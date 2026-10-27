package api

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/giantmushroom/asgard-chat/server/internal/realtime"
)

func (s *Server) searchUsers(w http.ResponseWriter, r *http.Request) error {
	q := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("q")))
	var rows pgx.Rows
	var err error
	if q == "" {
		// Directory of everyone on this server (it is private and small).
		rows, err = s.db.Query(r.Context(), `SELECT `+userCols+` FROM users u WHERE NOT u.disabled AND NOT u.is_bot ORDER BY u.display_name LIMIT 200`)
	} else {
		rows, err = s.db.Query(r.Context(), `SELECT `+userCols+` FROM users u
			WHERE NOT u.disabled AND (u.username LIKE $1 || '%' OR lower(u.display_name) LIKE '%' || $1 || '%')
			ORDER BY (u.username = $1) DESC, u.username LIMIT 50`, q)
	}
	if err != nil {
		return err
	}
	users, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (*User, error) { return scanUser(row) })
	if err != nil {
		return err
	}
	for _, u := range users {
		s.publicView(u)
	}
	writeJSON(w, http.StatusOK, users)
	return nil
}

func (s *Server) getUser(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "userID")
	if err != nil {
		return err
	}
	u, err := s.loadUser(r.Context(), id)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, s.publicView(u))
	return nil
}

func (s *Server) devicesOf(ctx context.Context, users []uuid.UUID) ([]Device, error) {
	rows, err := s.db.Query(ctx, `SELECT d.id, d.user_id, d.identity_key, d.signing_key, d.created_at
		FROM devices d JOIN users u ON u.id = d.user_id
		WHERE d.user_id = ANY($1) AND NOT u.disabled AND d.platform <> 'admin' ORDER BY d.user_id, d.created_at`, users)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (Device, error) {
		var d Device
		return d, row.Scan(&d.ID, &d.UserID, &d.IdentityKey, &d.SigningKey, &d.CreatedAt)
	})
}

func (s *Server) userDevices(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "userID")
	if err != nil {
		return err
	}
	devices, err := s.devicesOf(r.Context(), []uuid.UUID{id})
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, devices)
	return nil
}

type Contact struct {
	User     *User  `json:"user"`
	Nickname string `json:"nickname"`
	Blocked  bool   `json:"blocked"`
}

func (s *Server) listContacts(w http.ResponseWriter, r *http.Request) error {
	rows, err := s.db.Query(r.Context(), `SELECT `+userCols+`, c.nickname, c.blocked
		FROM contacts c JOIN users u ON u.id = c.contact_id WHERE c.user_id = $1 ORDER BY u.display_name`, me(r).UserID)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := []Contact{}
	for rows.Next() {
		u := &User{}
		var settings []byte
		var c Contact
		if err := rows.Scan(&u.ID, &u.Username, &u.DisplayName, &u.Bio, &u.AvatarMediaID, &u.IsAdmin, &u.IsBot, &u.ServerBot, &u.LastSeenAt, &u.CreatedAt, &settings, &c.Nickname, &c.Blocked); err != nil {
			return err
		}
		c.User = s.publicView(u)
		out = append(out, c)
	}
	writeJSON(w, http.StatusOK, out)
	return rows.Err()
}

func (s *Server) putContact(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "userID")
	if err != nil {
		return err
	}
	var in struct {
		Nickname string `json:"nickname"`
		Blocked  bool   `json:"blocked"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	if id == me(r).UserID {
		return badRequest("You cannot add yourself.")
	}
	_, err = s.db.Exec(r.Context(), `INSERT INTO contacts(user_id, contact_id, nickname, blocked) VALUES ($1,$2,$3,$4)
		ON CONFLICT (user_id, contact_id) DO UPDATE SET nickname = $3, blocked = $4`, me(r).UserID, id, trim(in.Nickname, 64), in.Blocked)
	if err != nil {
		return errNotFound
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) deleteContact(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "userID")
	if err != nil {
		return err
	}
	_, err = s.db.Exec(r.Context(), `DELETE FROM contacts WHERE user_id = $1 AND contact_id = $2`, me(r).UserID, id)
	if err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// blocked reports whether recipient has blocked sender.
func (s *Server) blocked(ctx context.Context, recipient, sender uuid.UUID) bool {
	var b bool
	s.db.QueryRow(ctx, `SELECT blocked FROM contacts WHERE user_id = $1 AND contact_id = $2`, recipient, sender).Scan(&b)
	return b
}

func (s *Server) broadcastPresence(user uuid.UUID, online bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	var hide bool
	s.db.QueryRow(ctx, `SELECT coalesce((settings->>'hide_last_seen')::boolean, false) FROM users WHERE id = $1`, user).Scan(&hide)
	if hide {
		return
	}
	if !online {
		s.db.Exec(ctx, `UPDATE users SET last_seen_at = now() WHERE id = $1`, user)
	}
	s.hub.ToUsers(s.peersOf(ctx, user), realtime.Event{Type: "presence", Data: map[string]any{
		"user_id": user, "online": online, "last_seen_at": time.Now().UTC(),
	}}, uuid.Nil)
}
