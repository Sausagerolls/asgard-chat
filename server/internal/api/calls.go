package api

import (
	"context"
	"net/http"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/giantmushroom/asgard-chat/server/internal/push"
	"github.com/giantmushroom/asgard-chat/server/internal/realtime"
)

type activeCall struct {
	Room      string    `json:"room"`
	StartedBy uuid.UUID `json:"started_by"`
	StartedAt time.Time `json:"started_at"`
	Video     bool      `json:"video"`
}

// startCall returns a LiveKit join token. The first caller rings everyone else.
func (s *Server) startCall(w http.ResponseWriter, r *http.Request) error {
	if !s.cfg.CallsEnabled() {
		return errf(http.StatusServiceUnavailable, "calls_disabled", "Calls are not configured on this server.")
	}
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	var in struct {
		Video bool `json:"video"`
	}
	decode(r, &in)
	ctx, p := r.Context(), me(r)
	m, err := s.membershipOf(ctx, id, p.UserID)
	if err != nil {
		return err
	}
	if !m.can(PermStartCalls) && m.Kind != "channel" {
		return errForbidden
	}
	room := "conv-" + id.String()

	s.callsMu.Lock()
	call, ongoing := s.calls[id]
	if !ongoing || time.Since(call.StartedAt) > 12*time.Hour {
		call = &activeCall{Room: room, StartedBy: p.UserID, StartedAt: time.Now(), Video: in.Video}
		s.calls[id] = call
		ongoing = false
	}
	s.callsMu.Unlock()

	var name string
	s.db.QueryRow(ctx, `SELECT display_name FROM users WHERE id = $1`, p.UserID).Scan(&name)
	token, err := s.liveKitToken(room, p.UserID.String()+":"+p.DeviceID.String(), name, m.Kind != "channel" || m.can(PermSend))
	if err != nil {
		return err
	}
	if !ongoing {
		go s.ring(id, p, name, in.Video)
	}
	writeJSON(w, http.StatusOK, map[string]any{"url": s.cfg.LiveKitURL, "token": token, "room": room, "call": call, "joined_existing": ongoing})
	return nil
}

func (s *Server) liveKitToken(room, identity, name string, canPublish bool) (string, error) {
	now := time.Now()
	claims := jwt.MapClaims{
		"iss":  s.cfg.LiveKitAPIKey,
		"sub":  identity,
		"name": name,
		"nbf":  now.Add(-time.Minute).Unix(),
		"exp":  now.Add(6 * time.Hour).Unix(),
		"video": map[string]any{
			"room": room, "roomJoin": true, "canPublish": canPublish, "canSubscribe": true, "canPublishData": true,
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(s.cfg.LiveKitAPISecret))
}

func (s *Server) ring(conv uuid.UUID, caller *principal, callerName string, video bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	ev := map[string]any{"conversation_id": conv, "caller_id": caller.UserID, "caller_name": callerName, "video": video, "call_id": uuid.New()}
	rows, err := s.db.Query(ctx, `SELECT d.id, d.push_kind, d.push_token, d.voip_token FROM devices d
		JOIN members m ON m.user_id = d.user_id
		WHERE m.conversation_id = $1 AND d.user_id <> $2 AND (m.muted_until IS NULL OR m.muted_until < now())`, conv, caller.UserID)
	if err != nil {
		return
	}
	type target struct {
		id                 uuid.UUID
		kind, token, voip string
	}
	targets, _ := pgx.CollectRows(rows, func(row pgx.CollectableRow) (target, error) {
		var t target
		return t, row.Scan(&t.id, &t.kind, &t.token, &t.voip)
	})
	for _, t := range targets {
		s.hub.ToDevice(t.id, realtime.Event{Type: "call.ring", Data: ev})
		if s.push == nil {
			continue
		}
		// iOS must receive a VoIP push to report to CallKit even when connected.
		switch {
		case t.kind == "apns" && t.voip != "":
			s.push.Send(ctx, "apns", t.voip, push.Notification{Kind: push.VoIP, Data: ev})
		case t.kind == "fcm" && !s.hub.DeviceOnline(t.id):
			s.push.Send(ctx, "fcm", t.token, push.Notification{Kind: push.VoIP, Data: ev, Collapse: "call-" + conv.String()})
		}
	}
}

func (s *Server) endCall(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	var in struct {
		Reason string `json:"reason"` // hangup | declined | missed
		All    bool   `json:"all"`    // end for everyone (last participant or 1:1)
	}
	decode(r, &in)
	ctx, p := r.Context(), me(r)
	m, err := s.membershipOf(ctx, id, p.UserID)
	if err != nil {
		return err
	}
	if in.All || m.Kind == "dm" {
		s.callsMu.Lock()
		delete(s.calls, id)
		s.callsMu.Unlock()
		s.hub.ToUsers(s.memberIDs(ctx, id), realtime.Event{Type: "call.ended", Data: map[string]any{
			"conversation_id": id, "by": p.UserID, "reason": in.Reason}}, uuid.Nil)
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}
