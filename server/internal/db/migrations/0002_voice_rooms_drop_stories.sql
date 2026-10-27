-- Stories were removed from Asgard.
DROP TABLE IF EXISTS story_views;
DROP TABLE IF EXISTS story_keys;
DROP TABLE IF EXISTS stories;

-- Bit 11 (formerly reserved for stories) is now "join and speak in the voice
-- room". Grant it to plain members of every existing group, channel and
-- community; per-member overrides are left as their admins set them.
UPDATE conversations SET member_permissions = member_permissions | 2048 WHERE kind <> 'dm';
