package api

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/giantmushroom/asgard-chat/server/internal/auth"
	"github.com/giantmushroom/asgard-chat/server/internal/realtime"
)

var usernameRe = regexp.MustCompile(`^[a-z0-9_.]{3,32}$`)

var platforms = map[string]bool{"ios": true, "ipados": true, "macos": true, "watchos": true, "visionos": true,
	"android": true, "wearos": true, "web": true, "bot": true,
	"admin": true} // admin = web admin panel session; never receives messages

type deviceIn struct {
	Name        string `json:"name"`
	Platform    string `json:"platform"`
	IdentityKey []byte `json:"identity_key"`
	SigningKey  []byte `json:"signing_key"`
}

func (d *deviceIn) validate() error {
	if len(d.IdentityKey) != 32 || len(d.SigningKey) != ed25519.PublicKeySize {
		return badRequest("Device keys must be a 32-byte X25519 identity key and a 32-byte Ed25519 signing key.")
	}
	if !platforms[d.Platform] || d.Platform == "bot" {
		return badRequest("Unknown platform.")
	}
	if len(d.Name) > 64 {
		d.Name = d.Name[:64]
	}
	return nil
}

type User struct {
	ID            uuid.UUID      `json:"id"`
	Username      string         `json:"username"`
	DisplayName   string         `json:"display_name"`
	Bio           string         `json:"bio"`
	AvatarMediaID *uuid.UUID     `json:"avatar_media_id"`
	IsAdmin       bool           `json:"is_admin"`
	IsBot         bool           `json:"is_bot"`
	ServerBot     bool           `json:"server_bot"`
	Online        bool           `json:"online"`
	LastSeenAt    *time.Time     `json:"last_seen_at"`
	CreatedAt     time.Time      `json:"created_at"`
	Settings      map[string]any `json:"settings,omitempty"`
}

const userCols = `u.id, u.username, u.display_name, u.bio, u.avatar_media_id, u.is_admin, u.is_bot, u.server_bot, u.last_seen_at, u.created_at, u.settings`

func scanUser(row pgx.Row) (*User, error) {
	u := &User{}
	var settings []byte
	if err := row.Scan(&u.ID, &u.Username, &u.DisplayName, &u.Bio, &u.AvatarMediaID, &u.IsAdmin, &u.IsBot, &u.ServerBot, &u.LastSeenAt, &u.CreatedAt, &settings); err != nil {
		return nil, err
	}
	json.Unmarshal(settings, &u.Settings)
	return u, nil
}

// publicView hides private settings and, if the user opted out, presence.
func (s *Server) publicView(u *User) *User {
	u.Online = s.hub.UserOnline(u.ID)
	if hide, _ := u.Settings["hide_last_seen"].(bool); hide {
		u.LastSeenAt, u.Online = nil, false
	}
	u.Settings = nil
	return u
}

type session struct {
	Token  string    `json:"token"`
	User   *User     `json:"user"`
	Device uuid.UUID `json:"device_id"`
}

func (s *Server) newSession(ctx context.Context, tx pgx.Tx, user uuid.UUID, d *deviceIn) (string, uuid.UUID, error) {
	deviceID := uuid.New()
	if _, err := tx.Exec(ctx, `INSERT INTO devices(id, user_id, name, platform, identity_key, signing_key) VALUES ($1,$2,$3,$4,$5,$6)`,
		deviceID, user, d.Name, d.Platform, d.IdentityKey, d.SigningKey); err != nil {
		return "", uuid.Nil, err
	}
	tok, hash := auth.NewToken()
	if _, err := tx.Exec(ctx, `INSERT INTO sessions(token_hash, user_id, device_id, expires_at) VALUES ($1,$2,$3,$4)`,
		hash, user, deviceID, time.Now().Add(s.cfg.SessionTTL)); err != nil {
		return "", uuid.Nil, err
	}
	return tok, deviceID, nil
}

// afterNewDevice tells the user's other devices and every contact that a new
// device exists, so they start including it in fan-out and update safety numbers.
func (s *Server) afterNewDevice(ctx context.Context, user, device uuid.UUID) {
	peers := s.peersOf(ctx, user)
	s.hub.ToUsers(append(peers, user), realtime.Event{Type: "device.added", Data: map[string]any{"user_id": user, "device_id": device}}, device)
}

func (s *Server) register(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Invite      string   `json:"invite"`
		Username    string   `json:"username"`
		Password    string   `json:"password"`
		DisplayName string   `json:"display_name"`
		Device      deviceIn `json:"device"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	in.Username = strings.ToLower(strings.TrimSpace(in.Username))
	if !usernameRe.MatchString(in.Username) {
		return badRequest("Usernames are 3-32 characters: letters, numbers, underscores and dots.")
	}
	if len(in.Password) < 10 {
		return badRequest("Use a password with at least 10 characters.")
	}
	if err := in.Device.validate(); err != nil {
		return err
	}
	ctx := r.Context()
	hash, err := auth.HashPassword(in.Password)
	if err != nil {
		return err
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	var userCount int
	tx.QueryRow(ctx, `SELECT count(*) FROM users WHERE NOT is_bot`).Scan(&userCount)
	makeAdmin := userCount == 0
	open := s.cfg.OpenRegistration || s.settings(ctx).OpenRegistration
	in.Invite = strings.ToUpper(strings.TrimSpace(in.Invite))
	if in.Invite != "" || !open {
		var inviteAdmin bool
		err := tx.QueryRow(ctx, `
			UPDATE invites SET uses = uses + 1
			WHERE code = $1 AND uses < max_uses AND (expires_at IS NULL OR expires_at > now())
			RETURNING make_admin`, in.Invite).Scan(&inviteAdmin)
		if err != nil {
			return errf(http.StatusForbidden, "invite_invalid", "That invite code is not valid or has been used up.")
		}
		makeAdmin = makeAdmin || inviteAdmin
	}
	if in.DisplayName == "" {
		in.DisplayName = in.Username
	}
	userID := uuid.New()
	quota := s.settings(ctx).DefaultQuotaBytes
	if _, err := tx.Exec(ctx, `INSERT INTO users(id, username, display_name, password_hash, is_admin, storage_quota) VALUES ($1,$2,$3,$4,$5,$6)`,
		userID, in.Username, trim(in.DisplayName, 64), hash, makeAdmin, quota); err != nil {
		if strings.Contains(err.Error(), "users_username_key") {
			return errf(http.StatusConflict, "username_taken", "That username is taken.")
		}
		return err
	}
	tok, deviceID, err := s.newSession(ctx, tx, userID, &in.Device)
	if err != nil {
		return err
	}
	// Everyone gets a private "Saved Messages" conversation.
	saved := uuid.New()
	if _, err := tx.Exec(ctx, `INSERT INTO conversations(id, kind, title, created_by, dm_key) VALUES ($1, 'saved', 'Saved Messages', $2, $3)`,
		saved, userID, "saved:"+userID.String()); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO members(conversation_id, user_id, role) VALUES ($1, $2, 'owner')`, saved, userID); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	s.audit(ctx, userID, "user.register", in.Username, map[string]any{"invite": in.Invite, "admin": makeAdmin})
	u, err := s.loadUser(ctx, userID)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, session{Token: tok, User: u, Device: deviceID})
	return nil
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Username string   `json:"username"`
		Password string   `json:"password"`
		Device   deviceIn `json:"device"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	if err := in.Device.validate(); err != nil {
		return err
	}
	ctx := r.Context()
	var id uuid.UUID
	var hash string
	var disabled, isBot bool
	err := s.db.QueryRow(ctx, `SELECT id, password_hash, disabled, is_bot FROM users WHERE username = $1`,
		strings.ToLower(strings.TrimSpace(in.Username))).Scan(&id, &hash, &disabled, &isBot)
	bad := errf(http.StatusUnauthorized, "bad_credentials", "Wrong username or password.")
	if err != nil {
		auth.HashPassword(in.Password) // equalize timing for unknown users
		return bad
	}
	if ok, _ := auth.VerifyPassword(in.Password, hash); !ok || isBot {
		return bad
	}
	if disabled {
		return errf(http.StatusForbidden, "account_disabled", "This account has been disabled by an administrator.")
	}
	if in.Device.Platform == "admin" {
		var admin bool
		s.db.QueryRow(ctx, `SELECT is_admin FROM users WHERE id = $1`, id).Scan(&admin)
		if !admin {
			return errForbidden
		}
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	tok, deviceID, err := s.newSession(ctx, tx, id, &in.Device)
	if err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	if in.Device.Platform == "admin" {
		s.db.Exec(ctx, `UPDATE sessions SET expires_at = now() + interval '12 hours' WHERE device_id = $1`, deviceID)
	} else {
		s.afterNewDevice(ctx, id, deviceID)
	}
	s.audit(ctx, id, "user.login", in.Device.Platform, map[string]any{"device": deviceID})
	u, err := s.loadUser(ctx, id)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, session{Token: tok, User: u, Device: deviceID})
	return nil
}

func (s *Server) logout(w http.ResponseWriter, r *http.Request) error {
	p := me(r)
	// Deleting the device removes its sessions and pending deliveries.
	if _, err := s.db.Exec(r.Context(), `DELETE FROM devices WHERE id = $1`, p.DeviceID); err != nil {
		return err
	}
	s.keysChanged(r.Context(), p.UserID)
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// ---- device linking (QR code from an existing device) ----

func (s *Server) createDeviceLink(w http.ResponseWriter, r *http.Request) error {
	p := me(r)
	code := auth.RandomCode(4)
	exp := time.Now().Add(5 * time.Minute)
	if _, err := s.db.Exec(r.Context(), `INSERT INTO device_links(code, user_id, created_by_device, expires_at) VALUES ($1,$2,$3,$4)`,
		code, p.UserID, p.DeviceID, exp); err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"code": code, "expires_at": exp,
		"uri": "asgard://link?host=" + strings.TrimPrefix(strings.TrimPrefix(s.cfg.PublicURL, "https://"), "http://") + "&code=" + code,
	})
	return nil
}

func (s *Server) claimDeviceLink(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Code   string   `json:"code"`
		Device deviceIn `json:"device"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	if err := in.Device.validate(); err != nil {
		return err
	}
	ctx := r.Context()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var user, origin uuid.UUID
	if err := tx.QueryRow(ctx, `DELETE FROM device_links WHERE code = $1 AND expires_at > now() RETURNING user_id, created_by_device`,
		strings.ToUpper(strings.TrimSpace(in.Code))).Scan(&user, &origin); err != nil {
		return errf(http.StatusForbidden, "link_invalid", "That code has expired. Show a new QR code on your other device.")
	}
	tok, deviceID, err := s.newSession(ctx, tx, user, &in.Device)
	if err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	s.afterNewDevice(ctx, user, deviceID)
	s.hub.ToDevice(origin, realtime.Event{Type: "device.linked", Data: map[string]any{"device_id": deviceID, "name": in.Device.Name,
		"identity_key": in.Device.IdentityKey, "signing_key": in.Device.SigningKey}})
	u, err := s.loadUser(ctx, user)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, session{Token: tok, User: u, Device: deviceID})
	return nil
}

// ---- profile ----

func (s *Server) loadUser(ctx context.Context, id uuid.UUID) (*User, error) {
	return scanUser(s.db.QueryRow(ctx, `SELECT `+userCols+` FROM users u WHERE u.id = $1`, id))
}

func (s *Server) getMe(w http.ResponseWriter, r *http.Request) error {
	u, err := s.loadUser(r.Context(), me(r).UserID)
	if err != nil {
		return err
	}
	u.Online = true
	writeJSON(w, http.StatusOK, u)
	return nil
}

func (s *Server) updateMe(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		DisplayName   *string        `json:"display_name"`
		Bio           *string        `json:"bio"`
		AvatarMediaID *uuid.UUID     `json:"avatar_media_id"`
		ClearAvatar   bool           `json:"clear_avatar"`
		Settings      map[string]any `json:"settings"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	if in.DisplayName != nil {
		s.db.Exec(ctx, `UPDATE users SET display_name = $2 WHERE id = $1`, p.UserID, trim(*in.DisplayName, 64))
	}
	if in.Bio != nil {
		s.db.Exec(ctx, `UPDATE users SET bio = $2 WHERE id = $1`, p.UserID, trim(*in.Bio, 280))
	}
	if in.AvatarMediaID != nil || in.ClearAvatar {
		s.db.Exec(ctx, `UPDATE users SET avatar_media_id = $2 WHERE id = $1`, p.UserID, in.AvatarMediaID)
	}
	if in.Settings != nil {
		// Known keys: hide_last_seen, read_receipts, typing_indicators, who_can_add (everyone|contacts)
		s.db.Exec(ctx, `UPDATE users SET settings = settings || $2 WHERE id = $1`, p.UserID, in.Settings)
	}
	u, err := s.loadUser(ctx, p.UserID)
	if err != nil {
		return err
	}
	public := *u
	s.hub.ToUsers(append(s.peersOf(ctx, p.UserID), p.UserID), realtime.Event{Type: "user.updated", Data: s.publicView(&public)}, uuid.Nil)
	writeJSON(w, http.StatusOK, u)
	return nil
}

func (s *Server) changePassword(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Current string `json:"current"`
		New     string `json:"new"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	if len(in.New) < 10 {
		return badRequest("Use a password with at least 10 characters.")
	}
	ctx, p := r.Context(), me(r)
	var hash string
	if err := s.db.QueryRow(ctx, `SELECT password_hash FROM users WHERE id = $1`, p.UserID).Scan(&hash); err != nil {
		return err
	}
	if ok, _ := auth.VerifyPassword(in.Current, hash); !ok {
		return errf(http.StatusUnauthorized, "bad_credentials", "Current password is wrong.")
	}
	nh, err := auth.HashPassword(in.New)
	if err != nil {
		return err
	}
	_, err = s.db.Exec(ctx, `UPDATE users SET password_hash = $2 WHERE id = $1`, p.UserID, nh)
	if err != nil {
		return err
	}
	s.audit(ctx, p.UserID, "user.password", "", nil)
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) setPushToken(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Kind      string `json:"kind"` // apns | fcm | ""
		Token     string `json:"token"`
		VoIPToken string `json:"voip_token"`
		Env       string `json:"env"` // development | production
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	if in.Kind != "apns" && in.Kind != "fcm" && in.Kind != "relay" && in.Kind != "" {
		return badRequest("kind must be apns, fcm or relay")
	}
	if in.Env != "development" && in.Env != "production" {
		in.Env = ""
	}
	_, err := s.db.Exec(r.Context(), `UPDATE devices SET push_kind = $2, push_token = $3, voip_token = $4, push_env = $5 WHERE id = $1`,
		me(r).DeviceID, in.Kind, in.Token, in.VoIPToken, in.Env)
	if err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

type Device struct {
	ID           uuid.UUID `json:"id"`
	UserID       uuid.UUID `json:"user_id"`
	Name         string    `json:"name,omitempty"`
	Platform     string    `json:"platform,omitempty"`
	IdentityKey  []byte    `json:"identity_key"`
	SigningKey   []byte    `json:"signing_key"`
	CreatedAt    time.Time `json:"created_at"`
	LastActiveAt time.Time `json:"last_active_at,omitempty"`
	Current      bool      `json:"current,omitempty"`
}

func (s *Server) listMyDevices(w http.ResponseWriter, r *http.Request) error {
	p := me(r)
	rows, err := s.db.Query(r.Context(), `SELECT id, user_id, name, platform, identity_key, signing_key, created_at, last_active_at FROM devices WHERE user_id = $1 AND platform <> 'history' ORDER BY created_at`, p.UserID)
	if err != nil {
		return err
	}
	devices, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Device, error) {
		var d Device
		err := row.Scan(&d.ID, &d.UserID, &d.Name, &d.Platform, &d.IdentityKey, &d.SigningKey, &d.CreatedAt, &d.LastActiveAt)
		d.Current = d.ID == p.DeviceID
		return d, err
	})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, devices)
	return nil
}

func (s *Server) revokeDevice(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "deviceID")
	if err != nil {
		return err
	}
	p := me(r)
	tag, err := s.db.Exec(r.Context(), `DELETE FROM devices WHERE id = $1 AND user_id = $2`, id, p.UserID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return errNotFound
	}
	s.hub.DisconnectDevice(id)
	s.keysChanged(r.Context(), p.UserID)
	s.audit(r.Context(), p.UserID, "device.revoke", id.String(), nil)
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// keysChanged tells peers to refresh this user's device list.
func (s *Server) keysChanged(ctx context.Context, user uuid.UUID) {
	s.hub.ToUsers(append(s.peersOf(ctx, user), user), realtime.Event{Type: "keys.changed", Data: map[string]any{"user_id": user}}, uuid.Nil)
}

// peersOf returns every user who shares a conversation with user.
func (s *Server) peersOf(ctx context.Context, user uuid.UUID) []uuid.UUID {
	rows, err := s.db.Query(ctx, `
		SELECT DISTINCT m2.user_id FROM members m1
		JOIN members m2 ON m2.conversation_id = m1.conversation_id
		JOIN conversations c ON c.id = m1.conversation_id
		WHERE m1.user_id = $1 AND m2.user_id <> $1 AND c.kind IN ('dm', 'group', 'community')`, user)
	if err != nil {
		return nil
	}
	ids, _ := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	return ids
}

func trim(s string, n int) string {
	s = strings.TrimSpace(s)
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}
