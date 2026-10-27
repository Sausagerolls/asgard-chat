package api

import (
	"context"

	"github.com/google/uuid"
)

// Conversation permissions. Owners and admins have all of them; moderators a
// fixed set; members use the conversation's member_permissions unless they
// have a per-member override.
const (
	PermSend int64 = 1 << iota
	PermSendMedia
	PermAddMembers
	PermPin
	PermEditInfo
	PermDeleteOthers
	PermManageMembers
	PermManageWebhooks
	PermStartCalls
	PermMentionAll
	PermBypassSlowMode
	PermPostStories // reserved
	PermAll int64 = 1<<62 - 1
)

const (
	defaultGroupPerms     = PermSend | PermSendMedia | PermAddMembers | PermPin | PermStartCalls | PermMentionAll
	defaultChannelPerms   = 0 // subscribers react, vote and comment in threads only
	defaultCommunityPerms = PermSend | PermSendMedia | PermStartCalls
	moderatorPerms        = PermSend | PermSendMedia | PermAddMembers | PermPin | PermDeleteOthers |
		PermManageMembers | PermStartCalls | PermMentionAll | PermBypassSlowMode
)

var roleRank = map[string]int{"subscriber": 0, "member": 1, "moderator": 2, "admin": 3, "owner": 4}

type membership struct {
	Role        string
	Perms       int64
	Kind        string
	SlowMode    int
	Disappear   int
	CommunityID *uuid.UUID
}

func (m *membership) can(p int64) bool { return m.Perms&p == p }

// membershipOf returns the caller's role and effective permissions, or
// errNotFound if they are not a member (so non-members cannot probe ids).
func (s *Server) membershipOf(ctx context.Context, conv, user uuid.UUID) (*membership, error) {
	m := &membership{}
	var override *int64
	var memberPerms int64
	err := s.db.QueryRow(ctx, `
		SELECT m.role, m.permissions, c.member_permissions, c.kind, c.slow_mode_seconds, c.disappearing_seconds, c.community_id
		FROM members m JOIN conversations c ON c.id = m.conversation_id
		WHERE m.conversation_id = $1 AND m.user_id = $2`, conv, user).
		Scan(&m.Role, &override, &memberPerms, &m.Kind, &m.SlowMode, &m.Disappear, &m.CommunityID)
	if err != nil {
		return nil, errNotFound
	}
	switch m.Role {
	case "owner", "admin":
		m.Perms = PermAll
	case "moderator":
		m.Perms = moderatorPerms
	default:
		m.Perms = memberPerms
	}
	if override != nil {
		m.Perms = *override
	}
	if m.Kind == "dm" || m.Kind == "saved" {
		m.Perms = PermAll &^ (PermAddMembers | PermManageMembers | PermManageWebhooks)
	}
	return m, nil
}
