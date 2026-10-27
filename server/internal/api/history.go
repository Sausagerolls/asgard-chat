package api

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// Message history sync.
//
// A user's devices share a recovery key the server never sees. From it they
// derive a "history device" key pair whose public half is registered here as
// an extra device (platform "history"). Senders already wrap every message
// key for every device of every member, so they wrap it for the history
// device too. A newly linked device, or a user restoring with the recovery
// key after losing every device, reads those envelopes through
// /me/history/messages and decrypts them locally.
//
// The history device never has a session, push token or WebSocket.

const historyPlatform = "history"

func (s *Server) historyDevice(ctx context.Context, user uuid.UUID) (*Device, error) {
	var d Device
	err := s.db.QueryRow(ctx, `SELECT id, user_id, identity_key, signing_key, created_at FROM devices WHERE user_id = $1 AND platform = $2`,
		user, historyPlatform).Scan(&d.ID, &d.UserID, &d.IdentityKey, &d.SigningKey, &d.CreatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return &d, err
}

// GET /me/history: whether history sync is on, and the public key that a
// typed-in recovery key must match.
func (s *Server) historyStatus(w http.ResponseWriter, r *http.Request) error {
	d, err := s.historyDevice(r.Context(), me(r).UserID)
	if err != nil {
		return err
	}
	if d == nil {
		writeJSON(w, http.StatusOK, map[string]any{"enabled": false})
		return nil
	}
	var count int64
	s.db.QueryRow(r.Context(), `SELECT count(*) FROM deliveries WHERE device_id = $1`, d.ID).Scan(&count)
	writeJSON(w, http.StatusOK, map[string]any{"enabled": true, "device_id": d.ID, "identity_key": d.IdentityKey,
		"signing_key": d.SigningKey, "created_at": d.CreatedAt, "messages": count})
	return nil
}

// PUT /me/history registers (or replaces) the history device's public keys.
// Replacing it means a new recovery key: history wrapped for the old one is dropped.
func (s *Server) setHistoryKey(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		IdentityKey []byte `json:"identity_key"`
		SigningKey  []byte `json:"signing_key"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	if len(in.IdentityKey) != 32 || len(in.SigningKey) != 32 {
		return badRequest("identity_key and signing_key must be 32 bytes")
	}
	ctx, p := r.Context(), me(r)
	existing, err := s.historyDevice(ctx, p.UserID)
	if err != nil {
		return err
	}
	if existing != nil && string(existing.IdentityKey) == string(in.IdentityKey) {
		return s.historyStatus(w, r)
	}
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if existing != nil {
		if _, err := tx.Exec(ctx, `DELETE FROM devices WHERE id = $1`, existing.ID); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, `INSERT INTO devices(id, user_id, name, platform, identity_key, signing_key) VALUES ($1,$2,'Message history',$3,$4,$5)`,
		uuid.New(), p.UserID, historyPlatform, in.IdentityKey, in.SigningKey); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	s.keysChanged(ctx, p.UserID)
	s.audit(ctx, p.UserID, "history.key.set", "", map[string]any{"replaced": existing != nil})
	return s.historyStatus(w, r)
}

// DELETE /me/history turns history sync off and deletes every wrapped key.
func (s *Server) deleteHistoryKey(w http.ResponseWriter, r *http.Request) error {
	ctx, p := r.Context(), me(r)
	if _, err := s.db.Exec(ctx, `DELETE FROM devices WHERE user_id = $1 AND platform = $2`, p.UserID, historyPlatform); err != nil {
		return err
	}
	s.keysChanged(ctx, p.UserID)
	s.audit(ctx, p.UserID, "history.key.delete", "", nil)
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// GET /me/history/messages?after=<cursor> pages through every envelope
// wrapped for the history device, oldest first, like /sync.
func (s *Server) historyMessages(w http.ResponseWriter, r *http.Request) error {
	ctx, p := r.Context(), me(r)
	d, err := s.historyDevice(ctx, p.UserID)
	if err != nil {
		return err
	}
	if d == nil {
		return errf(http.StatusNotFound, "history_off", "Message history sync isn't turned on.")
	}
	after := queryInt(r, "after", 0, 0)
	limit := queryInt(r, "limit", 500, 1000)
	envs, err := s.queryEnvelopes(ctx, d.ID, `d.cursor > $2 ORDER BY d.cursor LIMIT $3`, after, limit)
	if err != nil {
		return err
	}
	next := after
	if len(envs) > 0 {
		next = *envs[len(envs)-1].Cursor
	}
	writeJSON(w, http.StatusOK, map[string]any{"envelopes": orEmptyEnv(envs), "next_cursor": next, "more": int64(len(envs)) == limit})
	return nil
}

// POST /me/history/backfill adds history-device wrapped keys for messages sent
// before history sync was turned on. Devices re-wrap keys they can already
// unwrap; only messages in conversations the user belongs to are accepted.
func (s *Server) historyBackfill(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Items []struct {
			MessageID  uuid.UUID `json:"message_id"`
			WrappedKey []byte    `json:"wrapped_key"`
		} `json:"items"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	if len(in.Items) > 500 {
		return badRequest("at most 500 items per request")
	}
	ctx, p := r.Context(), me(r)
	d, err := s.historyDevice(ctx, p.UserID)
	if err != nil {
		return err
	}
	if d == nil {
		return errf(http.StatusNotFound, "history_off", "Message history sync isn't turned on.")
	}
	added := 0
	for _, it := range in.Items {
		if len(it.WrappedKey) != 92 {
			continue
		}
		tag, err := s.db.Exec(ctx, `INSERT INTO deliveries(device_id, message_id, wrapped_key)
			SELECT $1, m.id, $3 FROM messages m JOIN members mb ON mb.conversation_id = m.conversation_id AND mb.user_id = $4
			WHERE m.id = $2 AND NOT m.deleted
			ON CONFLICT DO NOTHING`, d.ID, it.MessageID, it.WrappedKey, p.UserID)
		if err != nil {
			return err
		}
		added += int(tag.RowsAffected())
	}
	writeJSON(w, http.StatusOK, map[string]any{"added": added, "at": time.Now()})
	return nil
}
