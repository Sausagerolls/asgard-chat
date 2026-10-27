// Package relay is the push relay that lets any self-hosted Asgard server
// notify users of the official apps without holding Apple or Google keys.
//
// It is stateless, so it runs on a free serverless tier:
//
//   - A server registers once and receives a server id plus a secret derived
//     from the relay's master key (HMAC), so nothing has to be stored.
//   - An app registers its APNs/FCM token and receives a "handle": the token,
//     platform, environment and server id sealed with a key only the relay
//     knows. Servers only ever see handles, never real device tokens.
//   - A server pushes by sending a signed request with a handle. The relay
//     refuses handles issued for a different server, so a rogue server can
//     only reach its own users.
//
// Payloads are the same end-to-end encrypted envelopes servers already send;
// the relay can't read them.
package relay

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/hkdf"

	"github.com/giantmushroom/asgard-chat/server/internal/push"
	"github.com/giantmushroom/asgard-chat/server/internal/relay/sign"
)

// Upstream delivers to Apple and Google; *push.Sender implements it.
type Upstream interface {
	Send(ctx context.Context, provider, token, env string, n push.Notification) error
}

type Config struct {
	MasterKey      []byte           // 32 bytes; rotating it invalidates every handle and server secret
	Blocked        map[string]bool  // server ids refused (abuse)
	PushesPerSec   float64          // sustained rate per server
	PushBurst      float64          // burst per server
	DailyPerServer int              // hard cap per server per UTC day
	RegisterPerIP  int              // server/device registrations per IP per hour
	Now            func() time.Time // for tests
}

type Relay struct {
	cfg       Config
	up        Upstream
	handleKey []byte
	serverKey []byte

	mu      sync.Mutex
	buckets map[string]*bucket
	ips     map[string]*window
}

type bucket struct {
	tokens float64
	last   time.Time
	day    string
	count  int
}

type window struct {
	start time.Time
	n     int
}

const (
	handlePrefix   = "h1."
	maxBody        = 8 << 10
	clockTolerance = 5 * time.Minute
)

func New(cfg Config, up Upstream) (*Relay, error) {
	if len(cfg.MasterKey) != 32 {
		return nil, errors.New("relay master key must be 32 bytes")
	}
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.PushesPerSec == 0 {
		cfg.PushesPerSec = 20
	}
	if cfg.PushBurst == 0 {
		cfg.PushBurst = 200
	}
	if cfg.DailyPerServer == 0 {
		cfg.DailyPerServer = 50_000
	}
	if cfg.RegisterPerIP == 0 {
		cfg.RegisterPerIP = 60
	}
	derive := func(info string) []byte {
		k := make([]byte, 32)
		io.ReadFull(hkdf.New(sha256.New, cfg.MasterKey, nil, []byte(info)), k)
		return k
	}
	return &Relay{cfg: cfg, up: up, handleKey: derive("asgard-relay-handle-v1"), serverKey: derive("asgard-relay-server-v1"),
		buckets: map[string]*bucket{}, ips: map[string]*window{}}, nil
}

func (r *Relay) Handler() http.Handler {
	mux := http.NewServeMux()
	// Cloud Run reserves paths ending in "z" (like /healthz), so health lives at /health.
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("POST /v1/servers", r.registerServer)
	mux.HandleFunc("POST /v1/devices", r.registerDevice)
	mux.HandleFunc("POST /v1/push", r.push)
	return mux
}

// ---- Credentials ----

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// ServerSecret derives a server's secret from its id.
func (r *Relay) ServerSecret(id string) string {
	m := hmac.New(sha256.New, r.serverKey)
	m.Write([]byte(id))
	return b64(m.Sum(nil))
}

type handleBody struct {
	V        int    `json:"v"`
	Platform string `json:"p"` // apns | fcm
	Token    string `json:"t"`
	Env      string `json:"e,omitempty"`
	Server   string `json:"s"`
}

func (r *Relay) sealHandle(h handleBody) (string, error) {
	aead, err := chacha20poly1305.NewX(r.handleKey)
	if err != nil {
		return "", err
	}
	plain, _ := json.Marshal(h)
	nonce := make([]byte, aead.NonceSize())
	rand.Read(nonce)
	return handlePrefix + b64(aead.Seal(nonce, nonce, plain, []byte(handlePrefix))), nil
}

func (r *Relay) openHandle(s string) (*handleBody, error) {
	if !strings.HasPrefix(s, handlePrefix) {
		return nil, errors.New("bad handle")
	}
	raw, err := base64.RawURLEncoding.DecodeString(s[len(handlePrefix):])
	aead, _ := chacha20poly1305.NewX(r.handleKey)
	if err != nil || len(raw) < aead.NonceSize()+aead.Overhead() {
		return nil, errors.New("bad handle")
	}
	plain, err := aead.Open(nil, raw[:aead.NonceSize()], raw[aead.NonceSize():], []byte(handlePrefix))
	if err != nil {
		return nil, errors.New("bad handle")
	}
	var h handleBody
	if json.Unmarshal(plain, &h) != nil || h.V != 1 {
		return nil, errors.New("bad handle")
	}
	return &h, nil
}

// Sign returns the headers a server sends with a push.
func Sign(serverID, secret string, body []byte, now time.Time) map[string]string {
	return sign.Headers(serverID, secret, body, now)
}

func (r *Relay) verify(req *http.Request, body []byte) (string, bool) {
	id := req.Header.Get("X-Asgard-Server")
	ts, err := strconv.ParseInt(req.Header.Get("X-Asgard-Timestamp"), 10, 64)
	sig, err2 := hex.DecodeString(req.Header.Get("X-Asgard-Signature"))
	if id == "" || err != nil || err2 != nil {
		return "", false
	}
	if d := r.cfg.Now().Sub(time.Unix(ts, 0)); d > clockTolerance || d < -clockTolerance {
		return "", false
	}
	return id, hmac.Equal(sig, sign.MAC(r.ServerSecret(id), strconv.FormatInt(ts, 10), body))
}

// ---- Handlers ----

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func fail(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": msg}})
}

func clientIP(req *http.Request) string {
	// Cloud Run sets X-Forwarded-For; the first address is the client.
	if f := req.Header.Get("X-Forwarded-For"); f != "" {
		return strings.TrimSpace(strings.Split(f, ",")[0])
	}
	h, _, _ := net.SplitHostPort(req.RemoteAddr)
	return h
}

func (r *Relay) allowIP(ip string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.cfg.Now()
	w := r.ips[ip]
	if w == nil || now.Sub(w.start) > time.Hour {
		if len(r.ips) > 50_000 {
			r.ips = map[string]*window{}
		}
		w = &window{start: now}
		r.ips[ip] = w
	}
	w.n++
	return w.n <= r.cfg.RegisterPerIP
}

func (r *Relay) allowServer(id string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.cfg.Now()
	b := r.buckets[id]
	if b == nil {
		b = &bucket{tokens: r.cfg.PushBurst, last: now}
		r.buckets[id] = b
	}
	if day := now.UTC().Format("2006-01-02"); b.day != day {
		b.day, b.count = day, 0
	}
	b.tokens = min(r.cfg.PushBurst, b.tokens+now.Sub(b.last).Seconds()*r.cfg.PushesPerSec)
	b.last = now
	if b.tokens < 1 || b.count >= r.cfg.DailyPerServer {
		return false
	}
	b.tokens--
	b.count++
	return true
}

func (r *Relay) registerServer(w http.ResponseWriter, req *http.Request) {
	if !r.allowIP(clientIP(req)) {
		fail(w, http.StatusTooManyRequests, "rate_limited", "Too many registrations from this address.")
		return
	}
	id := make([]byte, 16)
	rand.Read(id)
	sid := "s1" + b64(id)
	slog.Info("server registered", "server", sid)
	writeJSON(w, http.StatusCreated, map[string]string{"server_id": sid, "secret": r.ServerSecret(sid)})
}

func (r *Relay) registerDevice(w http.ResponseWriter, req *http.Request) {
	var in struct {
		ServerID string `json:"server_id"`
		Platform string `json:"platform"`
		Token    string `json:"token"`
		Env      string `json:"env"`
	}
	if json.NewDecoder(io.LimitReader(req.Body, maxBody)).Decode(&in) != nil {
		fail(w, http.StatusBadRequest, "bad_request", "Invalid JSON.")
		return
	}
	if !r.allowIP(clientIP(req)) {
		fail(w, http.StatusTooManyRequests, "rate_limited", "Too many registrations from this address.")
		return
	}
	switch {
	case !strings.HasPrefix(in.ServerID, "s1") || len(in.ServerID) > 40:
		fail(w, http.StatusBadRequest, "bad_server", "Unknown server id.")
		return
	case in.Platform == "apns" && (len(in.Token) < 64 || len(in.Token) > 200 || strings.Trim(in.Token, "0123456789abcdefABCDEF") != ""): // gitleaks:allow (hex alphabet, not a secret)
		fail(w, http.StatusBadRequest, "bad_token", "That isn't an APNs device token.")
		return
	case in.Platform == "fcm" && (len(in.Token) < 20 || len(in.Token) > 4096):
		fail(w, http.StatusBadRequest, "bad_token", "That isn't an FCM registration token.")
		return
	case in.Platform != "apns" && in.Platform != "fcm":
		fail(w, http.StatusBadRequest, "bad_platform", "platform must be apns or fcm")
		return
	}
	if in.Env != "development" && in.Env != "production" {
		in.Env = ""
	}
	h, err := r.sealHandle(handleBody{V: 1, Platform: in.Platform, Token: in.Token, Env: in.Env, Server: in.ServerID})
	if err != nil {
		fail(w, http.StatusInternalServerError, "internal", "Couldn't create a handle.")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"handle": h})
}

// PushRequest is what an Asgard server sends to deliver one notification.
type PushRequest struct {
	Handle   string         `json:"handle"`
	Kind     string         `json:"kind"` // alert | voip | background
	ThreadID string         `json:"thread_id,omitempty"`
	Collapse string         `json:"collapse,omitempty"`
	Title    string         `json:"title,omitempty"`
	Body     string         `json:"body,omitempty"`
	Data     map[string]any `json:"data,omitempty"`
}

func (r *Relay) push(w http.ResponseWriter, req *http.Request) {
	body, err := io.ReadAll(io.LimitReader(req.Body, maxBody+1))
	if err != nil || len(body) > maxBody {
		fail(w, http.StatusRequestEntityTooLarge, "too_large", "Push payloads are limited to 8 KB.")
		return
	}
	server, ok := r.verify(req, body)
	if !ok {
		fail(w, http.StatusUnauthorized, "bad_signature", "Request signature is missing, invalid or too old.")
		return
	}
	if r.cfg.Blocked[server] {
		fail(w, http.StatusForbidden, "blocked", "This server has been blocked from the relay.")
		return
	}
	var in PushRequest
	if json.Unmarshal(body, &in) != nil {
		fail(w, http.StatusBadRequest, "bad_request", "Invalid JSON.")
		return
	}
	h, err := r.openHandle(in.Handle)
	if err != nil || h.Server != server {
		// Same answer for forged and foreign handles, so servers can't probe.
		fail(w, http.StatusGone, "unregistered", "Unknown device handle.")
		return
	}
	if !r.allowServer(server) {
		fail(w, http.StatusTooManyRequests, "rate_limited", "This server is sending too many notifications.")
		return
	}
	kind := push.Alert
	switch in.Kind {
	case "voip":
		kind = push.VoIP
	case "background":
		kind = push.Background
	}
	ctx, cancel := context.WithTimeout(req.Context(), 15*time.Second)
	defer cancel()
	err = r.up.Send(ctx, h.Platform, h.Token, h.Env, push.Notification{Kind: kind, ThreadID: in.ThreadID, Collapse: in.Collapse,
		Title: in.Title, Body: in.Body, Data: in.Data})
	switch {
	case errors.Is(err, push.ErrUnregistered):
		fail(w, http.StatusGone, "unregistered", "The device is no longer registered.")
	case err != nil:
		slog.Warn("upstream push failed", "server", server, "platform", h.Platform, "err", err)
		fail(w, http.StatusBadGateway, "upstream", "Apple or Google rejected the push.")
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}
