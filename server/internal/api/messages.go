package api

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/giantmushroom/asgard-chat/server/internal/push"
	"github.com/giantmushroom/asgard-chat/server/internal/realtime"
)

// Envelope is one message as delivered to one device. See docs/PROTOCOL.md.
type Envelope struct {
	ID             uuid.UUID       `json:"id"`
	ConversationID uuid.UUID       `json:"conversation_id"`
	Seq            int64           `json:"seq"`
	ClientID       uuid.UUID       `json:"client_id"`
	Kind           string          `json:"kind"`
	TargetID       *uuid.UUID      `json:"target_id"`
	ThreadRootID   *uuid.UUID      `json:"thread_root_id"`
	SenderUserID   *uuid.UUID      `json:"sender_user_id"`
	SenderDeviceID *uuid.UUID      `json:"sender_device_id"`
	Alg            string          `json:"alg"`
	Ciphertext     []byte          `json:"ciphertext,omitempty"`
	Signature      []byte          `json:"signature,omitempty"`
	System         json.RawMessage `json:"system,omitempty"`
	WrappedKey     []byte          `json:"wrapped_key,omitempty"`
	SentAt         time.Time       `json:"sent_at"`
	ExpiresAt      *time.Time      `json:"expires_at"`
	ViewOnce       bool            `json:"view_once"`
	Deleted        bool            `json:"deleted"`
	Cursor         *int64          `json:"cursor,omitempty"`
}

const envCols = `m.id, m.conversation_id, m.seq, m.client_id, m.kind, m.target_id, m.thread_root_id, m.sender_user_id,
	m.sender_device_id, m.alg, m.ciphertext, m.signature, m.system, d.wrapped_key, m.sent_at, m.expires_at, m.view_once, m.deleted, d.cursor`

// queryEnvelopes runs a message query joined with this device's deliveries.
// where must use $1 for the device id.
func (s *Server) queryEnvelopes(ctx context.Context, device uuid.UUID, where string, args ...any) ([]Envelope, error) {
	rows, err := s.db.Query(ctx, `SELECT `+envCols+` FROM messages m
		LEFT JOIN deliveries d ON d.message_id = m.id AND d.device_id = $1 WHERE `+where, append([]any{device}, args...)...)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(row pgx.CollectableRow) (Envelope, error) {
		var e Envelope
		var system []byte
		err := row.Scan(&e.ID, &e.ConversationID, &e.Seq, &e.ClientID, &e.Kind, &e.TargetID, &e.ThreadRootID, &e.SenderUserID,
			&e.SenderDeviceID, &e.Alg, &e.Ciphertext, &e.Signature, &system, &e.WrappedKey, &e.SentAt, &e.ExpiresAt, &e.ViewOnce, &e.Deleted, &e.Cursor)
		if system != nil {
			e.System = system
		}
		return e, err
	})
}

type sendRequest struct {
	ClientID     uuid.UUID            `json:"client_id"`
	Kind         string               `json:"kind"`
	TargetID     *uuid.UUID           `json:"target_id"`
	ThreadRootID *uuid.UUID           `json:"thread_root_id"`
	Ciphertext   []byte               `json:"ciphertext"`
	Signature    []byte               `json:"signature"`
	Alg          string               `json:"alg"`
	Keys         map[uuid.UUID][]byte `json:"keys"`
	ExpiresIn    int                  `json:"expires_in"`
	SendAt       *time.Time           `json:"send_at"`
	ViewOnce     bool                 `json:"view_once"`
}

// "control" carries encrypted client-to-client signalling (call and voice room
// keys). Any member may send it; it is never pushed and expires after a day.
var sendKinds = map[string]bool{"msg": true, "edit": true, "delete": true, "reaction": true, "vote": true, "rsvp": true, "pin": true, "control": true}

const controlTTL = 24 * time.Hour

func (s *Server) sendMessage(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	var in sendRequest
	if err := decode(r, &in); err != nil {
		return err
	}
	p := me(r)
	env, scheduled, err := s.deliver(r.Context(), p.UserID, p.DeviceID, id, &in)
	if err != nil {
		return err
	}
	if scheduled != uuid.Nil {
		writeJSON(w, http.StatusAccepted, map[string]any{"scheduled_id": scheduled, "send_at": in.SendAt})
		return nil
	}
	writeJSON(w, http.StatusCreated, env)
	return nil
}

// deliver validates and stores a message, then fans it out. It is shared by
// the REST endpoint, the scheduler and server-side bots.
func (s *Server) deliver(ctx context.Context, user, device, conv uuid.UUID, in *sendRequest) (*Envelope, uuid.UUID, error) {
	if !sendKinds[in.Kind] {
		return nil, uuid.Nil, badRequest("Unknown message kind.")
	}
	if in.ClientID == uuid.Nil || len(in.Ciphertext) == 0 || len(in.Signature) != 64 {
		return nil, uuid.Nil, badRequest("client_id, ciphertext and a 64-byte signature are required.")
	}
	if len(in.Ciphertext) > 256<<10 {
		return nil, uuid.Nil, badRequest("Message too large; send big content as an attachment.")
	}
	if in.Kind != "msg" && in.Kind != "control" && in.TargetID == nil {
		return nil, uuid.Nil, badRequest("target_id is required for " + in.Kind)
	}
	if in.Alg == "" {
		in.Alg = "fanout-v1"
	}
	m, err := s.membershipOf(ctx, conv, user)
	if err != nil {
		return nil, uuid.Nil, err
	}

	// Permission checks.
	isComment := in.ThreadRootID != nil && m.Kind == "channel"
	switch in.Kind {
	case "msg", "edit":
		if !m.can(PermSend) && !isComment {
			return nil, uuid.Nil, errf(http.StatusForbidden, "read_only", "Only admins can post here.")
		}
	}
	if in.Kind == "pin" && !m.can(PermPin) {
		return nil, uuid.Nil, errForbidden
	}
	if in.Kind == "edit" || in.Kind == "delete" {
		var author *uuid.UUID
		var kind string
		if err := s.db.QueryRow(ctx, `SELECT sender_user_id, kind FROM messages WHERE id = $1 AND conversation_id = $2`, in.TargetID, conv).Scan(&author, &kind); err != nil {
			return nil, uuid.Nil, errNotFound
		}
		own := author != nil && *author == user
		if in.Kind == "edit" && (!own || kind != "msg") {
			return nil, uuid.Nil, errForbidden
		}
		if in.Kind == "delete" && !own && !m.can(PermDeleteOthers) {
			return nil, uuid.Nil, errForbidden
		}
	}
	if m.Kind == "dm" {
		for _, other := range s.memberIDs(ctx, conv) {
			if other != user && s.blocked(ctx, other, user) {
				return nil, uuid.Nil, errf(http.StatusForbidden, "blocked", "You can't message this person.")
			}
		}
	}
	if in.Kind == "msg" && m.SlowMode > 0 && !m.can(PermBypassSlowMode) {
		var last *time.Time
		s.db.QueryRow(ctx, `SELECT last_post_at FROM members WHERE conversation_id = $1 AND user_id = $2`, conv, user).Scan(&last)
		if last != nil && time.Since(*last) < time.Duration(m.SlowMode)*time.Second {
			wait := time.Duration(m.SlowMode)*time.Second - time.Since(*last)
			return nil, uuid.Nil, &apiError{Status: http.StatusTooManyRequests, Code: "slow_mode",
				Message: "Slow mode is on.", Extra: map[string]any{"retry_after_seconds": int(wait.Seconds()) + 1}}
		}
	}

	// Scheduled send: hold the request until it is due.
	if in.SendAt != nil && in.SendAt.After(time.Now().Add(5*time.Second)) {
		if in.Kind != "msg" {
			return nil, uuid.Nil, badRequest("Only messages can be scheduled.")
		}
		sid := uuid.New()
		payload, _ := json.Marshal(in)
		_, err := s.db.Exec(ctx, `INSERT INTO scheduled_messages(id, conversation_id, sender_user_id, sender_device_id, payload, send_at) VALUES ($1,$2,$3,$4,$5,$6)`,
			sid, conv, user, device, payload, *in.SendAt)
		return nil, sid, err
	}

	// Every member device must get a key, and only member devices.
	devices, err := s.devicesOf(ctx, s.memberIDs(ctx, conv))
	if err != nil {
		return nil, uuid.Nil, err
	}
	var missing, extra []uuid.UUID
	want := map[uuid.UUID]Device{}
	for _, d := range devices {
		want[d.ID] = d
		if d.ID == device {
			continue // the sender already has the plaintext
		}
		if k, ok := in.Keys[d.ID]; !ok || len(k) == 0 {
			missing = append(missing, d.ID)
		}
	}
	for d := range in.Keys {
		if _, ok := want[d]; !ok {
			extra = append(extra, d)
		}
	}
	if len(missing) > 0 || len(extra) > 0 {
		return nil, uuid.Nil, &apiError{Status: http.StatusConflict, Code: "device_mismatch",
			Message: "The conversation's devices changed. Refresh keys and retry.",
			Extra:   map[string]any{"missing": orEmpty(missing), "extra": orEmpty(extra)}}
	}

	tx, err := s.db.Begin(ctx)
	if err != nil {
		return nil, uuid.Nil, err
	}
	defer tx.Rollback(ctx)

	// Idempotency: a retried send returns the original message.
	var existing uuid.UUID
	if err := tx.QueryRow(ctx, `SELECT id FROM messages WHERE sender_device_id = $1 AND client_id = $2`, device, in.ClientID).Scan(&existing); err == nil {
		tx.Rollback(ctx)
		envs, err := s.queryEnvelopes(ctx, device, `m.id = $2`, existing)
		if err != nil || len(envs) == 0 {
			return nil, uuid.Nil, err
		}
		return &envs[0], uuid.Nil, nil
	}

	var seq int64
	var disappear int
	if err := tx.QueryRow(ctx, `UPDATE conversations SET last_seq = last_seq + 1,
		last_message_at = CASE WHEN $2 = 'msg' THEN now() ELSE last_message_at END
		WHERE id = $1 RETURNING last_seq, disappearing_seconds`, conv, in.Kind).Scan(&seq, &disappear); err != nil {
		return nil, uuid.Nil, err
	}
	var expires *time.Time
	ttl := disappear
	if in.ExpiresIn > 0 {
		ttl = in.ExpiresIn
	}
	if ttl > 0 && in.Kind == "msg" {
		t := time.Now().Add(time.Duration(ttl) * time.Second)
		expires = &t
	}
	if in.Kind == "control" {
		t := time.Now().Add(controlTTL)
		expires = &t
	}
	msgID := uuid.New()
	if _, err := tx.Exec(ctx, `INSERT INTO messages(id, conversation_id, seq, client_id, kind, target_id, thread_root_id, sender_user_id, sender_device_id, alg, ciphertext, signature, view_once, expires_at)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,
		msgID, conv, seq, in.ClientID, in.Kind, in.TargetID, in.ThreadRootID, user, device, in.Alg, in.Ciphertext, in.Signature, in.ViewOnce, expires); err != nil {
		return nil, uuid.Nil, err
	}
	if in.Kind == "delete" {
		// Erase the target's content; the delete event itself carries no secrets.
		tx.Exec(ctx, `UPDATE messages SET ciphertext = NULL, signature = NULL, deleted = true WHERE id = $1`, in.TargetID)
		tx.Exec(ctx, `UPDATE messages SET ciphertext = NULL, signature = NULL, deleted = true WHERE target_id = $1 AND kind = 'edit'`, in.TargetID)
	}
	if in.Kind == "msg" {
		tx.Exec(ctx, `UPDATE members SET last_post_at = now() WHERE conversation_id = $1 AND user_id = $2`, conv, user)
	}
	cursors := map[uuid.UUID]int64{}
	for d := range want {
		var c int64
		if err := tx.QueryRow(ctx, `INSERT INTO deliveries(device_id, message_id, wrapped_key) VALUES ($1,$2,$3) RETURNING cursor`,
			d, msgID, nilIfEmpty(in.Keys[d])).Scan(&c); err != nil {
			return nil, uuid.Nil, err
		}
		cursors[d] = c
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, uuid.Nil, err
	}

	base := Envelope{ID: msgID, ConversationID: conv, Seq: seq, ClientID: in.ClientID, Kind: in.Kind, TargetID: in.TargetID,
		ThreadRootID: in.ThreadRootID, SenderUserID: &user, SenderDeviceID: &device, Alg: in.Alg, Ciphertext: in.Ciphertext,
		Signature: in.Signature, SentAt: time.Now().UTC(), ExpiresAt: expires, ViewOnce: in.ViewOnce}
	go s.fanOut(base, want, in.Keys, cursors, device)

	self := base
	c := cursors[device]
	self.Cursor = &c
	return &self, uuid.Nil, nil
}

// fanOut sends the envelope over WebSockets and pushes to offline devices.
func (s *Server) fanOut(base Envelope, devices map[uuid.UUID]Device, keys map[uuid.UUID][]byte, cursors map[uuid.UUID]int64, sender uuid.UUID) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	muted := map[uuid.UUID]bool{}
	rows, err := s.db.Query(ctx, `SELECT user_id FROM members WHERE conversation_id = $1 AND muted_until > now()`, base.ConversationID)
	if err == nil {
		ids, _ := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
		for _, id := range ids {
			muted[id] = true
		}
	}
	for id, d := range devices {
		if id == sender {
			continue
		}
		env := base
		env.WrappedKey = keys[id]
		c := cursors[id]
		env.Cursor = &c
		if s.hub.ToDevice(id, realtime.Event{Type: "message", Data: env}) {
			continue
		}
		if base.Kind == "control" {
			continue
		}
		kind := push.Alert
		if base.Kind != "msg" || muted[d.UserID] || d.UserID == *base.SenderUserID {
			kind = push.Background
		}
		s.pushEnvelope(ctx, id, &env, kind)
	}
}

func (s *Server) pushEnvelope(ctx context.Context, device uuid.UUID, env *Envelope, kind push.Kind) {
	if !s.push.Any() {
		return
	}
	var provider, token, buildEnv string
	if err := s.db.QueryRow(ctx, `SELECT push_kind, push_token, push_env FROM devices WHERE id = $1`, device).Scan(&provider, &token, &buildEnv); err != nil || token == "" {
		return
	}
	data := map[string]any{"c": env.ConversationID.String(), "m": env.ID.String()}
	if b, _ := json.Marshal(env); len(b) < 3500 {
		data["e"] = env
	}
	err := s.push.Send(ctx, provider, token, buildEnv, push.Notification{Kind: kind, ThreadID: env.ConversationID.String(), Data: data})
	if errors.Is(err, push.ErrUnregistered) {
		s.db.Exec(ctx, `UPDATE devices SET push_token = '' WHERE id = $1`, device)
	} else if err != nil {
		slog.Warn("push failed", "device", device, "err", err)
	}
}

// postSystem records a plaintext membership/settings event for all members.
func (s *Server) postSystem(ctx context.Context, conv, actor uuid.UUID, event map[string]any) {
	event["actor_id"] = actor
	payload, _ := json.Marshal(event)
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return
	}
	defer tx.Rollback(ctx)
	var seq int64
	if err := tx.QueryRow(ctx, `UPDATE conversations SET last_seq = last_seq + 1 WHERE id = $1 RETURNING last_seq`, conv).Scan(&seq); err != nil {
		return
	}
	id := uuid.New()
	if _, err := tx.Exec(ctx, `INSERT INTO messages(id, conversation_id, seq, client_id, kind, sender_user_id, alg, system) VALUES ($1,$2,$3,$4,'system',$5,'none',$6)`,
		id, conv, seq, uuid.New(), nullable(actor), payload); err != nil {
		slog.Error("system message", "err", err)
		return
	}
	rows, err := tx.Query(ctx, `INSERT INTO deliveries(device_id, message_id)
		SELECT d.id, $2 FROM devices d JOIN members mb ON mb.user_id = d.user_id WHERE mb.conversation_id = $1 AND d.platform <> 'admin'
		RETURNING device_id, cursor`, conv, id)
	if err != nil {
		return
	}
	cursors := map[uuid.UUID]int64{}
	for rows.Next() {
		var d uuid.UUID
		var c int64
		rows.Scan(&d, &c)
		cursors[d] = c
	}
	rows.Close()
	if tx.Commit(ctx) != nil {
		return
	}
	for d, c := range cursors {
		c := c
		s.hub.ToDevice(d, realtime.Event{Type: "message", Data: Envelope{ID: id, ConversationID: conv, Seq: seq, Kind: "system",
			SenderUserID: nullable(actor), Alg: "none", System: payload, SentAt: time.Now().UTC(), Cursor: &c}})
	}
}

func (s *Server) sync(w http.ResponseWriter, r *http.Request) error {
	p := me(r)
	after := queryInt(r, "after", 0, 0)
	limit := queryInt(r, "limit", 500, 1000)
	envs, err := s.queryEnvelopes(r.Context(), p.DeviceID, `d.cursor > $2 ORDER BY d.cursor LIMIT $3`, after, limit)
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

func (s *Server) history(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	if _, err := s.membershipOf(ctx, id, p.UserID); err != nil {
		return err
	}
	before := queryInt(r, "before_seq", 1<<62, 0)
	limit := queryInt(r, "limit", 50, 200)
	envs, err := s.queryEnvelopes(ctx, p.DeviceID, `m.conversation_id = $2 AND m.seq < $3 AND m.thread_root_id IS NULL ORDER BY m.seq DESC LIMIT $4`, id, before, limit)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, orEmptyEnv(envs))
	return nil
}

func (s *Server) thread(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	root, err := pathUUID(r, "msgID")
	if err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	if _, err := s.membershipOf(ctx, id, p.UserID); err != nil {
		return err
	}
	envs, err := s.queryEnvelopes(ctx, p.DeviceID, `m.conversation_id = $2 AND (m.thread_root_id = $3 OR m.id = $3) ORDER BY m.seq`, id, root)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, orEmptyEnv(envs))
	return nil
}

func (s *Server) markRead(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	var in struct {
		Seq int64 `json:"seq"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	if err := s.applyRead(r.Context(), me(r), id, in.Seq); err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) applyRead(ctx context.Context, p *principal, conv uuid.UUID, seq int64) error {
	tag, err := s.db.Exec(ctx, `UPDATE members SET read_seq = GREATEST(read_seq, $3), delivered_seq = GREATEST(delivered_seq, $3)
		WHERE conversation_id = $1 AND user_id = $2`, conv, p.UserID, seq)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return errNotFound
	}
	// The user's own devices always sync read state; others only if receipts are on.
	s.hub.ToUsers([]uuid.UUID{p.UserID}, realtime.Event{Type: "receipt", Data: map[string]any{
		"conversation_id": conv, "user_id": p.UserID, "read_seq": seq}}, p.DeviceID)
	var share bool
	s.db.QueryRow(ctx, `SELECT coalesce((settings->>'read_receipts')::boolean, true) FROM users WHERE id = $1`, p.UserID).Scan(&share)
	if share {
		others := []uuid.UUID{}
		for _, u := range s.memberIDs(ctx, conv) {
			if u != p.UserID {
				others = append(others, u)
			}
		}
		s.hub.ToUsers(others, realtime.Event{Type: "receipt", Data: map[string]any{
			"conversation_id": conv, "user_id": p.UserID, "read_seq": seq}}, uuid.Nil)
	}
	return nil
}

func (s *Server) listScheduled(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	p := me(r)
	rows, err := s.db.Query(r.Context(), `SELECT id, send_at, payload FROM scheduled_messages WHERE conversation_id = $1 AND sender_user_id = $2 ORDER BY send_at`, id, p.UserID)
	if err != nil {
		return err
	}
	type item struct {
		ID      uuid.UUID       `json:"id"`
		SendAt  time.Time       `json:"send_at"`
		Payload json.RawMessage `json:"payload"`
	}
	items, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (item, error) {
		var it item
		return it, row.Scan(&it.ID, &it.SendAt, &it.Payload)
	})
	if err != nil {
		return err
	}
	if items == nil {
		items = []item{}
	}
	writeJSON(w, http.StatusOK, items)
	return nil
}

func (s *Server) cancelScheduled(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "schedID")
	if err != nil {
		return err
	}
	tag, err := s.db.Exec(r.Context(), `DELETE FROM scheduled_messages WHERE id = $1 AND sender_user_id = $2`, id, me(r).UserID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return errNotFound
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// RunScheduled delivers due scheduled messages. Called by the job loop.
func (s *Server) RunScheduled(ctx context.Context) {
	rows, err := s.db.Query(ctx, `DELETE FROM scheduled_messages WHERE id IN (
		SELECT id FROM scheduled_messages WHERE send_at <= now() ORDER BY send_at LIMIT 100 FOR UPDATE SKIP LOCKED)
		RETURNING conversation_id, sender_user_id, sender_device_id, payload`)
	if err != nil {
		slog.Error("scheduled query", "err", err)
		return
	}
	type due struct {
		conv, user, device uuid.UUID
		payload            []byte
	}
	var items []due
	for rows.Next() {
		var d due
		if rows.Scan(&d.conv, &d.user, &d.device, &d.payload) == nil {
			items = append(items, d)
		}
	}
	rows.Close()
	for _, d := range items {
		var in sendRequest
		if json.Unmarshal(d.payload, &in) != nil {
			continue
		}
		in.SendAt = nil
		if _, _, err := s.deliver(ctx, d.user, d.device, d.conv, &in); err != nil {
			// Device set changed since scheduling: the sender's device must re-wrap.
			slog.Warn("scheduled delivery failed", "conversation", d.conv, "err", err)
			s.hub.ToDevice(d.device, realtime.Event{Type: "scheduled.failed", Data: map[string]any{"conversation_id": d.conv, "client_id": in.ClientID, "error": err.Error()}})
		}
	}
}

func orEmpty(ids []uuid.UUID) []uuid.UUID {
	if ids == nil {
		return []uuid.UUID{}
	}
	return ids
}

func orEmptyEnv(e []Envelope) []Envelope {
	if e == nil {
		return []Envelope{}
	}
	return e
}

func nilIfEmpty(b []byte) []byte {
	if len(b) == 0 {
		return nil
	}
	return b
}
