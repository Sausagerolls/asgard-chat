package api

import (
	"context"
	"crypto/ed25519"
	"crypto/subtle"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/giantmushroom/asgard-chat/server/internal/auth"
	"github.com/giantmushroom/asgard-chat/server/internal/e2ee"
)

const botKeyLabel = "asgard-bot-device-v1"

type Bot struct {
	User      *User     `json:"user"`
	OwnerID   uuid.UUID `json:"owner_id"`
	Token     string    `json:"token,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

func (s *Server) listBots(w http.ResponseWriter, r *http.Request) error {
	p := me(r)
	rows, err := s.db.Query(r.Context(), `SELECT `+userCols+`, u.bot_owner_id FROM users u WHERE u.is_bot AND (u.bot_owner_id = $1 OR $2) ORDER BY u.created_at`, p.UserID, p.IsAdmin)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := []Bot{}
	for rows.Next() {
		u := &User{}
		var settings []byte
		var owner *uuid.UUID
		if err := rows.Scan(&u.ID, &u.Username, &u.DisplayName, &u.Bio, &u.AvatarMediaID, &u.IsAdmin, &u.IsBot, &u.ServerBot, &u.LastSeenAt, &u.CreatedAt, &settings, &owner); err != nil {
			return err
		}
		b := Bot{User: u, CreatedAt: u.CreatedAt}
		if owner != nil {
			b.OwnerID = *owner
		}
		out = append(out, b)
	}
	writeJSON(w, http.StatusOK, out)
	return rows.Err()
}

func (s *Server) createBot(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Username    string `json:"username"`
		DisplayName string `json:"display_name"`
		ServerSide  bool   `json:"server_side"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	if !p.IsAdmin && (in.ServerSide || !s.settings(ctx).AllowUserBots) {
		return errForbidden
	}
	in.Username = strings.ToLower(strings.TrimSpace(in.Username))
	if !strings.HasSuffix(in.Username, "bot") {
		in.Username += "_bot"
	}
	if !usernameRe.MatchString(in.Username) {
		return badRequest("Bot usernames are 3-32 characters: letters, numbers, underscores and dots.")
	}
	if in.DisplayName == "" {
		in.DisplayName = in.Username
	}
	bot, token, err := s.newBot(ctx, p.UserID, in.Username, in.DisplayName, in.ServerSide)
	if err != nil {
		return err
	}
	s.audit(ctx, p.UserID, "bot.create", in.Username, map[string]any{"server_side": in.ServerSide})
	writeJSON(w, http.StatusCreated, Bot{User: bot, OwnerID: p.UserID, Token: token, CreatedAt: bot.CreatedAt})
	return nil
}

// newBot creates a bot user. Server-side bots get a device whose private keys
// are sealed with the master key; external bots get a token instead.
func (s *Server) newBot(ctx context.Context, owner uuid.UUID, username, display string, serverSide bool) (*User, string, error) {
	if serverSide && len(s.cfg.MasterKey) != 32 {
		return nil, "", errf(http.StatusServiceUnavailable, "master_key_missing", "Set ASGARD_MASTER_KEY to use server-side bots and webhooks.")
	}
	id := uuid.New()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, "", err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `INSERT INTO users(id, username, display_name, is_bot, bot_owner_id, server_bot) VALUES ($1,$2,$3,true,$4,$5)`,
		id, username, trim(display, 64), owner, serverSide); err != nil {
		if strings.Contains(err.Error(), "users_username_key") {
			return nil, "", errf(http.StatusConflict, "username_taken", "That username is taken.")
		}
		return nil, "", err
	}
	var token string
	if serverSide {
		keys, err := e2ee.GenerateDeviceKeys()
		if err != nil {
			return nil, "", err
		}
		secret := append(append([]byte{}, keys.IdentityPrivate[:]...), keys.SigningPrivate...)
		sealed, err := e2ee.SealAtRest(s.cfg.MasterKey, secret, botKeyLabel)
		if err != nil {
			return nil, "", err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO devices(id, user_id, name, platform, identity_key, signing_key, sealed_private) VALUES ($1,$2,'server','bot',$3,$4,$5)`,
			uuid.New(), id, keys.IdentityPublic[:], []byte(keys.SigningPublic), sealed); err != nil {
			return nil, "", err
		}
	} else {
		raw, _ := auth.NewToken()
		token = "bot_" + raw
		hash := auth.HashToken(token)
		if _, err := tx.Exec(ctx, `INSERT INTO sessions(token_hash, user_id, is_bot_token, expires_at) VALUES ($1,$2,true,$3)`,
			hash, id, time.Now().AddDate(100, 0, 0)); err != nil {
			return nil, "", err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, "", err
	}
	u, err := s.loadUser(ctx, id)
	return u, token, err
}

// registerBotDevice lets an external bot publish its keys once.
func (s *Server) registerBotDevice(w http.ResponseWriter, r *http.Request) error {
	p := me(r)
	if !p.IsBot || p.DeviceID != uuid.Nil {
		return errForbidden
	}
	var in deviceIn
	if err := decode(r, &in); err != nil {
		return err
	}
	in.Platform = "web" // validated as a normal client; stored as "bot"
	if err := in.validate(); err != nil {
		return err
	}
	ctx := r.Context()
	id := uuid.New()
	if _, err := s.db.Exec(ctx, `INSERT INTO devices(id, user_id, name, platform, identity_key, signing_key) VALUES ($1,$2,$3,'bot',$4,$5)`,
		id, p.UserID, in.Name, in.IdentityKey, in.SigningKey); err != nil {
		return err
	}
	if _, err := s.db.Exec(ctx, `UPDATE sessions SET device_id = $2 WHERE token_hash = $1`, auth.HashToken(bearer(r)), id); err != nil {
		return err
	}
	s.keysChanged(ctx, p.UserID)
	writeJSON(w, http.StatusCreated, map[string]any{"device_id": id})
	return nil
}

func (s *Server) deleteBot(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "userID")
	if err != nil {
		return err
	}
	p := me(r)
	tag, err := s.db.Exec(r.Context(), `DELETE FROM users WHERE id = $1 AND is_bot AND (bot_owner_id = $2 OR $3)`, id, p.UserID, p.IsAdmin)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return errNotFound
	}
	s.keysChanged(r.Context(), id)
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// ---- webhooks ----

type Webhook struct {
	ID        uuid.UUID `json:"id"`
	Name      string    `json:"name"`
	BotUserID uuid.UUID `json:"bot_user_id"`
	URL       string    `json:"url,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

func (s *Server) listWebhooks(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	m, err := s.membershipOf(ctx, id, p.UserID)
	if err != nil {
		return err
	}
	if !m.can(PermManageWebhooks) {
		return errForbidden
	}
	rows, err := s.db.Query(ctx, `SELECT id, name, bot_user_id, created_at FROM webhooks WHERE conversation_id = $1 ORDER BY created_at`, id)
	if err != nil {
		return err
	}
	hooks, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Webhook, error) {
		var h Webhook
		return h, row.Scan(&h.ID, &h.Name, &h.BotUserID, &h.CreatedAt)
	})
	if err != nil {
		return err
	}
	if hooks == nil {
		hooks = []Webhook{}
	}
	writeJSON(w, http.StatusOK, hooks)
	return nil
}

func (s *Server) createWebhook(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	var in struct {
		Name string `json:"name"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	m, err := s.membershipOf(ctx, id, p.UserID)
	if err != nil {
		return err
	}
	if !m.can(PermManageWebhooks) || m.Kind == "dm" {
		return errForbidden
	}
	if in.Name = trim(in.Name, 64); in.Name == "" {
		in.Name = "Webhook"
	}
	bot, _, err := s.newBot(ctx, p.UserID, "hook_"+strings.ToLower(auth.RandomCode(2)[:4])+"_bot", in.Name, true)
	if err != nil {
		return err
	}
	if _, err := s.db.Exec(ctx, `INSERT INTO members(conversation_id, user_id, role) VALUES ($1,$2,'member')`, id, bot.ID); err != nil {
		return err
	}
	secret, hash := auth.NewToken()
	hookID := uuid.New()
	if _, err := s.db.Exec(ctx, `INSERT INTO webhooks(id, conversation_id, bot_user_id, name, secret_hash, created_by) VALUES ($1,$2,$3,$4,$5,$6)`,
		hookID, id, bot.ID, in.Name, hash, p.UserID); err != nil {
		return err
	}
	s.postSystem(ctx, id, p.UserID, map[string]any{"event": "webhook_added", "name": in.Name, "user_id": bot.ID})
	s.keysChanged(ctx, bot.ID)
	s.audit(ctx, p.UserID, "webhook.create", hookID.String(), map[string]any{"conversation": id})
	writeJSON(w, http.StatusCreated, Webhook{ID: hookID, Name: in.Name, BotUserID: bot.ID, CreatedAt: time.Now(),
		URL: s.cfg.PublicURL + "/api/v1/hooks/" + hookID.String() + "/" + secret})
	return nil
}

func (s *Server) deleteWebhook(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	hookID, err := pathUUID(r, "hookID")
	if err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	m, err := s.membershipOf(ctx, id, p.UserID)
	if err != nil {
		return err
	}
	if !m.can(PermManageWebhooks) {
		return errForbidden
	}
	var bot uuid.UUID
	if err := s.db.QueryRow(ctx, `DELETE FROM webhooks WHERE id = $1 AND conversation_id = $2 RETURNING bot_user_id`, hookID, id).Scan(&bot); err != nil {
		return errNotFound
	}
	s.db.Exec(ctx, `DELETE FROM users WHERE id = $1 AND server_bot`, bot)
	s.keysChanged(ctx, bot)
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) incomingWebhook(w http.ResponseWriter, r *http.Request) error {
	hookID, err := pathUUID(r, "hookID")
	if err != nil {
		return err
	}
	var in struct {
		Text     string `json:"text"`
		Markdown bool   `json:"markdown"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	if in.Text = strings.TrimSpace(in.Text); in.Text == "" {
		return badRequest("text is required")
	}
	ctx := r.Context()
	var conv, bot uuid.UUID
	var hash []byte
	if err := s.db.QueryRow(ctx, `SELECT conversation_id, bot_user_id, secret_hash FROM webhooks WHERE id = $1`, hookID).Scan(&conv, &bot, &hash); err != nil {
		return errNotFound
	}
	if subtle.ConstantTimeCompare(hash, auth.HashToken(chiParam(r, "secret"))) != 1 {
		return errNotFound
	}
	content, _ := json.Marshal(map[string]any{"v": 1, "type": "text", "text": trim(in.Text, 8000), "markdown": in.Markdown})
	env, err := s.sendAsServerBot(ctx, bot, conv, content)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": env.ID})
	return nil
}

// sendAsServerBot encrypts content for every member device and delivers it.
func (s *Server) sendAsServerBot(ctx context.Context, bot, conv uuid.UUID, content []byte) (*Envelope, error) {
	var device uuid.UUID
	var sealed []byte
	if err := s.db.QueryRow(ctx, `SELECT id, sealed_private FROM devices WHERE user_id = $1 AND sealed_private IS NOT NULL LIMIT 1`, bot).Scan(&device, &sealed); err != nil {
		return nil, err
	}
	secret, err := e2ee.OpenAtRest(s.cfg.MasterKey, sealed, botKeyLabel)
	if err != nil || len(secret) != 32+ed25519.PrivateKeySize {
		return nil, errf(http.StatusInternalServerError, "bot_keys", "Bot keys could not be opened. Was ASGARD_MASTER_KEY changed?")
	}
	signing := ed25519.PrivateKey(secret[32:])
	clientID := uuid.New()
	aad := e2ee.AAD(conv.String(), device.String(), clientID.String())
	key, ct, err := e2ee.Seal(content, aad)
	if err != nil {
		return nil, err
	}
	devices, err := s.devicesOf(ctx, s.memberIDs(ctx, conv))
	if err != nil {
		return nil, err
	}
	keys := map[uuid.UUID][]byte{}
	for _, d := range devices {
		if d.ID == device {
			continue
		}
		wk, err := e2ee.Wrap(key, d.IdentityKey, clientID.String())
		if err != nil {
			return nil, err
		}
		keys[d.ID] = wk
	}
	env, _, err := s.deliver(ctx, bot, device, conv, &sendRequest{ClientID: clientID, Kind: "msg", Ciphertext: ct,
		Signature: e2ee.Sign(signing, aad, ct), Alg: "fanout-v1", Keys: keys})
	return env, err
}
