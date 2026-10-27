package api

import (
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/giantmushroom/asgard-chat/server/internal/realtime"
)

type Story struct {
	ID             uuid.UUID `json:"id"`
	UserID         uuid.UUID `json:"user_id"`
	SenderDeviceID uuid.UUID `json:"sender_device_id"`
	Ciphertext     []byte    `json:"ciphertext"`
	Signature      []byte    `json:"signature"`
	WrappedKey     []byte    `json:"wrapped_key,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
	ExpiresAt      time.Time `json:"expires_at"`
	Viewed         bool      `json:"viewed"`
	ViewCount      int       `json:"view_count"`
}

// postStory: the client picks the audience (contacts, close friends, custom)
// by choosing which devices receive a wrapped key.
func (s *Server) postStory(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Ciphertext []byte               `json:"ciphertext"`
		Signature  []byte               `json:"signature"`
		Keys       map[uuid.UUID][]byte `json:"keys"`
		TTLHours   int                  `json:"ttl_hours"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	if len(in.Ciphertext) == 0 || len(in.Signature) != 64 || len(in.Keys) == 0 {
		return badRequest("ciphertext, signature and keys are required.")
	}
	ctx, p := r.Context(), me(r)
	ttl := s.settings(ctx).StoryTTLHours
	if in.TTLHours > 0 && in.TTLHours <= 48 {
		ttl = in.TTLHours
	}
	id := uuid.New()
	exp := time.Now().Add(time.Duration(ttl) * time.Hour)
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `INSERT INTO stories(id, user_id, sender_device_id, ciphertext, signature, expires_at) VALUES ($1,$2,$3,$4,$5,$6)`,
		id, p.UserID, p.DeviceID, in.Ciphertext, in.Signature, exp); err != nil {
		return err
	}
	for d, k := range in.Keys {
		if _, err := tx.Exec(ctx, `INSERT INTO story_keys(story_id, device_id, wrapped_key) VALUES ($1,$2,$3)`, id, d, k); err != nil {
			return badRequest("Unknown device " + d.String())
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	for d := range in.Keys {
		s.hub.ToDevice(d, realtime.Event{Type: "story", Data: map[string]any{"id": id, "user_id": p.UserID}})
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": id, "expires_at": exp})
	return nil
}

func (s *Server) listStories(w http.ResponseWriter, r *http.Request) error {
	p := me(r)
	rows, err := s.db.Query(r.Context(), `
		SELECT st.id, st.user_id, st.sender_device_id, st.ciphertext, st.signature, k.wrapped_key, st.created_at, st.expires_at,
			EXISTS(SELECT 1 FROM story_views v WHERE v.story_id = st.id AND v.viewer_id = $2),
			CASE WHEN st.user_id = $2 THEN (SELECT count(*) FROM story_views v WHERE v.story_id = st.id) ELSE 0 END
		FROM stories st
		LEFT JOIN story_keys k ON k.story_id = st.id AND k.device_id = $1
		WHERE st.expires_at > now() AND (k.device_id IS NOT NULL OR st.user_id = $2)
		  AND NOT EXISTS (SELECT 1 FROM contacts c WHERE c.user_id = $2 AND c.contact_id = st.user_id AND c.blocked)
		ORDER BY st.user_id, st.created_at`, p.DeviceID, p.UserID)
	if err != nil {
		return err
	}
	stories, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (Story, error) {
		var st Story
		return st, row.Scan(&st.ID, &st.UserID, &st.SenderDeviceID, &st.Ciphertext, &st.Signature, &st.WrappedKey, &st.CreatedAt, &st.ExpiresAt, &st.Viewed, &st.ViewCount)
	})
	if err != nil {
		return err
	}
	if stories == nil {
		stories = []Story{}
	}
	writeJSON(w, http.StatusOK, stories)
	return nil
}

func (s *Server) deleteStory(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "storyID")
	if err != nil {
		return err
	}
	tag, err := s.db.Exec(r.Context(), `DELETE FROM stories WHERE id = $1 AND user_id = $2`, id, me(r).UserID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return errNotFound
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) viewStory(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "storyID")
	if err != nil {
		return err
	}
	var in struct {
		Reaction string `json:"reaction"`
	}
	decode(r, &in)
	ctx, p := r.Context(), me(r)
	var owner uuid.UUID
	if err := s.db.QueryRow(ctx, `SELECT st.user_id FROM stories st JOIN story_keys k ON k.story_id = st.id AND k.device_id = $2 WHERE st.id = $1`, id, p.DeviceID).Scan(&owner); err != nil {
		return errNotFound
	}
	if _, err := s.db.Exec(ctx, `INSERT INTO story_views(story_id, viewer_id, reaction) VALUES ($1,$2,$3)
		ON CONFLICT (story_id, viewer_id) DO UPDATE SET reaction = CASE WHEN $3 = '' THEN story_views.reaction ELSE $3 END`,
		id, p.UserID, trim(in.Reaction, 16)); err != nil {
		return err
	}
	s.hub.ToUsers([]uuid.UUID{owner}, realtime.Event{Type: "story.viewed", Data: map[string]any{"story_id": id, "viewer_id": p.UserID, "reaction": in.Reaction}}, uuid.Nil)
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) storyViews(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "storyID")
	if err != nil {
		return err
	}
	rows, err := s.db.Query(r.Context(), `SELECT v.viewer_id, v.viewed_at, v.reaction FROM story_views v JOIN stories st ON st.id = v.story_id
		WHERE v.story_id = $1 AND st.user_id = $2 ORDER BY v.viewed_at DESC`, id, me(r).UserID)
	if err != nil {
		return err
	}
	type view struct {
		ViewerID uuid.UUID `json:"viewer_id"`
		ViewedAt time.Time `json:"viewed_at"`
		Reaction string    `json:"reaction"`
	}
	views, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (view, error) {
		var v view
		return v, row.Scan(&v.ViewerID, &v.ViewedAt, &v.Reaction)
	})
	if err != nil {
		return err
	}
	if views == nil {
		views = []view{}
	}
	writeJSON(w, http.StatusOK, views)
	return nil
}
