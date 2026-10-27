// Package api implements the Asgard Chat HTTP and WebSocket API.
package api

import (
	"context"
	"encoding/json"
	"net/http"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/giantmushroom/asgard-chat/server/internal/adminui"
	"github.com/giantmushroom/asgard-chat/server/internal/config"
	"github.com/giantmushroom/asgard-chat/server/internal/push"
	"github.com/giantmushroom/asgard-chat/server/internal/realtime"
	"github.com/giantmushroom/asgard-chat/server/internal/storage"
)

var Version = "dev"

type Server struct {
	cfg   *config.Config
	db    *pgxpool.Pool
	hub   *realtime.Hub
	push  *push.Sender
	store storage.Store

	touchMu sync.Mutex
	touched map[uuid.UUID]time.Time

	callsMu sync.Mutex
	calls   map[uuid.UUID]*activeCall
}

func New(cfg *config.Config, db *pgxpool.Pool, hub *realtime.Hub, ps *push.Sender, st storage.Store) *Server {
	s := &Server{cfg: cfg, db: db, hub: hub, push: ps, store: st,
		touched: map[uuid.UUID]time.Time{}, calls: map[uuid.UUID]*activeCall{}}
	hub.OnPresence = s.broadcastPresence
	return s
}

func (s *Server) Router() http.Handler {
	r := chi.NewRouter()
	if s.cfg.TrustProxy {
		r.Use(middleware.RealIP)
	}
	r.Use(middleware.RequestID, middleware.Recoverer, securityHeaders)

	r.Get("/healthz", s.healthz)
	r.Get("/.well-known/apple-app-site-association", s.appleAppSiteAssociation)
	r.Get("/.well-known/assetlinks.json", s.androidAssetLinks)
	r.Mount("/admin", adminui.Handler())

	authLimit := newLimiter(10, time.Minute)
	r.Route("/api/v1", func(r chi.Router) {
		r.Get("/info", handler(s.info).ServeHTTP)
		r.With(authLimit.middleware).Post("/auth/register", handler(s.register).ServeHTTP)
		r.With(authLimit.middleware).Post("/auth/login", handler(s.login).ServeHTTP)
		r.With(authLimit.middleware).Post("/devices/link/claim", handler(s.claimDeviceLink).ServeHTTP)
		r.With(authLimit.middleware).Post("/hooks/{hookID}/{secret}", handler(s.incomingWebhook).ServeHTTP)

		r.Group(func(r chi.Router) {
			r.Use(s.authenticate)
			r.Post("/auth/bot-device", handler(s.registerBotDevice).ServeHTTP)

			r.Group(func(r chi.Router) {
				r.Use(requireDevice)
				r.Get("/ws", s.websocket)
				r.Post("/auth/logout", handler(s.logout).ServeHTTP)

				r.Get("/me", handler(s.getMe).ServeHTTP)
				r.Patch("/me", handler(s.updateMe).ServeHTTP)
				r.Put("/me/password", handler(s.changePassword).ServeHTTP)
				r.Put("/me/push", handler(s.setPushToken).ServeHTTP)
				r.Get("/me/devices", handler(s.listMyDevices).ServeHTTP)
				r.Delete("/me/devices/{deviceID}", handler(s.revokeDevice).ServeHTTP)
				r.Post("/devices/link", handler(s.createDeviceLink).ServeHTTP)

				r.Get("/users", handler(s.searchUsers).ServeHTTP)
				r.Get("/users/{userID}", handler(s.getUser).ServeHTTP)
				r.Get("/users/{userID}/devices", handler(s.userDevices).ServeHTTP)
				r.Get("/contacts", handler(s.listContacts).ServeHTTP)
				r.Put("/contacts/{userID}", handler(s.putContact).ServeHTTP)
				r.Delete("/contacts/{userID}", handler(s.deleteContact).ServeHTTP)

				r.Get("/sync", handler(s.sync).ServeHTTP)

				r.Get("/conversations", handler(s.listConversations).ServeHTTP)
				r.Post("/conversations", handler(s.createConversation).ServeHTTP)
				r.Get("/conversations/discover", handler(s.discoverConversations).ServeHTTP)
				r.Route("/conversations/{convID}", func(r chi.Router) {
					r.Get("/", handler(s.getConversation).ServeHTTP)
					r.Patch("/", handler(s.updateConversation).ServeHTTP)
					r.Delete("/", handler(s.deleteConversation).ServeHTTP)
					r.Post("/join", handler(s.joinConversation).ServeHTTP)
					r.Post("/leave", handler(s.leaveConversation).ServeHTTP)
					r.Put("/prefs", handler(s.updatePrefs).ServeHTTP)
					r.Get("/members", handler(s.listMembers).ServeHTTP)
					r.Post("/members", handler(s.addMembers).ServeHTTP)
					r.Patch("/members/{userID}", handler(s.updateMember).ServeHTTP)
					r.Delete("/members/{userID}", handler(s.removeMember).ServeHTTP)
					r.Get("/devices", handler(s.conversationDevices).ServeHTTP)
					r.Get("/messages", handler(s.history).ServeHTTP)
					r.Post("/messages", handler(s.sendMessage).ServeHTTP)
					r.Get("/messages/{msgID}/thread", handler(s.thread).ServeHTTP)
					r.Post("/read", handler(s.markRead).ServeHTTP)
					r.Get("/scheduled", handler(s.listScheduled).ServeHTTP)
					r.Delete("/scheduled/{schedID}", handler(s.cancelScheduled).ServeHTTP)
					r.Post("/calls", handler(s.startCall).ServeHTTP)
					r.Post("/calls/end", handler(s.endCall).ServeHTTP)
					r.Get("/webhooks", handler(s.listWebhooks).ServeHTTP)
					r.Post("/webhooks", handler(s.createWebhook).ServeHTTP)
					r.Delete("/webhooks/{hookID}", handler(s.deleteWebhook).ServeHTTP)
				})

				r.Post("/media", handler(s.uploadMedia).ServeHTTP)
				r.Get("/media/{mediaID}", handler(s.downloadMedia).ServeHTTP)
				r.Delete("/media/{mediaID}", handler(s.deleteMedia).ServeHTTP)

				r.Get("/stories", handler(s.listStories).ServeHTTP)
				r.Post("/stories", handler(s.postStory).ServeHTTP)
				r.Delete("/stories/{storyID}", handler(s.deleteStory).ServeHTTP)
				r.Post("/stories/{storyID}/view", handler(s.viewStory).ServeHTTP)
				r.Get("/stories/{storyID}/views", handler(s.storyViews).ServeHTTP)

				r.Get("/bots", handler(s.listBots).ServeHTTP)
				r.Post("/bots", handler(s.createBot).ServeHTTP)
				r.Delete("/bots/{userID}", handler(s.deleteBot).ServeHTTP)

				r.Route("/admin", func(r chi.Router) {
					r.Use(requireAdmin)
					r.Get("/stats", handler(s.adminStats).ServeHTTP)
					r.Get("/users", handler(s.adminUsers).ServeHTTP)
					r.Patch("/users/{userID}", handler(s.adminUpdateUser).ServeHTTP)
					r.Post("/users/{userID}/reset-password", handler(s.adminResetPassword).ServeHTTP)
					r.Delete("/users/{userID}", handler(s.adminDeleteUser).ServeHTTP)
					r.Get("/invites", handler(s.adminListInvites).ServeHTTP)
					r.Post("/invites", handler(s.adminCreateInvite).ServeHTTP)
					r.Delete("/invites/{code}", handler(s.adminDeleteInvite).ServeHTTP)
					r.Get("/audit", handler(s.adminAudit).ServeHTTP)
					r.Get("/settings", handler(s.adminGetSettings).ServeHTTP)
					r.Put("/settings", handler(s.adminPutSettings).ServeHTTP)
				})
			})
		})
	})
	return r
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("X-Frame-Options", "DENY")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) healthz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 3*time.Second)
	defer cancel()
	status := map[string]string{"status": "ok", "database": "ok", "storage": "disabled"}
	code := http.StatusOK
	if err := s.db.Ping(ctx); err != nil {
		status["database"], status["status"], code = "down", "degraded", http.StatusServiceUnavailable
	}
	if s.store != nil {
		status["storage"] = "ok"
		if err := s.store.Ping(ctx); err != nil {
			status["storage"], status["status"], code = "down", "degraded", http.StatusServiceUnavailable
		}
	}
	writeJSON(w, code, status)
}

func (s *Server) info(w http.ResponseWriter, r *http.Request) error {
	settings := s.settings(r.Context())
	writeJSON(w, http.StatusOK, map[string]any{
		"name":              settings.ServerName,
		"version":           Version,
		"protocol":          1,
		"open_registration": s.cfg.OpenRegistration || settings.OpenRegistration,
		"features": map[string]bool{
			"calls": s.cfg.CallsEnabled(), "push": s.cfg.PushEnabled(), "media": s.store != nil,
			"stories": true, "bots": true, "communities": true, "channels": true,
			"server_bots": len(s.cfg.MasterKey) == 32,
		},
		"max_upload_bytes": s.cfg.MaxUploadBytes,
		"livekit_url":      s.cfg.LiveKitURL,
	})
	return nil
}

// appleAppSiteAssociation enables universal links (invites, device linking)
// and the shared web credentials used by password AutoFill.
func (s *Server) appleAppSiteAssociation(w http.ResponseWriter, r *http.Request) {
	appID := s.cfg.APNsTeamID + "." + s.cfg.APNsTopic
	writeJSON(w, http.StatusOK, map[string]any{
		"applinks": map[string]any{"details": []any{map[string]any{
			"appIDs":     []string{appID},
			"components": []any{map[string]string{"/": "/invite/*"}, map[string]string{"/": "/link/*"}, map[string]string{"/": "/c/*"}},
		}}},
		"webcredentials": map[string]any{"apps": []string{appID}},
	})
}

func (s *Server) androidAssetLinks(w http.ResponseWriter, r *http.Request) {
	fp := s.settings(r.Context()).AndroidCertSHA256
	if fp == "" {
		writeJSON(w, http.StatusOK, []any{})
		return
	}
	writeJSON(w, http.StatusOK, []any{map[string]any{
		"relation": []string{"delegate_permission/common.handle_all_urls", "delegate_permission/common.get_login_creds"},
		"target":   map[string]any{"namespace": "android_app", "package_name": s.cfg.APNsTopic, "sha256_cert_fingerprints": []string{fp}},
	}})
}

// ---- server settings ----

type ServerSettings struct {
	ServerName         string `json:"server_name"`
	OpenRegistration   bool   `json:"open_registration"`
	DefaultDisappear   int    `json:"default_disappearing_seconds"`
	AllowUserBots      bool   `json:"allow_user_bots"`
	AllowPublicGroups  bool   `json:"allow_public_groups"`
	AndroidCertSHA256  string `json:"android_cert_sha256"`
	DefaultQuotaBytes  int64  `json:"default_quota_bytes"`
	StoryTTLHours      int    `json:"story_ttl_hours"`
	MessageRetentionDays int  `json:"message_retention_days"` // 0 = forever
}

func defaultSettings() ServerSettings {
	return ServerSettings{ServerName: "Asgard", AllowUserBots: true, AllowPublicGroups: true, StoryTTLHours: 24}
}

func (s *Server) settings(ctx context.Context) ServerSettings {
	st := defaultSettings()
	var raw []byte
	if err := s.db.QueryRow(ctx, `SELECT value FROM server_settings WHERE key = 'server'`).Scan(&raw); err == nil {
		json.Unmarshal(raw, &st)
	}
	return st
}

func (s *Server) audit(ctx context.Context, actor uuid.UUID, action, target string, details map[string]any) {
	if details == nil {
		details = map[string]any{}
	}
	s.db.Exec(ctx, `INSERT INTO audit_log(actor_id, action, target, details) VALUES ($1, $2, $3, $4)`,
		nullable(actor), action, target, details)
}

func nullable(id uuid.UUID) *uuid.UUID {
	if id == uuid.Nil {
		return nil
	}
	return &id
}
