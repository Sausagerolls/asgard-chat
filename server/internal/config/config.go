// Package config loads server settings from the environment.
//
// Every secret can be given either directly (ASGARD_FOO) or as a path to a
// file (ASGARD_FOO_FILE), which is how Docker secrets are mounted. Secrets are
// never logged.
package config

import (
	"encoding/base64"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	PublicURL   string // https://chat.example.com
	ListenAddr  string
	DatabaseURL string
	MasterKey   []byte // 32 bytes, encrypts server-held bot keys

	StorageKind string // fs | s3
	MediaDir    string
	S3Endpoint  string
	S3Region    string
	S3AccessKey string
	S3SecretKey string
	S3Bucket    string
	S3UseSSL    bool

	LiveKitURL       string // wss://chat.example.com/livekit (what clients dial)
	LiveKitAPIKey    string
	LiveKitAPISecret string

	APNsKeyPath  string // .p8 auth key
	APNsKeyID    string
	APNsTeamID   string
	APNsTopic    string // bundle id
	FCMCredsPath string // service account json
	PushRelayURL string // push relay for the official apps; "" disables

	BootstrapInvite  string // optional fixed first invite code
	MaxUploadBytes   int64
	SessionTTL       time.Duration
	TrustProxy       bool
	LogRequests      bool
	OpenRegistration bool
}

func Load() (*Config, error) {
	c := &Config{
		PublicURL:        env("ASGARD_PUBLIC_URL", "http://localhost:8080"),
		ListenAddr:       env("ASGARD_LISTEN", ":8080"),
		StorageKind:      env("ASGARD_STORAGE", "fs"),
		MediaDir:         env("ASGARD_MEDIA_DIR", "/data/media"),
		S3Endpoint:       env("ASGARD_S3_ENDPOINT", ""),
		S3Region:         env("ASGARD_S3_REGION", ""),
		S3Bucket:         env("ASGARD_S3_BUCKET", "asgard-media"),
		S3UseSSL:         envBool("ASGARD_S3_SSL", true),
		LiveKitURL:       env("ASGARD_LIVEKIT_URL", ""),
		APNsKeyPath:      env("ASGARD_APNS_KEY_FILE", ""),
		APNsKeyID:        env("ASGARD_APNS_KEY_ID", ""),
		APNsTeamID:       env("ASGARD_APNS_TEAM_ID", ""),
		APNsTopic:        env("ASGARD_APNS_TOPIC", "com.giantmushroom.asgardchat"),
		FCMCredsPath:     env("ASGARD_FCM_CREDENTIALS_FILE", ""),
		PushRelayURL:     relayURL(),
		MaxUploadBytes:   int64(envInt("ASGARD_MAX_UPLOAD_MB", 2048)) << 20,
		SessionTTL:       time.Duration(envInt("ASGARD_SESSION_DAYS", 180)) * 24 * time.Hour,
		TrustProxy:       envBool("ASGARD_TRUST_PROXY", true),
		LogRequests:      envBool("ASGARD_LOG_REQUESTS", false),
		OpenRegistration: envBool("ASGARD_OPEN_REGISTRATION", false),
	}
	var err error
	if c.DatabaseURL, err = secret("ASGARD_DATABASE_URL"); err != nil {
		return nil, err
	}
	if c.S3AccessKey, err = secret("ASGARD_S3_ACCESS_KEY"); err != nil {
		return nil, err
	}
	if c.S3SecretKey, err = secret("ASGARD_S3_SECRET_KEY"); err != nil {
		return nil, err
	}
	if c.LiveKitAPIKey, err = secret("ASGARD_LIVEKIT_API_KEY"); err != nil {
		return nil, err
	}
	if c.LiveKitAPISecret, err = secret("ASGARD_LIVEKIT_API_SECRET"); err != nil {
		return nil, err
	}
	if c.BootstrapInvite, err = secret("ASGARD_BOOTSTRAP_INVITE"); err != nil {
		return nil, err
	}
	mk, err := secret("ASGARD_MASTER_KEY")
	if err != nil {
		return nil, err
	}
	if mk != "" {
		if c.MasterKey, err = base64.StdEncoding.DecodeString(mk); err != nil || len(c.MasterKey) != 32 {
			return nil, fmt.Errorf("ASGARD_MASTER_KEY must be 32 bytes, base64 encoded (openssl rand -base64 32)")
		}
	}
	if c.DatabaseURL == "" {
		return nil, fmt.Errorf("ASGARD_DATABASE_URL (or ASGARD_DATABASE_URL_FILE) is required")
	}
	c.PublicURL = strings.TrimRight(c.PublicURL, "/")
	return c, nil
}

func (c *Config) CallsEnabled() bool {
	return c.LiveKitURL != "" && c.LiveKitAPIKey != "" && c.LiveKitAPISecret != ""
}

func env(k, def string) string {
	if v, ok := os.LookupEnv(k); ok && v != "" {
		return v
	}
	return def
}

func envBool(k string, def bool) bool {
	v, err := strconv.ParseBool(env(k, strconv.FormatBool(def)))
	if err != nil {
		return def
	}
	return v
}

func envInt(k string, def int) int {
	v, err := strconv.Atoi(env(k, strconv.Itoa(def)))
	if err != nil {
		return def
	}
	return v
}

// secret reads K or the file named by K_FILE.
func secret(k string) (string, error) {
	if p := os.Getenv(k + "_FILE"); p != "" {
		b, err := os.ReadFile(p)
		if err != nil {
			return "", fmt.Errorf("reading %s_FILE: %w", k, err)
		}
		return strings.TrimSpace(string(b)), nil
	}
	return os.Getenv(k), nil
}

// DefaultPushRelay serves the official App Store and Play Store builds of the
// apps. Servers register with it automatically; set ASGARD_PUSH_RELAY=off to
// use only your own APNs/FCM keys (for apps you build and sign yourself).
const DefaultPushRelay = "https://push.giantmushroom.studio"

func relayURL() string {
	switch v := os.Getenv("ASGARD_PUSH_RELAY"); v {
	case "":
		return DefaultPushRelay
	case "off", "false", "none":
		return ""
	default:
		return v
	}
}
