package api

import (
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"
)

// uploadMedia stores an already-encrypted blob. The body is the raw bytes.
// Avatars are uploaded unencrypted with ?purpose=avatar (they are public on
// this server by design).
func (s *Server) uploadMedia(w http.ResponseWriter, r *http.Request) error {
	if s.store == nil {
		return errf(http.StatusServiceUnavailable, "storage_disabled", "Media storage is not configured on this server.")
	}
	ctx, p := r.Context(), me(r)
	if r.ContentLength <= 0 {
		return errf(http.StatusLengthRequired, "length_required", "Content-Length is required.")
	}
	if r.ContentLength > s.cfg.MaxUploadBytes {
		return errf(http.StatusRequestEntityTooLarge, "too_large", "File is larger than this server allows.")
	}
	var used, quota int64
	s.db.QueryRow(ctx, `SELECT coalesce((SELECT sum(size) FROM media WHERE owner_id = $1), 0), storage_quota FROM users WHERE id = $1`, p.UserID).Scan(&used, &quota)
	if quota > 0 && used+r.ContentLength > quota {
		return errf(http.StatusInsufficientStorage, "quota_exceeded", "You have used all of your storage. Delete some media or ask the admin for more space.")
	}
	contentType := "application/octet-stream"
	if r.URL.Query().Get("purpose") == "avatar" {
		if ct := r.Header.Get("Content-Type"); ct == "image/jpeg" || ct == "image/png" || ct == "image/heic" || ct == "image/webp" {
			contentType = ct
		}
	}
	id := uuid.New()
	key := "media/" + id.String()[:2] + "/" + id.String()
	body := http.MaxBytesReader(w, r.Body, s.cfg.MaxUploadBytes)
	if err := s.store.Put(ctx, key, body, r.ContentLength); err != nil {
		return err
	}
	var expires *time.Time
	if ttl, _ := strconv.Atoi(r.URL.Query().Get("ttl")); ttl > 0 {
		t := time.Now().Add(time.Duration(ttl) * time.Second)
		expires = &t
	}
	if _, err := s.db.Exec(ctx, `INSERT INTO media(id, owner_id, object_key, size, content_type, expires_at) VALUES ($1,$2,$3,$4,$5,$6)`,
		id, p.UserID, key, r.ContentLength, contentType, expires); err != nil {
		s.store.Delete(ctx, key)
		return err
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": id, "size": r.ContentLength})
	return nil
}

// downloadMedia streams a blob. Media ids are unguessable capabilities and
// the bytes are ciphertext, so any signed-in user holding the id may fetch it.
// Range requests are supported for video scrubbing.
func (s *Server) downloadMedia(w http.ResponseWriter, r *http.Request) error {
	if s.store == nil {
		return errNotFound
	}
	id, err := pathUUID(r, "mediaID")
	if err != nil {
		return err
	}
	var key, ct string
	var created time.Time
	if err := s.db.QueryRow(r.Context(), `SELECT object_key, content_type, created_at FROM media WHERE id = $1 AND (expires_at IS NULL OR expires_at > now())`, id).Scan(&key, &ct, &created); err != nil {
		return errNotFound
	}
	obj, _, err := s.store.Get(r.Context(), key)
	if err != nil {
		return errNotFound
	}
	defer obj.Close()
	w.Header().Set("Content-Type", ct)
	w.Header().Set("Cache-Control", "private, max-age=31536000, immutable")
	http.ServeContent(w, r, "", created, obj)
	return nil
}

func (s *Server) deleteMedia(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "mediaID")
	if err != nil {
		return err
	}
	var key string
	if err := s.db.QueryRow(r.Context(), `DELETE FROM media WHERE id = $1 AND owner_id = $2 RETURNING object_key`, id, me(r).UserID).Scan(&key); err != nil {
		return errNotFound
	}
	if s.store != nil {
		s.store.Delete(r.Context(), key)
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}
