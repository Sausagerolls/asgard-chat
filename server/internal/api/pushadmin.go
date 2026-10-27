package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/giantmushroom/asgard-chat/server/internal/e2ee"
	"github.com/giantmushroom/asgard-chat/server/internal/push"
)

// Push credentials can come from files named in the environment, or be
// uploaded by an admin in the web panel. Uploaded credentials are encrypted
// with the server master key and take precedence over files.

const (
	apnsSettingsKey = "push_apns"
	fcmSettingsKey  = "push_fcm"
	pushKeyLabel    = "asgard-push-credential-v1"
)

type storedAPNs struct {
	Key       []byte    `json:"key"` // sealed .p8 contents
	KeyID     string    `json:"key_id"`
	TeamID    string    `json:"team_id"`
	Topic     string    `json:"topic"`
	UpdatedAt time.Time `json:"updated_at"`
}

type storedFCM struct {
	Credentials []byte    `json:"credentials"` // sealed service-account JSON
	ProjectID   string    `json:"project_id"`
	UpdatedAt   time.Time `json:"updated_at"`
}

type pushSource struct {
	Configured bool       `json:"configured"`
	Source     string     `json:"source,omitempty"` // admin | environment
	KeyID      string     `json:"key_id,omitempty"`
	TeamID     string     `json:"team_id,omitempty"`
	Topic      string     `json:"topic,omitempty"`
	ProjectID  string     `json:"project_id,omitempty"`
	UpdatedAt  *time.Time `json:"updated_at,omitempty"`
}

// LoadPushCredentials configures the push sender from environment files and
// then any admin-uploaded credentials, which win.
func (s *Server) LoadPushCredentials(ctx context.Context) {
	if s.cfg.APNsKeyPath != "" {
		if raw, err := os.ReadFile(s.cfg.APNsKeyPath); err != nil {
			slog.Error("apns key file", "err", err)
		} else if err := s.push.ConfigureAPNs(raw, s.cfg.APNsKeyID, s.cfg.APNsTeamID, s.cfg.APNsTopic); err != nil {
			slog.Error("apns key file", "err", err)
		}
	}
	if s.cfg.FCMCredsPath != "" {
		if raw, err := os.ReadFile(s.cfg.FCMCredsPath); err != nil {
			slog.Error("fcm credentials file", "err", err)
		} else if err := s.push.ConfigureFCM(raw); err != nil {
			slog.Error("fcm credentials file", "err", err)
		}
	}
	if a, ok := s.loadAPNs(ctx); ok {
		if key, err := e2ee.OpenAtRest(s.cfg.MasterKey, a.Key, pushKeyLabel); err != nil {
			slog.Error("stored apns key can't be decrypted; was the master key changed?")
		} else if err := s.push.ConfigureAPNs(key, a.KeyID, a.TeamID, a.Topic); err != nil {
			slog.Error("stored apns key", "err", err)
		}
	}
	if f, ok := s.loadFCM(ctx); ok {
		if creds, err := e2ee.OpenAtRest(s.cfg.MasterKey, f.Credentials, pushKeyLabel); err != nil {
			slog.Error("stored fcm credentials can't be decrypted; was the master key changed?")
		} else if err := s.push.ConfigureFCM(creds); err != nil {
			slog.Error("stored fcm credentials", "err", err)
		}
	}
	if !s.push.Any() {
		slog.Warn("push notifications disabled: upload APNs/FCM credentials in the admin panel")
	}
}

func (s *Server) loadSetting(ctx context.Context, key string, out any) bool {
	var raw []byte
	if s.db.QueryRow(ctx, `SELECT value FROM server_settings WHERE key = $1`, key).Scan(&raw) != nil {
		return false
	}
	return json.Unmarshal(raw, out) == nil
}

func (s *Server) saveSetting(ctx context.Context, key string, v any) error {
	raw, _ := json.Marshal(v)
	_, err := s.db.Exec(ctx, `INSERT INTO server_settings(key, value) VALUES ($1, $2) ON CONFLICT (key) DO UPDATE SET value = $2`, key, raw)
	return err
}

func (s *Server) loadAPNs(ctx context.Context) (storedAPNs, bool) {
	var a storedAPNs
	ok := s.loadSetting(ctx, apnsSettingsKey, &a)
	return a, ok && len(a.Key) > 0
}

func (s *Server) loadFCM(ctx context.Context) (storedFCM, bool) {
	var f storedFCM
	ok := s.loadSetting(ctx, fcmSettingsKey, &f)
	return f, ok && len(f.Credentials) > 0
}

func (s *Server) adminPushStatus(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	apnsOn, fcmOn := s.push.Enabled()
	ap := pushSource{Configured: apnsOn}
	if a, ok := s.loadAPNs(ctx); ok {
		ap.Source, ap.KeyID, ap.TeamID, ap.Topic, ap.UpdatedAt = "admin", a.KeyID, a.TeamID, a.Topic, &a.UpdatedAt
	} else if s.cfg.APNsKeyPath != "" {
		ap.Source, ap.KeyID, ap.TeamID, ap.Topic = "environment", s.cfg.APNsKeyID, s.cfg.APNsTeamID, s.cfg.APNsTopic
	}
	fp := pushSource{Configured: fcmOn}
	if f, ok := s.loadFCM(ctx); ok {
		fp.Source, fp.ProjectID, fp.UpdatedAt = "admin", f.ProjectID, &f.UpdatedAt
	} else if s.cfg.FCMCredsPath != "" {
		fp.Source = "environment"
	}
	var devices struct{ APNs, FCM int }
	s.db.QueryRow(ctx, `SELECT count(*) FILTER (WHERE push_kind = 'apns' AND push_token <> ''),
		count(*) FILTER (WHERE push_kind = 'fcm' AND push_token <> '') FROM devices`).Scan(&devices.APNs, &devices.FCM)
	writeJSON(w, http.StatusOK, map[string]any{
		"apns": ap, "fcm": fp, "default_topic": s.cfg.APNsTopic,
		"devices":   map[string]int{"apns": devices.APNs, "fcm": devices.FCM},
		"can_store": len(s.cfg.MasterKey) == 32,
	})
	return nil
}

func (s *Server) requireMasterKey() error {
	if len(s.cfg.MasterKey) != 32 {
		return errf(http.StatusPreconditionFailed, "no_master_key", "Set ASGARD_MASTER_KEY on the server so uploaded keys can be stored encrypted.")
	}
	return nil
}

func (s *Server) adminSetAPNs(w http.ResponseWriter, r *http.Request) error {
	if err := s.requireMasterKey(); err != nil {
		return err
	}
	var in struct {
		Key    string `json:"key"` // .p8 file contents
		KeyID  string `json:"key_id"`
		TeamID string `json:"team_id"`
		Topic  string `json:"topic"` // app bundle ID
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	in.KeyID, in.TeamID = strings.ToUpper(strings.TrimSpace(in.KeyID)), strings.ToUpper(strings.TrimSpace(in.TeamID))
	in.Topic = strings.TrimSpace(in.Topic)
	if in.Topic == "" {
		in.Topic = s.cfg.APNsTopic
	}
	key := []byte(strings.TrimSpace(in.Key) + "\n")
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	if err := push.VerifyAPNs(ctx, key, in.KeyID, in.TeamID, in.Topic); err != nil {
		return errf(http.StatusUnprocessableEntity, "apns_rejected", err.Error())
	}
	sealed, err := e2ee.SealAtRest(s.cfg.MasterKey, key, pushKeyLabel)
	if err != nil {
		return err
	}
	if err := s.saveSetting(ctx, apnsSettingsKey, storedAPNs{Key: sealed, KeyID: in.KeyID, TeamID: in.TeamID, Topic: in.Topic, UpdatedAt: time.Now()}); err != nil {
		return err
	}
	if err := s.push.ConfigureAPNs(key, in.KeyID, in.TeamID, in.Topic); err != nil {
		return err
	}
	s.audit(ctx, me(r).UserID, "admin.push.apns.set", in.KeyID, map[string]any{"team_id": in.TeamID, "topic": in.Topic})
	return s.adminPushStatus(w, r)
}

func (s *Server) adminDeleteAPNs(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	s.db.Exec(ctx, `DELETE FROM server_settings WHERE key = $1`, apnsSettingsKey)
	s.push.DisableAPNs()
	s.LoadPushCredentials(ctx) // fall back to environment files, if any
	s.audit(ctx, me(r).UserID, "admin.push.apns.delete", "", nil)
	return s.adminPushStatus(w, r)
}

func (s *Server) adminSetFCM(w http.ResponseWriter, r *http.Request) error {
	if err := s.requireMasterKey(); err != nil {
		return err
	}
	var in struct {
		Credentials string `json:"credentials"` // service-account JSON
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	creds := []byte(strings.TrimSpace(in.Credentials))
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	project, err := push.VerifyFCM(ctx, creds)
	if err != nil {
		return errf(http.StatusUnprocessableEntity, "fcm_rejected", err.Error())
	}
	sealed, err := e2ee.SealAtRest(s.cfg.MasterKey, creds, pushKeyLabel)
	if err != nil {
		return err
	}
	if err := s.saveSetting(ctx, fcmSettingsKey, storedFCM{Credentials: sealed, ProjectID: project, UpdatedAt: time.Now()}); err != nil {
		return err
	}
	if err := s.push.ConfigureFCM(creds); err != nil {
		return err
	}
	s.audit(ctx, me(r).UserID, "admin.push.fcm.set", project, nil)
	return s.adminPushStatus(w, r)
}

func (s *Server) adminDeleteFCM(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	s.db.Exec(ctx, `DELETE FROM server_settings WHERE key = $1`, fcmSettingsKey)
	s.push.DisableFCM()
	s.LoadPushCredentials(ctx)
	s.audit(ctx, me(r).UserID, "admin.push.fcm.delete", "", nil)
	return s.adminPushStatus(w, r)
}

// adminTestPush sends a visible notification to every device of the caller.
func (s *Server) adminTestPush(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	rows, err := s.db.Query(ctx, `SELECT id, name, push_kind, push_token, push_env FROM devices WHERE user_id = $1`, me(r).UserID)
	if err != nil {
		return err
	}
	type result struct {
		DeviceID uuid.UUID `json:"device_id"`
		Name     string    `json:"name"`
		Status   string    `json:"status"` // sent | no_token | failed
		Error    string    `json:"error,omitempty"`
	}
	type dev struct {
		id                     uuid.UUID
		name, kind, token, env string
	}
	var devs []dev
	for rows.Next() {
		var d dev
		if rows.Scan(&d.id, &d.name, &d.kind, &d.token, &d.env) == nil {
			devs = append(devs, d)
		}
	}
	rows.Close()
	out := []result{}
	for _, d := range devs {
		res := result{DeviceID: d.id, Name: d.name, Status: "sent"}
		if d.token == "" {
			res.Status = "no_token"
		} else if err := s.push.Send(ctx, d.kind, d.token, d.env, push.Notification{Kind: push.Alert,
			Title: "Asgard", Body: "Push notifications are working 🎉", Data: map[string]any{"test": "1"}}); err != nil {
			res.Status, res.Error = "failed", err.Error()
		}
		out = append(out, res)
	}
	writeJSON(w, http.StatusOK, out)
	return nil
}

// ---- Push relay ----

const relaySettingsKey = "push_relay"

type storedRelay struct {
	URL      string `json:"url"`
	ServerID string `json:"server_id"`
	Secret   []byte `json:"secret"` // sealed with the master key
}

// relayInfo tells apps where to register their push tokens, or nil.
func (s *Server) relayInfo() map[string]string {
	c := s.push.Relay()
	if c == nil {
		return nil
	}
	return map[string]string{"url": c.URL, "server_id": c.ServerID}
}

// StartPushRelay registers this server with the push relay once (keeping the
// id and secret for good) and retries in the background until the relay answers.
func (s *Server) StartPushRelay(ctx context.Context) {
	url := s.cfg.PushRelayURL
	if url == "" || len(s.cfg.MasterKey) != 32 {
		return
	}
	client := func(id, secret string) *push.RelayClient {
		c := push.NewRelayClient(url, id, secret)
		c.OnAuthFailure = func() {
			slog.Warn("push relay rejected this server; registering again", "relay", url)
			s.db.Exec(context.WithoutCancel(ctx), `DELETE FROM server_settings WHERE key = $1`, relaySettingsKey)
			s.StartPushRelay(ctx)
		}
		return c
	}
	var st storedRelay
	if s.loadSetting(ctx, relaySettingsKey, &st) && st.URL == url && st.ServerID != "" {
		if secret, err := e2ee.OpenAtRest(s.cfg.MasterKey, st.Secret, pushKeyLabel); err == nil {
			s.push.ConfigureRelay(client(st.ServerID, string(secret)))
			return
		}
	}
	go func() {
		wait := 30 * time.Second
		for {
			id, secret, err := push.RegisterServer(ctx, url)
			if err == nil {
				sealed, _ := e2ee.SealAtRest(s.cfg.MasterKey, []byte(secret), pushKeyLabel)
				s.saveSetting(ctx, relaySettingsKey, storedRelay{URL: url, ServerID: id, Secret: sealed})
				s.push.ConfigureRelay(client(id, secret))
				slog.Info("registered with push relay", "relay", url, "server", id)
				return
			}
			slog.Warn("push relay unavailable; retrying", "relay", url, "err", err, "in", wait)
			select {
			case <-ctx.Done():
				return
			case <-time.After(wait):
			}
			wait = min(wait*2, time.Hour)
		}
	}()
}
