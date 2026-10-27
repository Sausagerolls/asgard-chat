-- APNs environment of the device's build: development (Xcode), production, or '' if unknown.
ALTER TABLE devices ADD COLUMN push_env text NOT NULL DEFAULT '';
