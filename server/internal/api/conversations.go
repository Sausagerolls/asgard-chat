package api

import (
	"context"
	"net/http"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/giantmushroom/asgard-chat/server/internal/realtime"
)

type MyMembership struct {
	Role       string     `json:"role"`
	Perms      int64      `json:"permissions"`
	MutedUntil *time.Time `json:"muted_until"`
	Pinned     bool       `json:"pinned"`
	Archived   bool       `json:"archived"`
	Folder     string     `json:"folder"`
	ReadSeq    int64      `json:"read_seq"`
}

type Conversation struct {
	ID                uuid.UUID     `json:"id"`
	Kind              string        `json:"kind"`
	CommunityID       *uuid.UUID    `json:"community_id"`
	Title             string        `json:"title"`
	Description       string        `json:"description"`
	AvatarMediaID     *uuid.UUID    `json:"avatar_media_id"`
	CreatedBy         *uuid.UUID    `json:"created_by"`
	CreatedAt         time.Time     `json:"created_at"`
	LastSeq           int64         `json:"last_seq"`
	LastMessageAt     *time.Time    `json:"last_message_at"`
	DisappearSeconds  int           `json:"disappearing_seconds"`
	SlowModeSeconds   int           `json:"slow_mode_seconds"`
	MemberPermissions int64         `json:"member_permissions"`
	IsPublic          bool          `json:"is_public"`
	MemberCount       int           `json:"member_count"`
	HasServerBot      bool          `json:"has_server_bot"`
	Unread            int           `json:"unread"`
	Me                *MyMembership `json:"me,omitempty"`
	Peer              *User         `json:"peer,omitempty"`
	LastMessage       *Envelope     `json:"last_message,omitempty"`
}

const convCols = `c.id, c.kind, c.community_id, c.title, c.description, c.avatar_media_id, c.created_by, c.created_at,
	c.last_seq, c.last_message_at, c.disappearing_seconds, c.slow_mode_seconds, c.member_permissions, c.is_public,
	(SELECT count(*) FROM members x WHERE x.conversation_id = c.id),
	EXISTS(SELECT 1 FROM members x JOIN users bu ON bu.id = x.user_id WHERE x.conversation_id = c.id AND bu.server_bot)`

func scanConv(row pgx.Row, extra ...any) (*Conversation, error) {
	c := &Conversation{}
	dest := []any{&c.ID, &c.Kind, &c.CommunityID, &c.Title, &c.Description, &c.AvatarMediaID, &c.CreatedBy, &c.CreatedAt,
		&c.LastSeq, &c.LastMessageAt, &c.DisappearSeconds, &c.SlowModeSeconds, &c.MemberPermissions, &c.IsPublic, &c.MemberCount, &c.HasServerBot}
	return c, row.Scan(append(dest, extra...)...)
}

// loadConversation returns the conversation as seen by user (with prefs, peer, last message).
func (s *Server) loadConversation(ctx context.Context, id uuid.UUID, p *principal) (*Conversation, error) {
	m, err := s.membershipOf(ctx, id, p.UserID)
	if err != nil {
		return nil, err
	}
	my := &MyMembership{Role: m.Role, Perms: m.Perms}
	c, err := scanConv(s.db.QueryRow(ctx, `SELECT `+convCols+`, m.muted_until, m.pinned, m.archived, m.folder, m.read_seq
		FROM conversations c JOIN members m ON m.conversation_id = c.id AND m.user_id = $2 WHERE c.id = $1`, id, p.UserID),
		&my.MutedUntil, &my.Pinned, &my.Archived, &my.Folder, &my.ReadSeq)
	if err != nil {
		return nil, err
	}
	c.Me = my
	return c, s.decorate(ctx, []*Conversation{c}, p)
}

// decorate fills peer, unread count and the last message envelope.
func (s *Server) decorate(ctx context.Context, convs []*Conversation, p *principal) error {
	for _, c := range convs {
		if c.Kind == "dm" {
			u, err := scanUser(s.db.QueryRow(ctx, `SELECT `+userCols+` FROM members m JOIN users u ON u.id = m.user_id
				WHERE m.conversation_id = $1 AND m.user_id <> $2 LIMIT 1`, c.ID, p.UserID))
			if err == nil {
				c.Peer = s.publicView(u)
			}
		}
		if c.Me != nil {
			s.db.QueryRow(ctx, `SELECT count(*) FROM messages WHERE conversation_id = $1 AND seq > $2 AND kind = 'msg'
				AND sender_user_id IS DISTINCT FROM $3 AND NOT deleted`, c.ID, c.Me.ReadSeq, p.UserID).Scan(&c.Unread)
		}
		envs, err := s.queryEnvelopes(ctx, p.DeviceID, `m.conversation_id = $2 AND m.kind IN ('msg', 'system') AND NOT m.deleted ORDER BY m.seq DESC LIMIT 1`, c.ID)
		if err != nil {
			return err
		}
		if len(envs) > 0 {
			c.LastMessage = &envs[0]
		}
	}
	return nil
}

func (s *Server) listConversations(w http.ResponseWriter, r *http.Request) error {
	p := me(r)
	ctx := r.Context()
	rows, err := s.db.Query(ctx, `SELECT `+convCols+`, m.role, m.muted_until, m.pinned, m.archived, m.folder, m.read_seq
		FROM members m JOIN conversations c ON c.id = m.conversation_id
		WHERE m.user_id = $1 ORDER BY m.pinned DESC, coalesce(c.last_message_at, c.created_at) DESC`, p.UserID)
	if err != nil {
		return err
	}
	var convs []*Conversation
	for rows.Next() {
		my := &MyMembership{}
		c, err := scanConv(rows, &my.Role, &my.MutedUntil, &my.Pinned, &my.Archived, &my.Folder, &my.ReadSeq)
		if err != nil {
			rows.Close()
			return err
		}
		c.Me = my
		convs = append(convs, c)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, c := range convs {
		if m, err := s.membershipOf(ctx, c.ID, p.UserID); err == nil {
			c.Me.Perms = m.Perms
		}
	}
	if err := s.decorate(ctx, convs, p); err != nil {
		return err
	}
	if convs == nil {
		convs = []*Conversation{}
	}
	writeJSON(w, http.StatusOK, convs)
	return nil
}

func (s *Server) getConversation(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	c, err := s.loadConversation(r.Context(), id, me(r))
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, c)
	return nil
}

func (s *Server) createConversation(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Kind             string      `json:"kind"`
		Title            string      `json:"title"`
		Description      string      `json:"description"`
		AvatarMediaID    *uuid.UUID  `json:"avatar_media_id"`
		MemberIDs        []uuid.UUID `json:"member_ids"`
		CommunityID      *uuid.UUID  `json:"community_id"`
		IsPublic         bool        `json:"is_public"`
		DisappearSeconds int         `json:"disappearing_seconds"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	members := uniqueIDs(in.MemberIDs, p.UserID)

	if in.Kind == "dm" {
		if len(members) != 1 {
			return badRequest("A direct message has exactly one other member.")
		}
		return s.openDM(w, r, members[0])
	}
	if in.Kind != "group" && in.Kind != "channel" && in.Kind != "community" {
		return badRequest("kind must be dm, group, channel or community")
	}
	if trim(in.Title, 100) == "" {
		return badRequest("Give it a name.")
	}
	if in.CommunityID != nil {
		cm, err := s.membershipOf(ctx, *in.CommunityID, p.UserID)
		if err != nil || cm.Kind != "community" {
			return errNotFound
		}
		if !cm.can(PermEditInfo) {
			return errForbidden
		}
	}
	if in.IsPublic && !s.settings(ctx).AllowPublicGroups && !p.IsAdmin {
		return errf(http.StatusForbidden, "public_disabled", "The server admin has disabled public groups.")
	}
	if err := s.checkCanAdd(ctx, p.UserID, members); err != nil {
		return err
	}
	perms := map[string]int64{"group": defaultGroupPerms, "channel": defaultChannelPerms, "community": defaultCommunityPerms}[in.Kind]
	memberRole := "member"
	if in.Kind == "channel" {
		memberRole = "subscriber"
	}
	id := uuid.New()
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `INSERT INTO conversations(id, kind, community_id, title, description, avatar_media_id, created_by, member_permissions, is_public, disappearing_seconds)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`, id, in.Kind, in.CommunityID, trim(in.Title, 100), trim(in.Description, 1000), in.AvatarMediaID,
		p.UserID, perms, in.IsPublic, in.DisappearSeconds); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO members(conversation_id, user_id, role) VALUES ($1,$2,'owner')`, id, p.UserID); err != nil {
		return err
	}
	for _, u := range members {
		if _, err := tx.Exec(ctx, `INSERT INTO members(conversation_id, user_id, role) VALUES ($1,$2,$3)`, id, u, memberRole); err != nil {
			return badRequest("Unknown member " + u.String())
		}
	}
	if in.Kind == "community" {
		// Every community starts with an announcements channel and a general chat.
		for _, sub := range []struct {
			kind, title string
			perms       int64
		}{
			{"channel", "Announcements", defaultChannelPerms}, {"group", "General", defaultGroupPerms},
		} {
			subID := uuid.New()
			if _, err := tx.Exec(ctx, `INSERT INTO conversations(id, kind, community_id, title, created_by, member_permissions) VALUES ($1,$2,$3,$4,$5,$6)`,
				subID, sub.kind, id, sub.title, p.UserID, sub.perms); err != nil {
				return err
			}
			role := "member"
			if sub.kind == "channel" {
				role = "subscriber"
			}
			tx.Exec(ctx, `INSERT INTO members(conversation_id, user_id, role) VALUES ($1,$2,'owner')`, subID, p.UserID)
			for _, u := range members {
				tx.Exec(ctx, `INSERT INTO members(conversation_id, user_id, role) VALUES ($1,$2,$3)`, subID, u, role)
			}
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	s.audit(ctx, p.UserID, "conversation.create", id.String(), map[string]any{"kind": in.Kind})
	s.postSystem(ctx, id, p.UserID, map[string]any{"event": "created", "title": in.Title})
	s.notifyConversation(ctx, id, "conversation.updated")
	c, err := s.loadConversation(ctx, id, p)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusCreated, c)
	return nil
}

func (s *Server) openDM(w http.ResponseWriter, r *http.Request, other uuid.UUID) error {
	ctx, p := r.Context(), me(r)
	if s.blocked(ctx, other, p.UserID) {
		return errf(http.StatusForbidden, "blocked", "You can't message this person.")
	}
	if err := s.checkCanAdd(ctx, p.UserID, []uuid.UUID{other}); err != nil {
		return err
	}
	pair := []string{p.UserID.String(), other.String()}
	sort.Strings(pair)
	key := "dm:" + pair[0] + ":" + pair[1]
	var id uuid.UUID
	status := http.StatusOK
	if err := s.db.QueryRow(ctx, `SELECT id FROM conversations WHERE dm_key = $1`, key).Scan(&id); err != nil {
		id = uuid.New()
		tx, err := s.db.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)
		if _, err := tx.Exec(ctx, `INSERT INTO conversations(id, kind, created_by, dm_key, disappearing_seconds) VALUES ($1,'dm',$2,$3,$4)`,
			id, p.UserID, key, s.settings(ctx).DefaultDisappear); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO members(conversation_id, user_id, role) VALUES ($1,$2,'member'), ($1,$3,'member')`, id, p.UserID, other); err != nil {
			return errNotFound
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		status = http.StatusCreated
		s.notifyConversation(ctx, id, "conversation.updated")
	}
	c, err := s.loadConversation(ctx, id, p)
	if err != nil {
		return err
	}
	writeJSON(w, status, c)
	return nil
}

// checkCanAdd enforces each target's "who can add me" privacy setting.
func (s *Server) checkCanAdd(ctx context.Context, actor uuid.UUID, targets []uuid.UUID) error {
	for _, t := range targets {
		var who string
		var isContact bool
		err := s.db.QueryRow(ctx, `SELECT coalesce(u.settings->>'who_can_add', 'everyone'),
			EXISTS(SELECT 1 FROM contacts c WHERE c.user_id = u.id AND c.contact_id = $2 AND NOT c.blocked)
			FROM users u WHERE u.id = $1 AND NOT u.disabled`, t, actor).Scan(&who, &isContact)
		if err != nil {
			return badRequest("Unknown user " + t.String())
		}
		if who == "contacts" && !isContact || s.blocked(ctx, t, actor) {
			return errf(http.StatusForbidden, "privacy", "One of these people only accepts invitations from their contacts.")
		}
	}
	return nil
}

func (s *Server) updateConversation(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	m, err := s.membershipOf(ctx, id, p.UserID)
	if err != nil {
		return err
	}
	var in struct {
		Title             *string    `json:"title"`
		Description       *string    `json:"description"`
		AvatarMediaID     *uuid.UUID `json:"avatar_media_id"`
		DisappearSeconds  *int       `json:"disappearing_seconds"`
		SlowModeSeconds   *int       `json:"slow_mode_seconds"`
		MemberPermissions *int64     `json:"member_permissions"`
		IsPublic          *bool      `json:"is_public"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	// In DMs either side may change the disappearing timer; nothing else.
	if m.Kind == "dm" && (in.Title != nil || in.Description != nil || in.AvatarMediaID != nil || in.SlowModeSeconds != nil || in.MemberPermissions != nil || in.IsPublic != nil) {
		return errForbidden
	}
	if !m.can(PermEditInfo) {
		return errForbidden
	}
	changes := map[string]any{}
	set := func(col string, v any) error {
		changes[col] = v
		_, err := s.db.Exec(ctx, `UPDATE conversations SET `+col+` = $2, updated_at = now() WHERE id = $1`, id, v)
		return err
	}
	if in.Title != nil {
		if err := set("title", trim(*in.Title, 100)); err != nil {
			return err
		}
	}
	if in.Description != nil {
		if err := set("description", trim(*in.Description, 1000)); err != nil {
			return err
		}
	}
	if in.AvatarMediaID != nil {
		if err := set("avatar_media_id", *in.AvatarMediaID); err != nil {
			return err
		}
	}
	if in.DisappearSeconds != nil {
		if err := set("disappearing_seconds", max(0, *in.DisappearSeconds)); err != nil {
			return err
		}
	}
	if in.SlowModeSeconds != nil {
		if err := set("slow_mode_seconds", max(0, *in.SlowModeSeconds)); err != nil {
			return err
		}
	}
	if in.MemberPermissions != nil {
		if m.Role != "owner" && m.Role != "admin" {
			return errForbidden
		}
		if err := set("member_permissions", *in.MemberPermissions&PermAll); err != nil {
			return err
		}
	}
	if in.IsPublic != nil {
		if err := set("is_public", *in.IsPublic); err != nil {
			return err
		}
	}
	if len(changes) > 0 {
		s.postSystem(ctx, id, p.UserID, map[string]any{"event": "updated", "changes": changes})
		s.notifyConversation(ctx, id, "conversation.updated")
	}
	c, err := s.loadConversation(ctx, id, p)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, c)
	return nil
}

func (s *Server) deleteConversation(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	m, err := s.membershipOf(ctx, id, p.UserID)
	if err != nil {
		return err
	}
	if m.Role != "owner" && !p.IsAdmin || m.Kind == "saved" {
		return errForbidden
	}
	members := s.memberIDs(ctx, id)
	if _, err := s.db.Exec(ctx, `DELETE FROM conversations WHERE id = $1`, id); err != nil {
		return err
	}
	s.hub.ToUsers(members, realtime.Event{Type: "conversation.removed", Data: map[string]any{"conversation_id": id}}, uuid.Nil)
	s.audit(ctx, p.UserID, "conversation.delete", id.String(), nil)
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) discoverConversations(w http.ResponseWriter, r *http.Request) error {
	p := me(r)
	rows, err := s.db.Query(r.Context(), `SELECT `+convCols+` FROM conversations c
		WHERE c.kind IN ('group', 'channel', 'community')
		  AND NOT EXISTS (SELECT 1 FROM members m WHERE m.conversation_id = c.id AND m.user_id = $1)
		  AND (c.is_public OR c.community_id IN (SELECT conversation_id FROM members WHERE user_id = $1))
		ORDER BY c.last_message_at DESC NULLS LAST LIMIT 100`, p.UserID)
	if err != nil {
		return err
	}
	convs, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (*Conversation, error) { return scanConv(row) })
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, convs)
	return nil
}

func (s *Server) joinConversation(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	var kind string
	var public, inCommunity bool
	err = s.db.QueryRow(ctx, `SELECT c.kind, c.is_public,
		EXISTS(SELECT 1 FROM members m WHERE m.conversation_id = c.community_id AND m.user_id = $2)
		FROM conversations c WHERE c.id = $1`, id, p.UserID).Scan(&kind, &public, &inCommunity)
	if err != nil || !(public || inCommunity) || kind == "dm" || kind == "saved" {
		return errNotFound
	}
	role := "member"
	if kind == "channel" {
		role = "subscriber"
	}
	tag, err := s.db.Exec(ctx, `INSERT INTO members(conversation_id, user_id, role) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, id, p.UserID, role)
	if err != nil {
		return err
	}
	if tag.RowsAffected() > 0 {
		s.postSystem(ctx, id, p.UserID, map[string]any{"event": "joined", "user_id": p.UserID})
		s.keysChanged(ctx, p.UserID)
	}
	c, err := s.loadConversation(ctx, id, p)
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, c)
	return nil
}

func (s *Server) leaveConversation(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	m, err := s.membershipOf(ctx, id, p.UserID)
	if err != nil {
		return err
	}
	if m.Kind == "saved" {
		return badRequest("You can't leave Saved Messages.")
	}
	if err := s.removeMemberRow(ctx, id, p.UserID, m.Role); err != nil {
		return err
	}
	s.postSystem(ctx, id, p.UserID, map[string]any{"event": "left", "user_id": p.UserID})
	s.hub.ToUsers([]uuid.UUID{p.UserID}, realtime.Event{Type: "conversation.removed", Data: map[string]any{"conversation_id": id}}, uuid.Nil)
	w.WriteHeader(http.StatusNoContent)
	return nil
}

// removeMemberRow deletes a membership, handing ownership on if needed.
func (s *Server) removeMemberRow(ctx context.Context, conv, user uuid.UUID, role string) error {
	if _, err := s.db.Exec(ctx, `DELETE FROM members WHERE conversation_id = $1 AND user_id = $2`, conv, user); err != nil {
		return err
	}
	if role == "owner" {
		s.db.Exec(ctx, `UPDATE members SET role = 'owner' WHERE (conversation_id, user_id) = (
			SELECT conversation_id, user_id FROM members WHERE conversation_id = $1
			ORDER BY CASE role WHEN 'admin' THEN 0 WHEN 'moderator' THEN 1 WHEN 'member' THEN 2 ELSE 3 END, joined_at LIMIT 1)`, conv)
	}
	return nil
}

func (s *Server) updatePrefs(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	var in struct {
		MutedUntil *time.Time `json:"muted_until"`
		Pinned     *bool      `json:"pinned"`
		Archived   *bool      `json:"archived"`
		Folder     *string    `json:"folder"`
		Unmute     bool       `json:"unmute"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	if _, err := s.membershipOf(ctx, id, p.UserID); err != nil {
		return err
	}
	if in.MutedUntil != nil || in.Unmute {
		s.db.Exec(ctx, `UPDATE members SET muted_until = $3 WHERE conversation_id = $1 AND user_id = $2`, id, p.UserID, in.MutedUntil)
	}
	if in.Pinned != nil {
		s.db.Exec(ctx, `UPDATE members SET pinned = $3 WHERE conversation_id = $1 AND user_id = $2`, id, p.UserID, *in.Pinned)
	}
	if in.Archived != nil {
		s.db.Exec(ctx, `UPDATE members SET archived = $3 WHERE conversation_id = $1 AND user_id = $2`, id, p.UserID, *in.Archived)
	}
	if in.Folder != nil {
		s.db.Exec(ctx, `UPDATE members SET folder = $3 WHERE conversation_id = $1 AND user_id = $2`, id, p.UserID, trim(*in.Folder, 32))
	}
	c, err := s.loadConversation(ctx, id, p)
	if err != nil {
		return err
	}
	// Sync prefs to the user's other devices.
	s.hub.ToUsers([]uuid.UUID{p.UserID}, realtime.Event{Type: "conversation.updated", Data: c}, p.DeviceID)
	writeJSON(w, http.StatusOK, c)
	return nil
}

type Member struct {
	User     *User     `json:"user"`
	Role     string    `json:"role"`
	JoinedAt time.Time `json:"joined_at"`
	ReadSeq  int64     `json:"read_seq"`
}

func (s *Server) listMembers(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	if _, err := s.membershipOf(ctx, id, p.UserID); err != nil {
		return err
	}
	rows, err := s.db.Query(ctx, `SELECT `+userCols+`, m.role, m.joined_at, m.read_seq FROM members m JOIN users u ON u.id = m.user_id
		WHERE m.conversation_id = $1 ORDER BY CASE m.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 WHEN 'moderator' THEN 2 ELSE 3 END, u.display_name`, id)
	if err != nil {
		return err
	}
	defer rows.Close()
	out := []Member{}
	for rows.Next() {
		u := &User{}
		var settings []byte
		var m Member
		if err := rows.Scan(&u.ID, &u.Username, &u.DisplayName, &u.Bio, &u.AvatarMediaID, &u.IsAdmin, &u.IsBot, &u.ServerBot, &u.LastSeenAt, &u.CreatedAt, &settings, &m.Role, &m.JoinedAt, &m.ReadSeq); err != nil {
			return err
		}
		m.User = s.publicView(u)
		out = append(out, m)
	}
	writeJSON(w, http.StatusOK, out)
	return rows.Err()
}

func (s *Server) addMembers(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	var in struct {
		UserIDs []uuid.UUID `json:"user_ids"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	m, err := s.membershipOf(ctx, id, p.UserID)
	if err != nil {
		return err
	}
	if !m.can(PermAddMembers) || m.Kind == "dm" || m.Kind == "saved" {
		return errForbidden
	}
	ids := uniqueIDs(in.UserIDs, p.UserID)
	if err := s.checkCanAdd(ctx, p.UserID, ids); err != nil {
		return err
	}
	role := "member"
	if m.Kind == "channel" {
		role = "subscriber"
	}
	var added []uuid.UUID
	for _, u := range ids {
		tag, err := s.db.Exec(ctx, `INSERT INTO members(conversation_id, user_id, role) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING`, id, u, role)
		if err == nil && tag.RowsAffected() > 0 {
			added = append(added, u)
		}
	}
	if len(added) > 0 {
		s.postSystem(ctx, id, p.UserID, map[string]any{"event": "members_added", "user_ids": added})
		s.notifyConversation(ctx, id, "conversation.updated")
	}
	writeJSON(w, http.StatusOK, map[string]any{"added": added})
	return nil
}

func (s *Server) updateMember(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	target, err := pathUUID(r, "userID")
	if err != nil {
		return err
	}
	var in struct {
		Role        *string `json:"role"`
		Permissions *int64  `json:"permissions"`
		ClearPerms  bool    `json:"clear_permissions"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	actor, err := s.membershipOf(ctx, id, p.UserID)
	if err != nil {
		return err
	}
	tm, err := s.membershipOf(ctx, id, target)
	if err != nil {
		return err
	}
	if !actor.can(PermManageMembers) || roleRank[actor.Role] <= roleRank[tm.Role] {
		return errForbidden
	}
	if in.Role != nil {
		newRole := *in.Role
		if _, ok := roleRank[newRole]; !ok {
			return badRequest("Unknown role.")
		}
		if newRole == "owner" {
			if actor.Role != "owner" {
				return errForbidden
			}
			// Transfer ownership.
			s.db.Exec(ctx, `UPDATE members SET role = 'admin' WHERE conversation_id = $1 AND user_id = $2`, id, p.UserID)
		} else if roleRank[newRole] >= roleRank[actor.Role] {
			return errForbidden
		}
		if _, err := s.db.Exec(ctx, `UPDATE members SET role = $3 WHERE conversation_id = $1 AND user_id = $2`, id, target, newRole); err != nil {
			return err
		}
	}
	if in.Permissions != nil || in.ClearPerms {
		var v *int64
		if !in.ClearPerms {
			pv := *in.Permissions & actor.Perms // cannot grant what you don't have
			v = &pv
		}
		s.db.Exec(ctx, `UPDATE members SET permissions = $3 WHERE conversation_id = $1 AND user_id = $2`, id, target, v)
	}
	s.postSystem(ctx, id, p.UserID, map[string]any{"event": "member_updated", "user_id": target, "role": in.Role})
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) removeMember(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	target, err := pathUUID(r, "userID")
	if err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	if target == p.UserID {
		return s.leaveConversation(w, r)
	}
	actor, err := s.membershipOf(ctx, id, p.UserID)
	if err != nil {
		return err
	}
	tm, err := s.membershipOf(ctx, id, target)
	if err != nil {
		return err
	}
	if !actor.can(PermManageMembers) || roleRank[actor.Role] <= roleRank[tm.Role] {
		return errForbidden
	}
	if err := s.removeMemberRow(ctx, id, target, tm.Role); err != nil {
		return err
	}
	s.postSystem(ctx, id, p.UserID, map[string]any{"event": "member_removed", "user_id": target})
	s.hub.ToUsers([]uuid.UUID{target}, realtime.Event{Type: "conversation.removed", Data: map[string]any{"conversation_id": id}}, uuid.Nil)
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *Server) conversationDevices(w http.ResponseWriter, r *http.Request) error {
	id, err := pathUUID(r, "convID")
	if err != nil {
		return err
	}
	ctx, p := r.Context(), me(r)
	if _, err := s.membershipOf(ctx, id, p.UserID); err != nil {
		return err
	}
	devices, err := s.devicesOf(ctx, s.memberIDs(ctx, id))
	if err != nil {
		return err
	}
	writeJSON(w, http.StatusOK, devices)
	return nil
}

func (s *Server) memberIDs(ctx context.Context, conv uuid.UUID) []uuid.UUID {
	rows, err := s.db.Query(ctx, `SELECT user_id FROM members WHERE conversation_id = $1`, conv)
	if err != nil {
		return nil
	}
	ids, _ := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	return ids
}

// notifyConversation tells every member to refetch the conversation.
func (s *Server) notifyConversation(ctx context.Context, conv uuid.UUID, typ string) {
	s.hub.ToUsers(s.memberIDs(ctx, conv), realtime.Event{Type: typ, Data: map[string]any{"conversation_id": conv}}, uuid.Nil)
}

func uniqueIDs(ids []uuid.UUID, exclude uuid.UUID) []uuid.UUID {
	seen := map[uuid.UUID]bool{exclude: true, uuid.Nil: true}
	var out []uuid.UUID
	for _, id := range ids {
		if !seen[id] {
			seen[id] = true
			out = append(out, id)
		}
	}
	return out
}
