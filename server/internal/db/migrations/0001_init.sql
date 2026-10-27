-- Asgard Chat initial schema.
-- Message content is end-to-end encrypted: the server stores ciphertext only.

CREATE EXTENSION IF NOT EXISTS citext;

CREATE TABLE users (
    id              uuid PRIMARY KEY,
    username        citext NOT NULL UNIQUE,
    display_name    text NOT NULL DEFAULT '',
    bio             text NOT NULL DEFAULT '',
    avatar_media_id uuid,
    password_hash   text NOT NULL DEFAULT '',
    is_admin        boolean NOT NULL DEFAULT false,
    is_bot          boolean NOT NULL DEFAULT false,
    bot_owner_id    uuid REFERENCES users(id) ON DELETE SET NULL,
    server_bot      boolean NOT NULL DEFAULT false,
    disabled        boolean NOT NULL DEFAULT false,
    storage_quota   bigint NOT NULL DEFAULT 0, -- bytes; 0 = unlimited
    settings        jsonb NOT NULL DEFAULT '{}', -- privacy toggles, see api/users.go
    created_at      timestamptz NOT NULL DEFAULT now(),
    last_seen_at    timestamptz
);

CREATE TABLE devices (
    id            uuid PRIMARY KEY,
    user_id       uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name          text NOT NULL DEFAULT '',
    platform      text NOT NULL DEFAULT '', -- ios, ipados, macos, watchos, android, wearos, web, bot
    identity_key  bytea NOT NULL,           -- X25519 public
    signing_key   bytea NOT NULL,           -- Ed25519 public
    sealed_private bytea,                   -- server-side bots only, sealed with master key
    push_kind     text NOT NULL DEFAULT '', -- apns, fcm
    push_token    text NOT NULL DEFAULT '',
    voip_token    text NOT NULL DEFAULT '',
    created_at    timestamptz NOT NULL DEFAULT now(),
    last_active_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX devices_user ON devices(user_id);

CREATE TABLE sessions (
    token_hash  bytea PRIMARY KEY,
    user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id   uuid REFERENCES devices(id) ON DELETE CASCADE,
    is_bot_token boolean NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL
);
CREATE INDEX sessions_device ON sessions(device_id);

CREATE TABLE invites (
    code        text PRIMARY KEY,
    created_by  uuid REFERENCES users(id) ON DELETE SET NULL,
    note        text NOT NULL DEFAULT '',
    max_uses    int NOT NULL DEFAULT 1,
    uses        int NOT NULL DEFAULT 0,
    make_admin  boolean NOT NULL DEFAULT false,
    expires_at  timestamptz,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE device_links (
    code        text PRIMARY KEY,
    user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_by_device uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    expires_at  timestamptz NOT NULL
);

CREATE TABLE contacts (
    user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    contact_id  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    nickname    text NOT NULL DEFAULT '',
    blocked     boolean NOT NULL DEFAULT false,
    created_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, contact_id)
);

-- kind: dm, group, channel, community, saved
CREATE TABLE conversations (
    id              uuid PRIMARY KEY,
    kind            text NOT NULL,
    community_id    uuid REFERENCES conversations(id) ON DELETE CASCADE,
    title           text NOT NULL DEFAULT '',
    description     text NOT NULL DEFAULT '',
    avatar_media_id uuid,
    created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    last_seq        bigint NOT NULL DEFAULT 0,
    last_message_at timestamptz,
    disappearing_seconds int NOT NULL DEFAULT 0,
    slow_mode_seconds    int NOT NULL DEFAULT 0,
    -- default permissions bitmask for plain members (see api/permissions.go)
    member_permissions   bigint NOT NULL DEFAULT 0,
    is_public       boolean NOT NULL DEFAULT false, -- discoverable on this server
    dm_key          text UNIQUE                    -- sorted user ids, for dm uniqueness
);
CREATE INDEX conversations_community ON conversations(community_id);

-- role: owner, admin, moderator, member, subscriber
CREATE TABLE members (
    conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role            text NOT NULL DEFAULT 'member',
    permissions     bigint, -- per-member override, null = role default
    joined_at       timestamptz NOT NULL DEFAULT now(),
    muted_until     timestamptz,
    pinned          boolean NOT NULL DEFAULT false,
    archived        boolean NOT NULL DEFAULT false,
    folder          text NOT NULL DEFAULT '',
    delivered_seq   bigint NOT NULL DEFAULT 0,
    read_seq        bigint NOT NULL DEFAULT 0,
    last_post_at    timestamptz,
    PRIMARY KEY (conversation_id, user_id)
);
CREATE INDEX members_user ON members(user_id);

CREATE TABLE messages (
    id               uuid PRIMARY KEY,
    conversation_id  uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    seq              bigint NOT NULL,
    client_id        uuid NOT NULL,
    kind             text NOT NULL, -- msg, edit, delete, reaction, vote, rsvp, system
    target_id        uuid,
    thread_root_id   uuid,
    sender_user_id   uuid REFERENCES users(id) ON DELETE SET NULL,
    sender_device_id uuid,
    alg              text NOT NULL DEFAULT 'fanout-v1',
    ciphertext       bytea,
    signature        bytea,
    system           jsonb,
    view_once        boolean NOT NULL DEFAULT false,
    deleted          boolean NOT NULL DEFAULT false,
    sent_at          timestamptz NOT NULL DEFAULT now(),
    expires_at       timestamptz,
    UNIQUE (conversation_id, seq),
    UNIQUE (sender_device_id, client_id)
);
CREATE INDEX messages_expiry ON messages(expires_at) WHERE expires_at IS NOT NULL;
CREATE INDEX messages_thread ON messages(thread_root_id) WHERE thread_root_id IS NOT NULL;
CREATE INDEX messages_target ON messages(target_id) WHERE target_id IS NOT NULL;

-- Per-device delivery queue. cursor is the device's sync position.
CREATE TABLE deliveries (
    cursor      bigserial PRIMARY KEY,
    device_id   uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    message_id  uuid NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
    wrapped_key bytea,
    UNIQUE (device_id, message_id)
);
CREATE INDEX deliveries_device ON deliveries(device_id, cursor);

CREATE TABLE scheduled_messages (
    id              uuid PRIMARY KEY,
    conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    sender_user_id  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sender_device_id uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    payload         jsonb NOT NULL, -- the original send request
    send_at         timestamptz NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX scheduled_due ON scheduled_messages(send_at);

CREATE TABLE media (
    id          uuid PRIMARY KEY,
    owner_id    uuid REFERENCES users(id) ON DELETE SET NULL,
    object_key  text NOT NULL,
    size        bigint NOT NULL,
    content_type text NOT NULL DEFAULT 'application/octet-stream',
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz
);
CREATE INDEX media_owner ON media(owner_id);

CREATE TABLE stories (
    id              uuid PRIMARY KEY,
    user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    sender_device_id uuid NOT NULL,
    ciphertext      bytea NOT NULL,
    signature       bytea NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    expires_at      timestamptz NOT NULL
);
CREATE INDEX stories_expiry ON stories(expires_at);

CREATE TABLE story_keys (
    story_id    uuid NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
    device_id   uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    wrapped_key bytea NOT NULL,
    PRIMARY KEY (story_id, device_id)
);

CREATE TABLE story_views (
    story_id    uuid NOT NULL REFERENCES stories(id) ON DELETE CASCADE,
    viewer_id   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    viewed_at   timestamptz NOT NULL DEFAULT now(),
    reaction    text NOT NULL DEFAULT '',
    PRIMARY KEY (story_id, viewer_id)
);

CREATE TABLE webhooks (
    id              uuid PRIMARY KEY,
    conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    bot_user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name            text NOT NULL DEFAULT '',
    secret_hash     bytea NOT NULL,
    created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE audit_log (
    id          bigserial PRIMARY KEY,
    actor_id    uuid,
    action      text NOT NULL,
    target      text NOT NULL DEFAULT '',
    details     jsonb NOT NULL DEFAULT '{}',
    at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE server_settings (
    key   text PRIMARY KEY,
    value jsonb NOT NULL
);
