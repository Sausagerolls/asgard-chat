// Package demo fills a review/demo server with a believable conversation and
// lets newly signed-in devices read it.
//
// Messages are end-to-end encrypted to the devices that exist when they are
// sent, so a reviewer signing in later couldn't read anything seeded earlier.
// Instead each demo account gets message history sync with a recovery key
// held here, the seed messages are wrapped for the history device, and a
// helper device on each account stays registered. When a new device appears,
// the helper sends it the recovery key through Saved Messages (exactly what a
// user's own phone does when they link a laptop), and the app restores the
// conversation by itself.
package demo

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/hkdf"

	"github.com/giantmushroom/asgard-chat/server/internal/e2ee"
)

// Account is one demo login and the helper device that acts for it.
type Account struct {
	Username    string    `json:"username"`
	Password    string    `json:"password"`
	UserID      uuid.UUID `json:"user_id"`
	DeviceID    uuid.UUID `json:"device_id"`
	Token       string    `json:"token"`
	IdentityKey []byte    `json:"identity_private"` // X25519 private
	SigningSeed []byte    `json:"signing_seed"`     // Ed25519 seed
	Recovery    []byte    `json:"recovery_key"`
	Handled     []string  `json:"handled_devices"`
}

type State struct {
	Seeded   bool       `json:"seeded"`
	Accounts []*Account `json:"accounts"`
}

type Runner struct {
	URL   string // e.g. http://asgard:8080
	Path  string // state file
	State State
	http  http.Client
}

// Run seeds once (accounts given as "user:password" pairs), then watches for
// new devices until ctx ends.
func Run(ctx context.Context, url, path string, logins []string) error {
	r := &Runner{URL: strings.TrimRight(url, "/") + "/api/v1", Path: path, http: http.Client{Timeout: 30 * time.Second}}
	if b, err := os.ReadFile(path); err == nil {
		if err := json.Unmarshal(b, &r.State); err != nil {
			return fmt.Errorf("read %s: %w", path, err)
		}
	}
	if !r.State.Seeded {
		if len(logins) < 2 {
			return errors.New("need at least two accounts (-accounts user:pass,user:pass)")
		}
		if err := r.seed(ctx, logins); err != nil {
			return err
		}
	}
	slog.Info("demo: watching for new devices", "accounts", len(r.State.Accounts))
	for {
		for _, a := range r.State.Accounts {
			if err := r.shareKey(ctx, a); err != nil {
				slog.Warn("demo: share key", "user", a.Username, "err", err)
			}
		}
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(4 * time.Second):
		}
	}
}

func (r *Runner) save() error {
	b, _ := json.MarshalIndent(r.State, "", "  ")
	tmp := r.Path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, r.Path)
}

// ---- seeding ----

func (r *Runner) seed(ctx context.Context, logins []string) error {
	byName := map[string]*Account{}
	r.State.Accounts = nil
	for _, l := range logins {
		user, pass, ok := strings.Cut(l, ":")
		if !ok {
			return fmt.Errorf("account %q is not user:password", l)
		}
		a := &Account{Username: user, Password: pass}
		if err := r.login(ctx, a); err != nil {
			return err
		}
		a.Recovery = random(32)
		id, sign := historyKeys(a.Recovery)
		if err := r.do(ctx, a, "PUT", "/me/history", map[string]any{"identity_key": id, "signing_key": sign}, nil); err != nil {
			return fmt.Errorf("enable history for %s: %w", user, err)
		}
		r.State.Accounts = append(r.State.Accounts, a)
		byName[user] = a
	}
	if err := r.save(); err != nil {
		return err
	}
	a, b := r.State.Accounts[0], r.State.Accounts[1]
	var convs []struct {
		ID   uuid.UUID `json:"id"`
		Kind string    `json:"kind"`
	}
	if err := r.do(ctx, a, "GET", "/conversations", nil, &convs); err != nil {
		return err
	}
	ids := map[string]uuid.UUID{}
	for _, c := range convs {
		ids[c.Kind] = c.ID
	}
	if ids["dm"] == uuid.Nil || ids["group"] == uuid.Nil {
		return fmt.Errorf("%s needs a DM and a group with %s before seeding", a.Username, b.Username)
	}
	sent := map[int]uuid.UUID{}
	for i, line := range script {
		who := a
		if line.From == 2 {
			who = b
		}
		content := map[string]any{"v": 1, "type": "text", "text": line.Text}
		if line.ReplyTo > 0 {
			content["reply_to"] = sent[line.ReplyTo-1]
		}
		id, err := r.send(ctx, who, ids[line.Chat], "msg", uuid.Nil, content)
		if err != nil {
			return fmt.Errorf("script line %d: %w", i+1, err)
		}
		sent[i] = id
		if line.React != "" {
			other := b
			if who == b {
				other = a
			}
			if _, err := r.send(ctx, other, ids[line.Chat], "reaction", id, map[string]any{"v": 1, "type": "reaction", "emoji": line.React, "target": id}); err != nil {
				return err
			}
		}
		time.Sleep(300 * time.Millisecond) // keeps the order and timestamps natural
	}
	r.State.Seeded = true
	slog.Info("demo: seeded", "messages", len(script))
	return r.save()
}

func (r *Runner) login(ctx context.Context, a *Account) error {
	var priv [32]byte
	copy(priv[:], random(32))
	pub, _ := curve25519.X25519(priv[:], curve25519.Basepoint)
	seed := random(ed25519.SeedSize)
	sign := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	var out struct {
		Token    string    `json:"token"`
		DeviceID uuid.UUID `json:"device_id"`
		User     struct {
			ID uuid.UUID `json:"id"`
		} `json:"user"`
	}
	body := map[string]any{"username": a.Username, "password": a.Password,
		"device": map[string]any{"name": "Asgard Demo helper", "platform": "web", "identity_key": pub, "signing_key": []byte(sign)}}
	if err := r.do(ctx, nil, "POST", "/auth/login", body, &out); err != nil {
		return fmt.Errorf("log in %s: %w", a.Username, err)
	}
	a.Token, a.DeviceID, a.UserID = out.Token, out.DeviceID, out.User.ID
	a.IdentityKey, a.SigningSeed = priv[:], seed
	a.Handled = append(a.Handled, a.DeviceID.String())
	return nil
}

// ---- new devices ----

// shareKey sends the recovery key to any device the account hasn't seen yet.
func (r *Runner) shareKey(ctx context.Context, a *Account) error {
	var devices []struct {
		ID       uuid.UUID `json:"id"`
		Platform string    `json:"platform"`
	}
	if err := r.do(ctx, a, "GET", "/me/devices", nil, &devices); err != nil {
		return err
	}
	var fresh []string
	for _, d := range devices {
		if d.Platform != "history" && d.Platform != "admin" && !slices.Contains(a.Handled, d.ID.String()) {
			fresh = append(fresh, d.ID.String())
		}
	}
	if len(fresh) == 0 {
		return nil
	}
	var convs []struct {
		ID   uuid.UUID `json:"id"`
		Kind string    `json:"kind"`
	}
	if err := r.do(ctx, a, "GET", "/conversations", nil, &convs); err != nil {
		return err
	}
	for _, c := range convs {
		if c.Kind == "saved" {
			if _, err := r.send(ctx, a, c.ID, "control", uuid.Nil, map[string]any{"v": 1, "type": "history_key", "history_key": a.Recovery}); err != nil {
				return err
			}
			slog.Info("demo: sent history key", "user", a.Username, "devices", fresh)
			a.Handled = append(a.Handled, fresh...)
			return r.save()
		}
	}
	return errors.New("no Saved Messages chat")
}

// ---- protocol ----

func (r *Runner) send(ctx context.Context, a *Account, conv uuid.UUID, kind string, target uuid.UUID, content any) (uuid.UUID, error) {
	plain, _ := json.Marshal(content)
	clientID := uuid.NewString()
	aad := e2ee.AAD(conv.String(), a.DeviceID.String(), clientID)
	key, ct, err := e2ee.Seal(plain, aad)
	if err != nil {
		return uuid.Nil, err
	}
	sig := e2ee.Sign(ed25519.NewKeyFromSeed(a.SigningSeed), aad, ct)
	for attempt := 0; ; attempt++ {
		var devices []struct {
			ID          uuid.UUID `json:"id"`
			IdentityKey []byte    `json:"identity_key"`
		}
		if err := r.do(ctx, a, "GET", "/conversations/"+conv.String()+"/devices", nil, &devices); err != nil {
			return uuid.Nil, err
		}
		keys := map[string][]byte{}
		for _, d := range devices {
			w, err := e2ee.Wrap(key, d.IdentityKey, clientID)
			if err != nil {
				return uuid.Nil, err
			}
			keys[d.ID.String()] = w
		}
		body := map[string]any{"client_id": clientID, "kind": kind, "ciphertext": ct, "signature": sig, "alg": "fanout-v1", "keys": keys}
		if target != uuid.Nil {
			body["target_id"] = target
		}
		var env struct {
			ID uuid.UUID `json:"id"`
		}
		err := r.do(ctx, a, "POST", "/conversations/"+conv.String()+"/messages", body, &env)
		var he *httpError
		if errors.As(err, &he) && he.status == http.StatusConflict && attempt < 3 {
			continue // someone's device list changed between the two calls
		}
		return env.ID, err
	}
}

type httpError struct {
	status int
	body   string
}

func (e *httpError) Error() string { return fmt.Sprintf("HTTP %d: %s", e.status, e.body) }

func (r *Runner) do(ctx context.Context, a *Account, method, path string, in, out any) error {
	var body io.Reader
	if in != nil {
		b, _ := json.Marshal(in)
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, r.URL+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if a != nil {
		req.Header.Set("Authorization", "Bearer "+a.Token)
	}
	res, err := r.http.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(res.Body)
	if res.StatusCode >= 300 {
		return &httpError{res.StatusCode, strings.TrimSpace(string(data))}
	}
	if out != nil && len(data) > 0 {
		return json.Unmarshal(data, out)
	}
	return nil
}

// historyKeys derives the history device's public keys from a recovery key,
// matching RecoveryKey.deviceKeys in the apps.
func historyKeys(recovery []byte) (identity, signing []byte) {
	derive := func(info string) []byte {
		out := make([]byte, 32)
		io.ReadFull(hkdf.New(sha256.New, recovery, []byte("asgard-history-v1"), []byte(info)), out)
		return out
	}
	identity, _ = curve25519.X25519(derive("identity"), curve25519.Basepoint)
	signing = ed25519.NewKeyFromSeed(derive("signing")).Public().(ed25519.PublicKey)
	return identity, signing
}

func random(n int) []byte {
	b := make([]byte, n)
	rand.Read(b)
	return b
}
