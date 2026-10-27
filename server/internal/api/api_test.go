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
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/giantmushroom/asgard-chat/server/internal/config"
	"github.com/giantmushroom/asgard-chat/server/internal/db"
	"github.com/giantmushroom/asgard-chat/server/internal/e2ee"
	"github.com/giantmushroom/asgard-chat/server/internal/push"
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

func TestVoiceRooms(t *testing.T) {
	ts, srv := newTestServer(t)
	srv.cfg.LiveKitURL, srv.cfg.LiveKitAPIKey, srv.cfg.LiveKitAPISecret = "ws://lk", "key", "secret-secret-secret-secret-secret"
	ctx := context.Background()
	boot, _ := CreateInvite(ctx, srv, nil, "boot", 1, true, 0)
	odin := register(t, ts.URL, boot.Code, "odin")
	var inv Invite
	odin.do("POST", "/api/v1/admin/invites", map[string]any{"max_uses": 3}, &inv)
	thor := register(t, ts.URL, inv.Code, "thor")
	loki := register(t, ts.URL, inv.Code, "loki")

	var ch, dm Conversation
	if st := odin.do("POST", "/api/v1/conversations", map[string]any{"kind": "channel", "title": "Hall", "member_ids": []uuid.UUID{thor.user}}, &ch); st != http.StatusCreated {
		t.Fatalf("create channel: %d", st)
	}
	odin.do("POST", "/api/v1/conversations", map[string]any{"kind": "dm", "member_ids": []uuid.UUID{thor.user}}, &dm)
	base := "/api/v1/conversations/" + ch.ID.String() + "/voice"

	type join struct {
		Token        string             `json:"token"`
		Room         string             `json:"room"`
		First        bool               `json:"first"`
		Participants []voiceParticipant `json:"participants"`
	}
	// Channel subscribers can drop in; the first joiner is told to make the key.
	var j1, j2 join
	if st := thor.do("POST", base+"/join", map[string]any{}, &j1); st != http.StatusOK || !j1.First || j1.Token == "" {
		t.Fatalf("thor join: %d %+v", st, j1)
	}
	if st := odin.do("POST", base+"/join", map[string]any{"muted": true}, &j2); st != http.StatusOK || j2.First || len(j2.Participants) != 2 {
		t.Fatalf("odin join: %d %+v", st, j2)
	}
	if j2.Participants[0].UserID != thor.user {
		t.Fatal("participants not ordered by join time")
	}
	// Non-members can't see or join; DMs have no voice room.
	if st := loki.do("POST", base+"/join", map[string]any{}, nil); st != http.StatusNotFound {
		t.Fatalf("non-member join: %d", st)
	}
	if st := odin.do("POST", "/api/v1/conversations/"+dm.ID.String()+"/voice/join", map[string]any{}, nil); st != http.StatusBadRequest {
		t.Fatalf("dm voice: %d", st)
	}
	// Mute state is visible to others.
	thor.do("POST", base+"/update", map[string]any{"muted": true}, nil)
	var room struct {
		Participants []voiceParticipant `json:"participants"`
	}
	odin.do("GET", base, nil, &room)
	if len(room.Participants) != 2 || !room.Participants[0].Muted {
		t.Fatalf("room state: %+v", room)
	}
	var active []map[string]any
	if odin.do("GET", "/api/v1/voice", nil, &active); len(active) != 1 {
		t.Fatalf("active rooms for member: %v", active)
	}
	if loki.do("GET", "/api/v1/voice", nil, &active); len(active) != 0 {
		t.Fatalf("active rooms leak to non-member: %v", active)
	}
	// Leaving empties the room; the next joiner makes a new key.
	thor.do("POST", base+"/leave", nil, nil)
	odin.do("POST", base+"/leave", nil, nil)
	odin.do("GET", base, nil, &room)
	if len(room.Participants) != 0 {
		t.Fatalf("room not empty: %+v", room)
	}
	if thor.do("POST", base+"/join", map[string]any{}, &j1); !j1.First {
		t.Fatal("rejoin of empty room not first")
	}
	// Devices that vanish without leaving are swept.
	srv.voiceMu.Lock()
	for _, p := range srv.voice[ch.ID] {
		p.seen = time.Now().Add(-2 * voiceStale)
	}
	srv.voiceMu.Unlock()
	srv.sweepVoice(ctx)
	if odin.do("GET", base, nil, &room); len(room.Participants) != 0 {
		t.Fatal("stale participant not swept")
	}
}

func TestPushAdmin(t *testing.T) {
	ts, srv := newTestServer(t)
	srv.push = push.New()
	ctx := context.Background()
	boot, _ := CreateInvite(ctx, srv, nil, "boot", 1, true, 0)
	odin := register(t, ts.URL, boot.Code, "odin")
	var inv Invite
	odin.do("POST", "/api/v1/admin/invites", map[string]any{"max_uses": 1}, &inv)
	thor := register(t, ts.URL, inv.Code, "thor")

	if st := thor.do("GET", "/api/v1/admin/push", nil, nil); st != http.StatusForbidden {
		t.Fatalf("non-admin push status: %d", st)
	}
	var status struct {
		APNs     pushSource `json:"apns"`
		CanStore bool       `json:"can_store"`
	}
	if st := odin.do("GET", "/api/v1/admin/push", nil, &status); st != http.StatusOK || status.APNs.Configured || !status.CanStore {
		t.Fatalf("push status: %d %+v", st, status)
	}
	// Invalid keys are rejected before anything is stored or contacted.
	if st := odin.do("PUT", "/api/v1/admin/push/apns", map[string]any{"key": "nope", "key_id": "ABCDE12345", "team_id": "TEAM123456"}, nil); st != http.StatusUnprocessableEntity {
		t.Fatalf("bad apns key: %d", st)
	}
	if st := odin.do("PUT", "/api/v1/admin/push/fcm", map[string]any{"credentials": "{}"}, nil); st != http.StatusUnprocessableEntity {
		t.Fatalf("bad fcm creds: %d", st)
	}
	var info struct {
		Features map[string]bool `json:"features"`
	}
	odin.do("GET", "/api/v1/info", nil, &info)
	if info.Features["push"] {
		t.Fatal("push should be off")
	}
	// Devices report their build environment with their token.
	if st := odin.do("PUT", "/api/v1/me/push", map[string]any{"kind": "apns", "token": "abc", "env": "development"}, nil); st != http.StatusNoContent {
		t.Fatalf("set push token: %d", st)
	}
	var env string
	srv.db.QueryRow(ctx, `SELECT push_env FROM devices WHERE id = $1`, odin.device).Scan(&env)
	if env != "development" {
		t.Fatalf("push env = %q", env)
	}
	var results []map[string]any
	if st := odin.do("POST", "/api/v1/admin/push/test", nil, &results); st != http.StatusOK || len(results) != 1 {
		t.Fatalf("test push: %d %v", st, results)
	}
}

func TestHistorySync(t *testing.T) {
	ts, srv := newTestServer(t)
	ctx := context.Background()
	boot, _ := CreateInvite(ctx, srv, nil, "boot", 1, true, 0)
	odin := register(t, ts.URL, boot.Code, "odin")
	var inv Invite
	odin.do("POST", "/api/v1/admin/invites", map[string]any{"max_uses": 1}, &inv)
	thor := register(t, ts.URL, inv.Code, "thor")
	var dm Conversation
	odin.do("POST", "/api/v1/conversations", map[string]any{"kind": "dm", "member_ids": []uuid.UUID{thor.user}}, &dm)

	// A message from before history sync existed.
	_, early := thor.send(dm.ID, "before", nil)
	earlyID := uuid.MustParse(early["id"].(string))

	hist, _ := e2ee.GenerateDeviceKeys()
	var status struct {
		Enabled     bool   `json:"enabled"`
		IdentityKey []byte `json:"identity_key"`
		Messages    int    `json:"messages"`
	}
	if st := odin.do("PUT", "/api/v1/me/history", map[string]any{"identity_key": hist.IdentityPublic[:], "signing_key": []byte(hist.SigningPublic)}, &status); st != http.StatusOK || !status.Enabled {
		t.Fatalf("enable history: %d %+v", st, status)
	}
	// The history device is part of fan-out but hidden from the device list.
	var mine []Device
	odin.do("GET", "/api/v1/me/devices", nil, &mine)
	if len(mine) != 1 {
		t.Fatalf("history device listed: %d devices", len(mine))
	}
	var convDevices []Device
	thor.do("GET", "/api/v1/conversations/"+dm.ID.String()+"/devices", nil, &convDevices)
	if len(convDevices) != 3 {
		t.Fatalf("conversation devices = %d, want 3 (two phones + history)", len(convDevices))
	}
	if st, out := thor.send(dm.ID, "after", nil); st != http.StatusCreated {
		t.Fatalf("send with history device: %d %v", st, out)
	}

	type page struct {
		Envelopes []Envelope `json:"envelopes"`
	}
	var p page
	odin.do("GET", "/api/v1/me/history/messages", nil, &p)
	if len(p.Envelopes) != 1 {
		t.Fatalf("history before backfill: %d envelopes", len(p.Envelopes))
	}
	key, err := e2ee.Unwrap(p.Envelopes[0].WrappedKey, hist.IdentityPrivate, hist.IdentityPublic, p.Envelopes[0].ClientID.String())
	if err != nil {
		t.Fatal(err)
	}
	pt, _ := e2ee.Open(key, p.Envelopes[0].Ciphertext, e2ee.AAD(dm.ID.String(), p.Envelopes[0].SenderDeviceID.String(), p.Envelopes[0].ClientID.String()))
	if !strings.Contains(string(pt), "after") {
		t.Fatalf("history decrypted %q", pt)
	}

	// Odin's phone re-wraps the old message's key for the history device.
	var hist2 []Envelope
	odin.do("GET", "/api/v1/conversations/"+dm.ID.String()+"/messages", nil, &hist2)
	var old Envelope
	for _, e := range hist2 {
		if e.ID == earlyID {
			old = e
		}
	}
	oldKey, err := e2ee.Unwrap(old.WrappedKey, odin.keys.IdentityPrivate, odin.keys.IdentityPublic, old.ClientID.String())
	if err != nil {
		t.Fatal(err)
	}
	rewrapped, _ := e2ee.Wrap(oldKey, hist.IdentityPublic[:], old.ClientID.String())
	var res struct{ Added int }
	odin.do("POST", "/api/v1/me/history/backfill", map[string]any{"items": []map[string]any{{"message_id": earlyID, "wrapped_key": rewrapped}}}, &res)
	if res.Added != 1 {
		t.Fatalf("backfill added %d", res.Added)
	}
	// Thor can't backfill into Odin's history.
	if st := thor.do("POST", "/api/v1/me/history/backfill", map[string]any{"items": []map[string]any{}}, nil); st != http.StatusNotFound {
		t.Fatalf("thor backfill without history: %d", st)
	}
	odin.do("GET", "/api/v1/me/history/messages", nil, &p)
	if len(p.Envelopes) != 2 {
		t.Fatalf("history after backfill: %d", len(p.Envelopes))
	}

	// Turning it off removes the device and everything wrapped for it.
	odin.do("DELETE", "/api/v1/me/history", nil, nil)
	if st := odin.do("GET", "/api/v1/me/history/messages", nil, nil); st != http.StatusNotFound {
		t.Fatalf("history after delete: %d", st)
	}
}
