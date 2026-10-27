package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/giantmushroom/asgard-chat/server/internal/auth"
)

func (s *Server) adminStats(w http.ResponseWriter, r *http.Request) error {
	ctx := r.Context()
	st := map[string]any{}
	var users, bots, devices, convs, messages, stories int64
	var mediaBytes int64
	s.db.QueryRow(ctx, `SELECT
		(SELECT count(*) FROM users WHERE NOT is_bot), (SELECT count(*) FROM users WHERE is_bot),
		(SELECT count(*) FROM devices), (SELECT count(*) FROM conversations WHERE kind <> 'saved'),
		(SELECT count(*) FROM messages), (SELECT count(*) FROM stories WHERE expires_at > now()),
		(SELECT coalesce(sum(size), 0) FROM media)`).Scan(&users, &bots, &devices, &convs, &messages, &stories, &mediaBytes)
	onlineDevices, onlineUsers := s.hub.Stats()
	var dbSize int64
	s.db.QueryRow(ctx, `SELECT pg_database_size(current_database())`).Scan(&dbSize)
	st["users"], st["bots"], st["devices"], st["conversations"] = users, bots, devices, convs
	st["messages"], st["active_stories"], st["media_bytes"], st["database_bytes"] = messages, stories, mediaBytes, dbSize
	st["online_users"], st["online_devices"] = onlineUsers, onlineDevices
	st["version"], st["push_enabled"], st["calls_enabled"] = Version, s.cfg.PushEnabled(), s.cfg.CallsEnabled()
	writeJSON(w, http.StatusOK, st)
	return nil
}

type AdminUser struct {
	User
	Disabled     bool  `json:"disabled"`
	DeviceCount  int   `json:"device_count"`
	StorageUsed  int64 `json:"storage_used"`
	StorageQuota int64 `json:"storage_quota"`
}

func (s *Server) adminUsers(w http.ResponseWriter, r *http.Request) error {
	rows, err := s.db.Query(r.Context(), `SELECT `+userCols+`, u.disabled,
		(SELECT count(*) FROM devices d WHERE d.user_id = u.id),
		(SELECT coalesce(sum(size), 0) FROM media m WHERE m.owner_id = u.id), u.storage_quota
		FROM users u ORDER BY u.is_bot, u.created_at`)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := []AdminUser{}
	for rows.Next() {
		var a AdminUser
		var settings []byte
		if err := rows.Scan(&a.ID, &a.Username, &a.DisplayName, &a.Bio, &a.AvatarMediaID, &a.IsAdmin, &a.IsBot, &a.ServerBot, &a.LastSeenAt, &a.CreatedAt, &settings,
			&a.Disabled, &a.DeviceCount, &a.StorageUsed, &a.StorageQuota); err != nil {
			return err
		}
		a.Online = s.hub.UserOnline(a.ID)
		out = append(out, a)
	}
	writeJSON(w, http.StatusOK, out)
	return rows.Err()
}

func (s *Server) adminUpdateUser(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "userID")
	if err != nil {
		return err
	}
	var in struct {
		Disabled     *bool  `json:"disabled"`
		IsAdmin      *bool  `json:"is_admin"`
		StorageQuota *int64 `json:"storage_quota"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	if id == p.UserID && (in.Disabled != nil && *in.Disabled || in.IsAdmin != nil && !*in.IsAdmin) {
		return badRequest("You can't disable or demote yourself.")
	}
	if in.Disabled != nil {
		s.db.Exec(ctx, `UPDATE users SET disabled = $2 WHERE id = $1`, id, *in.Disabled)
		if *in.Disabled {
			s.db.Exec(ctx, `DELETE FROM sessions WHERE user_id = $1`, id)
			s.disconnectUser(ctx, id)
		}
		s.keysChanged(ctx, id)
	}
	if in.IsAdmin != nil {
		s.db.Exec(ctx, `UPDATE users SET is_admin = $2 WHERE id = $1`, id, *in.IsAdmin)
	}
	if in.StorageQuota != nil {
		s.db.Exec(ctx, `UPDATE users SET storage_quota = $2 WHERE id = $1`, id, max(0, *in.StorageQuota))
	}
	s.audit(ctx, p.UserID, "admin.user.update", id.String(), map[string]any{"disabled": in.Disabled, "is_admin": in.IsAdmin, "quota": in.StorageQuota})
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) disconnectUser(ctx context.Context, id uuid.UUID) {
	rows, err := s.db.Query(ctx, `SELECT id FROM devices WHERE user_id = $1`, id)
	if err != nil {
		return
	}
	ids, _ := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	for _, d := range ids {
		s.hub.DisconnectDevice(d)
	}
}

// adminResetPassword sets a random temporary password and signs the user out
// everywhere. Message keys live on devices, so this does not expose content.
func (s *Server) adminResetPassword(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "userID")
	if err != nil {
		return err
	}
	ctx := r.Context()
	temp := strings.ToLower(auth.RandomCode(4))
	hash, err := auth.HashPassword(temp)
	if err != nil {
		return err
	}
	tag, err := s.db.Exec(ctx, `UPDATE users SET password_hash = $2 WHERE id = $1 AND NOT is_bot`, id, hash)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return errNotFound
	}
	// Signing out removes the user's devices; they sign in again with the new password.
	s.disconnectUser(ctx, id)
	s.db.Exec(ctx, `DELETE FROM devices WHERE user_id = $1 AND platform <> 'bot'`, id)
	s.keysChanged(ctx, id)
	s.audit(ctx, me(r).UserID, "admin.user.reset_password", id.String(), nil)
	writeJSON(w, http.StatusOK, map[string]string{"temporary_password": temp})
	return nil
}

func (s *Server) adminDeleteUser(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "userID")
	if err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	if id == p.UserID {
		return badRequest("You can't delete yourself.")
	}
	s.disconnectUser(ctx, id)
	s.keysChanged(ctx, id)
	tag, err := s.db.Exec(ctx, `DELETE FROM users WHERE id = $1`, id)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return errNotFound
	}
	s.audit(ctx, p.UserID, "admin.user.delete", id.String(), nil)
	w.WriteHeader(http.StatusNoContent)
	return nil
}

type Invite struct {
	Code      string     `json:"code"`
	Note      string     `json:"note"`
	MaxUses   int        `json:"max_uses"`
	Uses      int        `json:"uses"`
	MakeAdmin bool       `json:"make_admin"`
	ExpiresAt *time.Time `json:"expires_at"`
	CreatedAt time.Time  `json:"created_at"`
	CreatedBy *uuid.UUID `json:"created_by"`
	URL       string     `json:"url"`
}

func (s *Server) adminListInvites(w http.ResponseWriter, r *http.Request) error {
	rows, err := s.db.Query(r.Context(), `SELECT code, note, max_uses, uses, make_admin, expires_at, created_at, created_by FROM invites ORDER BY created_at DESC`)
	if err != nil {
		return err
	}
	invites, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Invite, error) {
		var i Invite
		err := row.Scan(&i.Code, &i.Note, &i.MaxUses, &i.Uses, &i.MakeAdmin, &i.ExpiresAt, &i.CreatedAt, &i.CreatedBy)
		i.URL = s.inviteURL(i.Code)
		return i, err
	})
	if err != nil {
		return err
	}
	if invites == nil {
		invites = []Invite{}
	}
	writeJSON(w, http.StatusOK, invites)
	return nil
}

func (s *Server) inviteURL(code string) string { return s.cfg.PublicURL + "/invite/" + code }

func (s *Server) adminCreateInvite(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Note         string `json:"note"`
		MaxUses      int    `json:"max_uses"`
		MakeAdmin    bool   `json:"make_admin"`
		ExpiresHours int    `json:"expires_hours"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	inv, err := CreateInvite(r.Context(), s, nullable(me(r).UserID), in.Note, in.MaxUses, in.MakeAdmin, in.ExpiresHours)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, inv)
	return nil
}

// CreateInvite is shared with the CLI.
func CreateInvite(ctx context.Context, s *Server, by *uuid.UUID, note string, maxUses int, admin bool, expiresHours int) (*Invite, error) {
	if maxUses <= 0 {
		maxUses = 1
	}
	inv := &Invite{Code: auth.RandomCode(3), Note: trim(note, 200), MaxUses: maxUses, MakeAdmin: admin, CreatedAt: time.Now(), CreatedBy: by}
	if expiresHours > 0 {
		t := time.Now().Add(time.Duration(expiresHours) * time.Hour)
		inv.ExpiresAt = &t
	}
	if _, err := s.db.Exec(ctx, `INSERT INTO invites(code, created_by, note, max_uses, make_admin, expires_at) VALUES ($1,$2,$3,$4,$5,$6)`,
		inv.Code, by, inv.Note, inv.MaxUses, inv.MakeAdmin, inv.ExpiresAt); err != nil {
		return nil, err
	}
	inv.URL = s.inviteURL(inv.Code)
	actor := uuid.Nil
	if by != nil {
		actor = *by
	}
	s.audit(ctx, actor, "invite.create", inv.Code, map[string]any{"max_uses": maxUses, "admin": admin})
	return inv, nil
}

func (s *Server) adminDeleteInvite(w http.ResponseWriter, r *http.Request) error {
	code := strings.ToUpper(chiParam(r, "code"))
	if _, err := s.db.Exec(r.Context(), `DELETE FROM invites WHERE code = $1`, code); err != nil {
		return err
	}
	s.audit(r.Context(), me(r).UserID, "invite.delete", code, nil)
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) adminAudit(w http.ResponseWriter, r *http.Request) error {
	before := queryInt(r, "before", 1<<62, 0)
	rows, err := s.db.Query(r.Context(), `SELECT a.id, a.actor_id, coalesce(u.username, ''), a.action, a.target, a.details, a.at
		FROM audit_log a LEFT JOIN users u ON u.id = a.actor_id WHERE a.id < $1 ORDER BY a.id DESC LIMIT 100`, before)
	if err != nil {
		return err
	}
	type entry struct {
		ID      int64           `json:"id"`
		ActorID *uuid.UUID      `json:"actor_id"`
		Actor   string          `json:"actor"`
		Action  string          `json:"action"`
		Target  string          `json:"target"`
		Details json.RawMessage `json:"details"`
		At      time.Time       `json:"at"`
	}
	entries, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (entry, error) {
		var e entry
		return e, row.Scan(&e.ID, &e.ActorID, &e.Actor, &e.Action, &e.Target, &e.Details, &e.At)
	})
	if err != nil {
		return err
	}
	if entries == nil {
		entries = []entry{}
	}
	writeJSON(w, http.StatusOK, entries)
	return nil
}

func (s *Server) adminGetSettings(w http.ResponseWriter, r *http.Request) error {
	writeJSON(w, http.StatusOK, s.settings(r.Context()))
	return nil
}

func (s *Server) adminPutSettings(w http.ResponseWriter, r *http.Request) error {
	st := s.settings(r.Context())
	if err := decode(r, &st); err != nil {
		return err
	}
	st.ServerName = trim(st.ServerName, 64)
	if st.StoryTTLHours <= 0 || st.StoryTTLHours > 48 {
		st.StoryTTLHours = 24
	}
	raw, _ := json.Marshal(st)
	if _, err := s.db.Exec(r.Context(), `INSERT INTO server_settings(key, value) VALUES ('server', $1)
		ON CONFLICT (key) DO UPDATE SET value = $1`, raw); err != nil {
		return err
	}
	s.audit(r.Context(), me(r).UserID, "admin.settings", "", map[string]any{"settings": st})
	writeJSON(w, http.StatusOK, st)
	return nil
}
