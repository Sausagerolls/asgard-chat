package api

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/giantmushroom/asgard-chat/server/internal/auth"
)

type apiError struct {
	Status  int    `json:"-"`
	Code    string `json:"code"`
	Message string `json:"message"`
	Extra   any    `json:"details,omitempty"`
}

func (e *apiError) Error() string { return e.Code + ": " + e.Message }

func errf(status int, code, msg string) *apiError {
	return &apiError{Status: status, Code: code, Message: msg}
}

var (
	errNotFound     = errf(http.StatusNotFound, "not_found", "Not found.")
	errForbidden    = errf(http.StatusForbidden, "forbidden", "You do not have permission to do that.")
	errUnauthorized = errf(http.StatusUnauthorized, "unauthorized", "Sign in again.")
)

func badRequest(msg string) *apiError { return errf(http.StatusBadRequest, "bad_request", msg) }

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if v != nil {
		json.NewEncoder(w).Encode(v)
	}
}

func writeErr(w http.ResponseWriter, r *http.Request, err error) {
	var ae *apiError
	if errors.As(err, &ae) {
		writeJSON(w, ae.Status, map[string]any{"error": ae})
		return
	}
	if errors.Is(err, pgx.ErrNoRows) {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": errNotFound})
		return
	}
	slog.Error("request failed", "method", r.Method, "path", r.URL.Path, "err", err)
	writeJSON(w, http.StatusInternalServerError, map[string]any{"error": errf(500, "internal", "Something went wrong.")})
}

// handler adapts func(w, r) error into http.HandlerFunc.
type handler func(w http.ResponseWriter, r *http.Request) error

func (h handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if err := h(w, r); err != nil {
		writeErr(w, r, err)
	}
}

func decode(r *http.Request, v any) error {
	dec := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 4<<20))
	if err := dec.Decode(v); err != nil {
		return badRequest("Invalid JSON body: " + err.Error())
	}
	return nil
}

func pathUUID(r *http.Request, name string) (uuid.UUID, error) {
	id, err := uuid.Parse(chi.URLParam(r, name))
	if err != nil {
		return uuid.Nil, errNotFound
	}
	return id, nil
}

func chiParam(r *http.Request, name string) string { return chi.URLParam(r, name) }

func queryInt(r *http.Request, name string, def, max int64) int64 {
	v, err := strconv.ParseInt(r.URL.Query().Get(name), 10, 64)
	if err != nil || v <= 0 {
		return def
	}
	if max > 0 && v > max {
		return max
	}
	return v
}

// ---- authentication ----

type principal struct {
	UserID   uuid.UUID
	DeviceID uuid.UUID // uuid.Nil for a bot token without a device yet
	Username string
	IsAdmin  bool
	IsBot    bool
}

type ctxKey int

const principalKey ctxKey = 1

func me(r *http.Request) *principal { return r.Context().Value(principalKey).(*principal) }

func bearer(r *http.Request) string {
	if h := r.Header.Get("Authorization"); strings.HasPrefix(h, "Bearer ") {
		return strings.TrimPrefix(h, "Bearer ")
	}
	return r.URL.Query().Get("token") // browsers cannot set WebSocket headers
}

func (s *Server) authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := bearer(r)
		if tok == "" {
			writeErr(w, r, errUnauthorized)
			return
		}
		p := &principal{}
		var device *uuid.UUID
		err := s.db.QueryRow(r.Context(), `
			SELECT u.id, s.device_id, u.username, u.is_admin, u.is_bot
			FROM sessions s JOIN users u ON u.id = s.user_id
			WHERE s.token_hash = $1 AND s.expires_at > now() AND NOT u.disabled`,
			auth.HashToken(tok)).Scan(&p.UserID, &device, &p.Username, &p.IsAdmin, &p.IsBot)
		if err != nil {
			writeErr(w, r, errUnauthorized)
			return
		}
		if device != nil {
			p.DeviceID = *device
		}
		s.touch(p)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), principalKey, p)))
	})
}

// requireDevice rejects bot tokens that have not registered device keys yet.
func requireDevice(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if me(r).DeviceID == uuid.Nil {
			writeErr(w, r, errf(http.StatusForbidden, "device_required", "Register device keys first."))
			return
		}
		next.ServeHTTP(w, r)
	})
}

func requireAdmin(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !me(r).IsAdmin {
			writeErr(w, r, errForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// touch records activity at most once a minute per device.
func (s *Server) touch(p *principal) {
	if p.DeviceID == uuid.Nil {
		return
	}
	s.touchMu.Lock()
	last := s.touched[p.DeviceID]
	now := time.Now()
	if now.Sub(last) < time.Minute {
		s.touchMu.Unlock()
		return
	}
	s.touched[p.DeviceID] = now
	s.touchMu.Unlock()
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		s.db.Exec(ctx, `UPDATE devices SET last_active_at = now() WHERE id = $1`, p.DeviceID)
		s.db.Exec(ctx, `UPDATE users SET last_seen_at = now() WHERE id = $1`, p.UserID)
	}()
}

// ---- rate limiting ----

type limiter struct {
	mu     sync.Mutex
	limit  int
	window time.Duration
	hits   map[string]*bucket
}

type bucket struct {
	count int
	reset time.Time
}

func newLimiter(limit int, window time.Duration) *limiter {
	return &limiter{limit: limit, window: window, hits: map[string]*bucket{}}
}

func (l *limiter) allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := time.Now()
	b := l.hits[key]
	if b == nil || now.After(b.reset) {
		if len(l.hits) > 10000 {
			l.hits = map[string]*bucket{}
		}
		b = &bucket{reset: now.Add(l.window)}
		l.hits[key] = b
	}
	b.count++
	return b.count <= l.limit
}

func (l *limiter) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := r.RemoteAddr
		if h, _, err := net.SplitHostPort(ip); err == nil {
			ip = h
		}
		if !l.allow(ip) {
			writeErr(w, r, errf(http.StatusTooManyRequests, "rate_limited", "Too many attempts. Wait a minute and try again."))
			return
		}
		next.ServeHTTP(w, r)
	})
}

// logRequests writes one line per request (method, path, status, client).
// Paths never contain message content; enable only when debugging.
func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
		start := time.Now()
		next.ServeHTTP(ww, r)
		if r.URL.Path == "/healthz" {
			return
		}
		slog.Info("request", "method", r.Method, "path", r.URL.Path, "status", ww.Status(),
			"ms", time.Since(start).Milliseconds(), "client", r.RemoteAddr, "ua", r.UserAgent())
	})
}
