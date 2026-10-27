package api

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/giantmushroom/asgard-chat/server/internal/push"
	"github.com/giantmushroom/asgard-chat/server/internal/relay"
)

type recordingUpstream struct {
	mu   sync.Mutex
	sent []push.Notification
	to   []string
}

func (r *recordingUpstream) Send(_ context.Context, provider, token, _ string, n push.Notification) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.sent = append(r.sent, n)
	r.to = append(r.to, provider+":"+token)
	return nil
}

func (r *recordingUpstream) count() int { r.mu.Lock(); defer r.mu.Unlock(); return len(r.sent) }

// A self-hosted server registers with the relay on boot, its users register
// relay handles, and pushes for offline devices flow server -> relay -> Apple.
func TestPushThroughRelay(t *testing.T) {
	up := &recordingUpstream{}
	rl, _ := relay.New(relay.Config{MasterKey: bytes.Repeat([]byte{9}, 32)}, up)
	relaySrv := httptest.NewServer(rl.Handler())
	defer relaySrv.Close()

	ts, srv := newTestServer(t)
	srv.push = push.New()
	srv.cfg.PushRelayURL = relaySrv.URL
	ctx := context.Background()
	srv.StartPushRelay(ctx)
	for i := 0; srv.push.Relay() == nil && i < 50; i++ {
		time.Sleep(20 * time.Millisecond)
	}
	var info struct {
		PushRelay map[string]string `json:"push_relay"`
	}
	(&testClient{t: t, base: ts.URL}).do("GET", "/api/v1/info", nil, &info)
	if info.PushRelay["server_id"] == "" || info.PushRelay["url"] != relaySrv.URL {
		t.Fatalf("info push_relay = %v", info.PushRelay)
	}
	// Restarting the server reuses the stored registration.
	firstID := info.PushRelay["server_id"]
	srv.push = push.New()
	srv.StartPushRelay(ctx)
	if srv.push.Relay() == nil || srv.push.Relay().ServerID != firstID {
		t.Fatal("relay registration not reused after restart")
	}

	boot, _ := CreateInvite(ctx, srv, nil, "boot", 1, true, 0)
	odin := register(t, ts.URL, boot.Code, "odin")
	var inv Invite
	odin.do("POST", "/api/v1/admin/invites", map[string]any{"max_uses": 1}, &inv)
	thor := register(t, ts.URL, inv.Code, "thor")

	// Thor's phone registers its APNs token with the relay and gives the server only the handle.
	apnsToken := strings.Repeat("cd", 32)
	body, _ := json.Marshal(map[string]any{"server_id": firstID, "platform": "apns", "token": apnsToken, "env": "production"})
	resp, err := http.Post(relaySrv.URL+"/v1/devices", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	var reg struct{ Handle string }
	json.NewDecoder(resp.Body).Decode(&reg)
	resp.Body.Close()
	if st := thor.do("PUT", "/api/v1/me/push", map[string]any{"kind": "relay", "token": reg.Handle}, nil); st != http.StatusNoContent {
		t.Fatalf("set relay handle: %d", st)
	}
	var stored string
	srv.db.QueryRow(ctx, `SELECT push_token FROM devices WHERE id = $1`, thor.device).Scan(&stored)
	if strings.Contains(stored, apnsToken) {
		t.Fatal("server stored the raw device token")
	}

	var dm Conversation
	odin.do("POST", "/api/v1/conversations", map[string]any{"kind": "dm", "member_ids": []uuid.UUID{thor.user}}, &dm)
	if st, _ := odin.send(dm.ID, "Hail through the relay", nil); st != http.StatusCreated {
		t.Fatalf("send: %d", st)
	}
	for i := 0; up.count() == 0 && i < 100; i++ {
		time.Sleep(20 * time.Millisecond)
	}
	if up.count() == 0 {
		t.Fatal("push never reached the upstream")
	}
	if up.to[0] != "apns:"+apnsToken || up.sent[0].Kind != push.Alert || up.sent[0].Data["c"] != dm.ID.String() {
		t.Fatalf("upstream got %v %+v", up.to, up.sent[0])
	}
}
