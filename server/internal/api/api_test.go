package api

// Integration tests. They need a disposable Postgres:
//
//	docker run --rm -d -p 55432:5432 -e POSTGRES_PASSWORD=test --name asgard-test-db postgres:17-alpine
//	ASGARD_TEST_DATABASE_URL=postgres://postgres:test@localhost:55432/postgres?sslmode=disable go test ./...

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/google/uuid"

	"github.com/giantmushroom/asgard-chat/server/internal/config"
	"github.com/giantmushroom/asgard-chat/server/internal/db"
	"github.com/giantmushroom/asgard-chat/server/internal/e2ee"
	"github.com/giantmushroom/asgard-chat/server/internal/realtime"
)

type testClient struct {
	t      *testing.T
	base   string
	token  string
	user   uuid.UUID
	device uuid.UUID
	keys   *e2ee.DeviceKeys
}

func (c *testClient) do(method, path string, body any, out any) int {
	c.t.Helper()
	var buf bytes.Buffer
	if body != nil {
		json.NewEncoder(&buf).Encode(body)
	}
	req, _ := http.NewRequest(method, c.base+path, &buf)
	req.Header.Set("Content-Type", "application/json")
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	if out != nil {
		json.NewDecoder(resp.Body).Decode(out)
	}
	return resp.StatusCode
}

func newTestServer(t *testing.T) (*httptest.Server, *Server) {
	url := os.Getenv("ASGARD_TEST_DATABASE_URL")
	if url == "" {
		t.Skip("ASGARD_TEST_DATABASE_URL not set")
	}
	ctx := context.Background()
	pool, err := db.Open(ctx, url)
	if err != nil {
		t.Fatal(err)
	}
	// Fresh schema per test run.
	pool.Exec(ctx, `DROP SCHEMA public CASCADE; CREATE SCHEMA public;`)
	if err := db.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	mk := make([]byte, 32)
	cfg := &config.Config{PublicURL: "http://test", MasterKey: mk, SessionTTL: 3600e9, MaxUploadBytes: 1 << 20}
	s := New(cfg, pool, realtime.NewHub(), nil, nil)
	ts := httptest.NewServer(s.Router())
	t.Cleanup(func() { ts.Close(); pool.Close() })
	return ts, s
}

func register(t *testing.T, base, invite, username string) *testClient {
	keys, _ := e2ee.GenerateDeviceKeys()
	c := &testClient{t: t, base: base, keys: keys}
	var out struct {
		Token  string    `json:"token"`
		Device uuid.UUID `json:"device_id"`
		User   User      `json:"user"`
	}
	status := c.do("POST", "/api/v1/auth/register", map[string]any{
		"invite": invite, "username": username, "password": "correct-horse-battery",
		"device": map[string]any{"name": "test", "platform": "ios", "identity_key": keys.IdentityPublic[:], "signing_key": []byte(keys.SigningPublic)},
	}, &out)
	if status != http.StatusCreated {
		t.Fatalf("register %s: status %d", username, status)
	}
	c.token, c.device, c.user = out.Token, out.Device, out.User.ID
	return c
}

// send encrypts text for every device in the conversation, like a real client.
func (c *testClient) send(conv uuid.UUID, text string, extra map[string]any) (int, map[string]any) {
	var devices []Device
	c.do("GET", "/api/v1/conversations/"+conv.String()+"/devices", nil, &devices)
	clientID := uuid.New()
	aad := e2ee.AAD(conv.String(), c.device.String(), clientID.String())
	content, _ := json.Marshal(map[string]any{"v": 1, "type": "text", "text": text})
	key, ct, _ := e2ee.Seal(content, aad)
	keys := map[string][]byte{}
	for _, d := range devices {
		if d.ID != c.device {
			wk, _ := e2ee.Wrap(key, d.IdentityKey, clientID.String())
			keys[d.ID.String()] = wk
		}
	}
	body := map[string]any{"client_id": clientID, "kind": "msg", "ciphertext": ct, "signature": e2ee.Sign(c.keys.SigningPrivate, aad, ct), "keys": keys}
	for k, v := range extra {
		body[k] = v
	}
	var out map[string]any
	status := c.do("POST", "/api/v1/conversations/"+conv.String()+"/messages", body, &out)
	return status, out
}

func (c *testClient) decryptAll(senderSigning []byte) []string {
	var out struct {
		Envelopes []Envelope `json:"envelopes"`
	}
	c.do("GET", "/api/v1/sync?after=0", nil, &out)
	var texts []string
	for _, e := range out.Envelopes {
		if e.Kind != "msg" {
			continue
		}
		aad := e2ee.AAD(e.ConversationID.String(), e.SenderDeviceID.String(), e.ClientID.String())
		if !e2ee.Verify(senderSigning, aad, e.Ciphertext, e.Signature) {
			c.t.Fatal("signature failed")
		}
		key, err := e2ee.Unwrap(e.WrappedKey, c.keys.IdentityPrivate, c.keys.IdentityPublic, e.ClientID.String())
		if err != nil {
			c.t.Fatal(err)
		}
		pt, err := e2ee.Open(key, e.Ciphertext, aad)
		if err != nil {
			c.t.Fatal(err)
		}
		var content struct{ Text string }
		json.Unmarshal(pt, &content)
		texts = append(texts, content.Text)
	}
	return texts
}

func TestEndToEndFlow(t *testing.T) {
	ts, srv := newTestServer(t)
	ctx := context.Background()
	boot, err := CreateInvite(ctx, srv, nil, "boot", 1, true, 0)
	if err != nil {
		t.Fatal(err)
	}
	odin := register(t, ts.URL, boot.Code, "odin")

	// Second registration with a used invite fails.
	keys, _ := e2ee.GenerateDeviceKeys()
	bad := &testClient{t: t, base: ts.URL}
	if st := bad.do("POST", "/api/v1/auth/register", map[string]any{"invite": boot.Code, "username": "loki", "password": "correct-horse-battery",
		"device": map[string]any{"platform": "ios", "identity_key": keys.IdentityPublic[:], "signing_key": []byte(keys.SigningPublic)}}, nil); st != http.StatusForbidden {
		t.Fatalf("reused invite: got %d", st)
	}

	var inv Invite
	if st := odin.do("POST", "/api/v1/admin/invites", map[string]any{"max_uses": 3}, &inv); st != http.StatusCreated {
		t.Fatalf("create invite: %d", st)
	}
	thor := register(t, ts.URL, inv.Code, "thor")
	freya := register(t, ts.URL, inv.Code, "freya")

	// DM: open twice returns the same conversation.
	var dm, dm2 Conversation
	if st := odin.do("POST", "/api/v1/conversations", map[string]any{"kind": "dm", "member_ids": []uuid.UUID{thor.user}}, &dm); st != http.StatusCreated {
		t.Fatalf("open dm: %d", st)
	}
	thor.do("POST", "/api/v1/conversations", map[string]any{"kind": "dm", "member_ids": []uuid.UUID{odin.user}}, &dm2)
	if dm.ID != dm2.ID {
		t.Fatal("dm not deduplicated")
	}

	if st, out := odin.send(dm.ID, "Hail, Thor", nil); st != http.StatusCreated {
		t.Fatalf("send: %d %v", st, out)
	}
	if got := thor.decryptAll(odin.keys.SigningPublic); len(got) != 1 || got[0] != "Hail, Thor" {
		t.Fatalf("thor decrypted %v", got)
	}
	// Freya is not a member and cannot read the DM.
	if st := freya.do("GET", "/api/v1/conversations/"+dm.ID.String()+"/messages", nil, nil); st != http.StatusNotFound {
		t.Fatalf("non-member history: %d", st)
	}

	// A new device for Thor makes old fan-out stale: server rejects with 409.
	staleKeys := map[string][]byte{thor.device.String(): make([]byte, 92)}
	thor2keys, _ := e2ee.GenerateDeviceKeys()
	thor2 := &testClient{t: t, base: ts.URL, keys: thor2keys}
	var sess struct {
		Token  string    `json:"token"`
		Device uuid.UUID `json:"device_id"`
	}
	thor2.do("POST", "/api/v1/auth/login", map[string]any{"username": "thor", "password": "correct-horse-battery",
		"device": map[string]any{"platform": "android", "identity_key": thor2keys.IdentityPublic[:], "signing_key": []byte(thor2keys.SigningPublic)}}, &sess)
	thor2.token, thor2.device, thor2.user = sess.Token, sess.Device, thor.user
	var mismatch map[string]any
	st := odin.do("POST", "/api/v1/conversations/"+dm.ID.String()+"/messages", map[string]any{
		"client_id": uuid.New(), "kind": "msg", "ciphertext": []byte("x"), "signature": make([]byte, 64), "keys": staleKeys}, &mismatch)
	if st != http.StatusConflict {
		t.Fatalf("stale keys: got %d", st)
	}
	if st, _ := odin.send(dm.ID, "Both devices", nil); st != http.StatusCreated {
		t.Fatalf("send after refresh: %d", st)
	}
	if got := thor2.decryptAll(odin.keys.SigningPublic); len(got) != 1 || got[0] != "Both devices" {
		t.Fatalf("new device decrypted %v", got)
	}

	// Channel: only admins post, subscribers can't.
	var ch Conversation
	odin.do("POST", "/api/v1/conversations", map[string]any{"kind": "channel", "title": "Bifrost News", "member_ids": []uuid.UUID{freya.user}}, &ch)
	if st, _ := freya.send(ch.ID, "Can I post?", nil); st != http.StatusForbidden {
		t.Fatalf("subscriber post: %d", st)
	}
	if st, _ := odin.send(ch.ID, "Announcement", nil); st != http.StatusCreated {
		t.Fatalf("owner post: %d", st)
	}

	// Slow mode in a group.
	var grp Conversation
	odin.do("POST", "/api/v1/conversations", map[string]any{"kind": "group", "title": "Aesir", "member_ids": []uuid.UUID{thor.user, freya.user}}, &grp)
	odin.do("PATCH", "/api/v1/conversations/"+grp.ID.String(), map[string]any{"slow_mode_seconds": 60}, nil)
	if st, _ := freya.send(grp.ID, "first", nil); st != http.StatusCreated {
		t.Fatalf("first slow-mode post: %d", st)
	}
	if st, _ := freya.send(grp.ID, "second", nil); st != http.StatusTooManyRequests {
		t.Fatalf("second slow-mode post: %d", st)
	}

	// Webhook posts an encrypted message every member can read.
	var hook Webhook
	if st := odin.do("POST", "/api/v1/conversations/"+grp.ID.String()+"/webhooks", map[string]any{"name": "Heimdall"}, &hook); st != http.StatusCreated {
		t.Fatalf("create webhook: %d", st)
	}
	path := hook.URL[len("http://test"):]
	hookClient := &testClient{t: t, base: ts.URL}
	if st := hookClient.do("POST", path, map[string]any{"text": "Intruder at the gate"}, nil); st != http.StatusCreated {
		t.Fatalf("webhook post: %d", st)
	}
	var botSigning []byte
	var devs []Device
	freya.do("GET", "/api/v1/users/"+hook.BotUserID.String()+"/devices", nil, &devs)
	botSigning = devs[0].SigningKey
	var out struct{ Envelopes []Envelope }
	freya.do("GET", "/api/v1/sync?after=0", nil, &out)
	found := false
	for _, e := range out.Envelopes {
		if e.SenderUserID != nil && *e.SenderUserID == hook.BotUserID {
			aad := e2ee.AAD(e.ConversationID.String(), e.SenderDeviceID.String(), e.ClientID.String())
			key, err := e2ee.Unwrap(e.WrappedKey, freya.keys.IdentityPrivate, freya.keys.IdentityPublic, e.ClientID.String())
			if err != nil || !e2ee.Verify(botSigning, aad, e.Ciphertext, e.Signature) {
				t.Fatal("bot message did not verify/decrypt")
			}
			pt, _ := e2ee.Open(key, e.Ciphertext, aad)
			found = bytes.Contains(pt, []byte("Intruder"))
		}
	}
	if !found {
		t.Fatal("webhook message not delivered")
	}

	// Delete-for-everyone erases ciphertext.
	_, sent := odin.send(grp.ID, "oops", nil)
	target := sent["id"].(string)
	delClient := uuid.New()
	if st := odin.do("POST", "/api/v1/conversations/"+grp.ID.String()+"/messages", map[string]any{
		"client_id": delClient, "kind": "delete", "target_id": target, "ciphertext": []byte("d"), "signature": make([]byte, 64),
		"keys": fanoutKeys(t, odin, grp.ID)}, nil); st != http.StatusCreated {
		t.Fatalf("delete: %d", st)
	}
	var hist []Envelope
	thor.do("GET", "/api/v1/conversations/"+grp.ID.String()+"/messages", nil, &hist)
	for _, e := range hist {
		if e.ID.String() == target && (!e.Deleted || e.Ciphertext != nil) {
			t.Fatal("deleted message still has content")
		}
	}

	// Conversation list shows unread counts.
	var convs []Conversation
	thor.do("GET", "/api/v1/conversations", nil, &convs)
	unread := map[uuid.UUID]int{}
	for _, c := range convs {
		unread[c.ID] = c.Unread
	}
	if unread[dm.ID] != 2 {
		t.Fatalf("dm unread = %d, want 2", unread[dm.ID])
	}

	// Admin panel sessions never receive messages.
	adminKeys := map[string]any{"platform": "admin", "identity_key": make([]byte, 32), "signing_key": make([]byte, 32)}
	if st := thor.do("POST", "/api/v1/auth/login", map[string]any{"username": "thor", "password": "correct-horse-battery", "device": adminKeys}, nil); st != http.StatusForbidden {
		t.Fatalf("non-admin admin login: %d", st)
	}
	fmt.Println("end-to-end flow ok")
}

func fanoutKeys(t *testing.T, c *testClient, conv uuid.UUID) map[string]string {
	var devices []Device
	c.do("GET", "/api/v1/conversations/"+conv.String()+"/devices", nil, &devices)
	keys := map[string]string{}
	for _, d := range devices {
		if d.ID != c.device {
			keys[d.ID.String()] = base64.StdEncoding.EncodeToString(make([]byte, 92))
		}
	}
	return keys
}
