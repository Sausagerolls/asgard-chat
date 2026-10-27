package api

import (
	"context"
	"net/http"
	"sort"
	"time"

	"github.com/google/uuid"

	"github.com/giantmushroom/asgard-chat/server/internal/realtime"
)

// Voice rooms are always-open LiveKit rooms attached to a group, channel or
// community. Members drop in and out whenever they like; nobody is rung.
// The server only tracks who is in each room so members can see it. Media
// is end-to-end encrypted with a key the participants share among themselves.

// voiceStale is how long a participant may go without a heartbeat before the
// server assumes they left. Clients heartbeat every 30 seconds; a backgrounded
// app in a call may drop its WebSocket but keeps heartbeating.
const voiceStale = 75 * time.Second

type voiceParticipant struct {
	UserID   uuid.UUID `json:"user_id"`
	DeviceID uuid.UUID `json:"device_id"`
	Name     string    `json:"name"`
	Muted    bool      `json:"muted"`
	Video    bool      `json:"video"`
	JoinedAt time.Time `json:"joined_at"`
	seen     time.Time
}

func voiceRoomName(conv uuid.UUID) string { return "voice-" + conv.String() }

// voiceParticipants returns the room's participants, earliest joiner first.
// Callers must hold voiceMu.
func (s *Server) voiceParticipants(conv uuid.UUID) []voiceParticipant {
	out := make([]voiceParticipant, 0, len(s.voice[conv]))
	for _, p := range s.voice[conv] {
		out = append(out, *p)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].JoinedAt.Before(out[j].JoinedAt) })
	return out
}

func (s *Server) voiceMembership(r *http.Request) (uuid.UUID, *membership, error) {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return uuid.Nil, nil, err
	}
	m, err := s.membershipOf(r.Context(), id, me(r).UserID)
	if err != nil {
		return uuid.Nil, nil, err
	}
	if m.Kind != "group" && m.Kind != "channel" {
		return uuid.Nil, nil, errf(http.StatusBadRequest, "no_voice_room", "Only groups and channels have voice rooms.")
	}
	return id, m, nil
}

func (s *Server) broadcastVoice(ctx context.Context, conv uuid.UUID) {
	s.voiceMu.Lock()
	parts := s.voiceParticipants(conv)
	s.voiceMu.Unlock()
	s.hub.ToUsers(s.memberIDs(ctx, conv), realtime.Event{Type: "voice.state", Data: map[string]any{
		"conversation_id": conv, "room": voiceRoomName(conv), "participants": parts}}, uuid.Nil)
}

// voiceRoom lists who is in one conversation's voice room.
func (s *Server) voiceRoom(w http.ResponseWriter, r *http.Request) error {
	id, _, err := s.voiceMembership(r)
	if err != nil {
		return err
	}
	s.voiceMu.Lock()
	parts := s.voiceParticipants(id)
	s.voiceMu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"conversation_id": id, "room": voiceRoomName(id), "participants": parts})
	return nil
}

// activeVoiceRooms lists every occupied voice room the caller can see.
func (s *Server) activeVoiceRooms(w http.ResponseWriter, r *http.Request) error {
	s.voiceMu.Lock()
	convs := make([]uuid.UUID, 0, len(s.voice))
	for id, room := range s.voice {
		if len(room) > 0 {
			convs = append(convs, id)
		}
	}
	s.voiceMu.Unlock()
	out := []map[string]any{}
	if len(convs) > 0 {
		rows, err := s.db.Query(r.Context(), `SELECT conversation_id FROM members WHERE user_id = $1 AND conversation_id = ANY($2)`, me(r).UserID, convs)
		if err != nil {
			return err
		}
		var mine []uuid.UUID
		for rows.Next() {
			var id uuid.UUID
			if rows.Scan(&id) == nil {
				mine = append(mine, id)
			}
		}
		rows.Close()
		s.voiceMu.Lock()
		for _, id := range mine {
			if parts := s.voiceParticipants(id); len(parts) > 0 {
				out = append(out, map[string]any{"conversation_id": id, "room": voiceRoomName(id), "participants": parts})
			}
		}
		s.voiceMu.Unlock()
	}
	writeJSON(w, http.StatusOK, out)
	return nil
}

// joinVoice adds the caller's device to the room and returns a LiveKit token.
// "first" tells the client to create and share a fresh media key.
func (s *Server) joinVoice(w http.ResponseWriter, r *http.Request) error {
	if !s.cfg.CallsEnabled() {
		return errf(http.StatusServiceUnavailable, "calls_disabled", "Calls are not configured on this server.")
	}
	id, m, err := s.voiceMembership(r)
	if err != nil {
		return err
	}
	if !m.can(PermVoice) {
		return errForbidden
	}
	var in struct {
		Muted bool `json:"muted"`
		Video bool `json:"video"`
	}
	decode(r, &in)
	ctx, p := r.Context(), me(r)
	var name string
	s.db.QueryRow(ctx, `SELECT display_name FROM users WHERE id = $1`, p.UserID).Scan(&name)
	room := voiceRoomName(id)
	token, err := s.liveKitToken(room, p.UserID.String()+":"+p.DeviceID.String(), name, true)
	if err != nil {
		return err
	}

	now := time.Now()
	s.voiceMu.Lock()
	if s.voice[id] == nil {
		s.voice[id] = map[uuid.UUID]*voiceParticipant{}
	}
	_, rejoin := s.voice[id][p.DeviceID]
	first := len(s.voice[id]) == 0 || (rejoin && len(s.voice[id]) == 1)
	s.voice[id][p.DeviceID] = &voiceParticipant{UserID: p.UserID, DeviceID: p.DeviceID, Name: name,
		Muted: in.Muted, Video: in.Video, JoinedAt: now, seen: now}
	parts := s.voiceParticipants(id)
	s.voiceMu.Unlock()

	go s.broadcastVoice(context.WithoutCancel(ctx), id)
	writeJSON(w, http.StatusOK, map[string]any{"url": s.cfg.LiveKitURL, "token": token, "room": room,
		"first": first, "participants": parts})
	return nil
}

// updateVoice changes the caller's mute/video state; it doubles as the heartbeat.
func (s *Server) updateVoice(w http.ResponseWriter, r *http.Request) error {
	id, _, err := s.voiceMembership(r)
	if err != nil {
		return err
	}
	var in struct {
		Muted *bool `json:"muted"`
		Video *bool `json:"video"`
	}
	decode(r, &in)
	p := me(r)
	changed := false
	s.voiceMu.Lock()
	vp := s.voice[id][p.DeviceID]
	if vp != nil {
		vp.seen = time.Now()
		if in.Muted != nil && *in.Muted != vp.Muted {
			vp.Muted, changed = *in.Muted, true
		}
		if in.Video != nil && *in.Video != vp.Video {
			vp.Video, changed = *in.Video, true
		}
	}
	s.voiceMu.Unlock()
	if vp == nil {
		return errf(http.StatusNotFound, "not_in_room", "You're not in this voice room.")
	}
	if changed {
		go s.broadcastVoice(context.WithoutCancel(r.Context()), id)
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) leaveVoice(w http.ResponseWriter, r *http.Request) error {
	id, _, err := s.voiceMembership(r)
	if err != nil {
		return err
	}
	if s.removeVoice(id, me(r).DeviceID) {
		go s.broadcastVoice(context.WithoutCancel(r.Context()), id)
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) removeVoice(conv, device uuid.UUID) bool {
	s.voiceMu.Lock()
	defer s.voiceMu.Unlock()
	if _, ok := s.voice[conv][device]; !ok {
		return false
	}
	delete(s.voice[conv], device)
	if len(s.voice[conv]) == 0 {
		delete(s.voice, conv)
	}
	return true
}

// sweepVoice drops participants whose app stopped heartbeating (crash, lost
// signal) so rooms never show ghosts.
func (s *Server) sweepVoice(ctx context.Context) {
	now := time.Now()
	var changed []uuid.UUID
	s.voiceMu.Lock()
	for conv, room := range s.voice {
		before := len(room)
		for dev, p := range room {
			if now.Sub(p.seen) > voiceStale {
				delete(room, dev)
			}
		}
		if len(room) != before {
			changed = append(changed, conv)
		}
		if len(room) == 0 {
			delete(s.voice, conv)
		}
	}
	s.voiceMu.Unlock()
	for _, conv := range changed {
		s.broadcastVoice(ctx, conv)
	}
}
