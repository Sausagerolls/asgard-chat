package relay

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/giantmushroom/asgard-chat/server/internal/push"
)

type fakeUpstream struct {
	sent []string
	gone map[string]bool
}

func (f *fakeUpstream) Send(_ context.Context, provider, token, env string, n push.Notification) error {
	if f.gone[token] {
		return push.ErrUnregistered
	}
	f.sent = append(f.sent, provider+":"+token+":"+env)
	return nil
}

type harness struct {
	t   *testing.T
	r   *Relay
	up  *fakeUpstream
	srv *httptest.Server
	now time.Time
}

func newHarness(t *testing.T, cfg Config) *harness {
	h := &harness{t: t, up: &fakeUpstream{gone: map[string]bool{}}, now: time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)}
	cfg.MasterKey = bytes.Repeat([]byte{7}, 32)
	cfg.Now = func() time.Time { return h.now }
	r, err := New(cfg, h.up)
	if err != nil {
		t.Fatal(err)
	}
	h.r = r
	h.srv = httptest.NewServer(r.Handler())
	t.Cleanup(h.srv.Close)
	return h
}

func (h *harness) post(path string, body any, headers map[string]string) (int, map[string]any) {
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest("POST", h.srv.URL+path, bytes.NewReader(raw))
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	json.NewDecoder(resp.Body).Decode(&out)
	return resp.StatusCode, out
}

func (h *harness) server() (id, secret string) {
	st, out := h.post("/v1/servers", map[string]any{}, nil)
	if st != http.StatusCreated {
		h.t.Fatalf("register server: %d", st)
	}
	return out["server_id"].(string), out["secret"].(string)
}

func (h *harness) device(server, platform, token string) string {
	st, out := h.post("/v1/devices", map[string]any{"server_id": server, "platform": platform, "token": token, "env": "production"}, nil)
	if st != http.StatusCreated {
		h.t.Fatalf("register device: %d %v", st, out)
	}
	return out["handle"].(string)
}

func (h *harness) push(id, secret, handle string) int {
	raw, _ := json.Marshal(PushRequest{Handle: handle, Kind: "alert", Data: map[string]any{"c": "conv"}})
	req, _ := http.NewRequest("POST", h.srv.URL+"/v1/push", bytes.NewReader(raw))
	for k, v := range Sign(id, secret, raw, h.now) {
		req.Header.Set(k, v)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}

var apnsToken = strings.Repeat("ab", 32)

func TestRelayFlow(t *testing.T) {
	h := newHarness(t, Config{})
	id, secret := h.server()
	if h.r.ServerSecret(id) != secret {
		t.Fatal("secret not derivable from id")
	}
	handle := h.device(id, "apns", apnsToken)
	if strings.Contains(handle, apnsToken) {
		t.Fatal("handle leaks the device token")
	}
	if st := h.push(id, secret, handle); st != http.StatusNoContent {
		t.Fatalf("push: %d", st)
	}
	if len(h.up.sent) != 1 || h.up.sent[0] != "apns:"+apnsToken+":production" {
		t.Fatalf("upstream got %v", h.up.sent)
	}
}

func TestRelayRejectsForeignAndForgedHandles(t *testing.T) {
	h := newHarness(t, Config{})
	a, aSecret := h.server()
	b, bSecret := h.server()
	handle := h.device(a, "fcm", strings.Repeat("x", 40))
	// Server B can't use a handle issued for server A's users.
	if st := h.push(b, bSecret, handle); st != http.StatusGone {
		t.Fatalf("foreign handle: %d", st)
	}
	// Tampered handles fail.
	if st := h.push(a, aSecret, handle[:len(handle)-2]+"AA"); st != http.StatusGone {
		t.Fatalf("tampered handle: %d", st)
	}
	// Wrong secret and replayed (old) requests fail.
	if st := h.push(a, bSecret, handle); st != http.StatusUnauthorized {
		t.Fatalf("wrong secret: %d", st)
	}
	raw, _ := json.Marshal(PushRequest{Handle: handle})
	req, _ := http.NewRequest("POST", h.srv.URL+"/v1/push", bytes.NewReader(raw))
	for k, v := range Sign(a, aSecret, raw, h.now.Add(-10*time.Minute)) {
		req.Header.Set(k, v)
	}
	resp, _ := http.DefaultClient.Do(req)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("stale signature: %d", resp.StatusCode)
	}
	if len(h.up.sent) != 0 {
		t.Fatalf("nothing should have been sent: %v", h.up.sent)
	}
}

func TestRelayLimitsAndBlocks(t *testing.T) {
	h := newHarness(t, Config{PushesPerSec: 1, PushBurst: 2, DailyPerServer: 3, RegisterPerIP: 100})
	id, secret := h.server()
	handle := h.device(id, "apns", apnsToken)
	codes := []int{h.push(id, secret, handle), h.push(id, secret, handle), h.push(id, secret, handle)}
	if codes[2] != http.StatusTooManyRequests {
		t.Fatalf("burst limit: %v", codes)
	}
	h.now = h.now.Add(5 * time.Second)
	if st := h.push(id, secret, handle); st != http.StatusNoContent {
		t.Fatalf("after refill: %d", st)
	}
	h.now = h.now.Add(5 * time.Second)
	if st := h.push(id, secret, handle); st != http.StatusTooManyRequests {
		t.Fatalf("daily cap: %d", st)
	}

	blocked := newHarness(t, Config{})
	bid, bsecret := blocked.server()
	bhandle := blocked.device(bid, "apns", apnsToken)
	blocked.r.cfg.Blocked = map[string]bool{bid: true}
	if st := blocked.push(bid, bsecret, bhandle); st != http.StatusForbidden {
		t.Fatalf("blocked server: %d", st)
	}
}

func TestRelayUnregisteredAndValidation(t *testing.T) {
	h := newHarness(t, Config{RegisterPerIP: 3})
	id, secret := h.server()
	handle := h.device(id, "apns", apnsToken)
	h.up.gone[apnsToken] = true
	if st := h.push(id, secret, handle); st != http.StatusGone {
		t.Fatalf("dead token: %d", st)
	}
	if st, _ := h.post("/v1/devices", map[string]any{"server_id": id, "platform": "apns", "token": "nothex"}, nil); st != http.StatusBadRequest {
		t.Fatalf("bad apns token: %d", st)
	}
	// Per-IP registration limit (3 per hour here; 3 used above).
	if st, _ := h.post("/v1/servers", map[string]any{}, nil); st != http.StatusTooManyRequests {
		t.Fatalf("ip limit: %d", st)
	}
}
