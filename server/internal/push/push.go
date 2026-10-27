// Package push delivers APNs (iOS/macOS/watchOS) and FCM (Android) pushes.
//
// Payloads never contain plaintext: at most the encrypted envelope addressed
// to the receiving device, which only that device can decrypt.
package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

// ErrUnregistered means the token is dead and should be removed.
var ErrUnregistered = errors.New("push: token unregistered")

type Kind int

const (
	Alert      Kind = iota // message notification, decrypted by the extension
	VoIP                   // incoming call, rings CallKit / ConnectionService
	Background             // silent sync nudge
)

type Notification struct {
	Kind     Kind
	ThreadID string         // groups notifications per conversation
	Data     map[string]any // custom payload (conversation id, envelope...)
	Collapse string
	Title    string // optional plain alert, only for server notices like test pushes
	Body     string
}

// Sender holds the active provider credentials. They can be replaced at
// runtime when an admin uploads new keys.
type Sender struct {
	mu    sync.RWMutex
	apns  *apnsClient
	fcm   *fcmClient
	relay *RelayClient
}

// ConfigureRelay routes devices that registered relay handles through the push relay.
func (s *Sender) ConfigureRelay(c *RelayClient) { s.mu.Lock(); s.relay = c; s.mu.Unlock() }

// Relay returns the configured relay client, if any.
func (s *Sender) Relay() *RelayClient {
	if s == nil {
		return nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.relay
}

func New() *Sender { return &Sender{} }

// ConfigureAPNs installs an APNs auth key (.p8 contents).
func (s *Sender) ConfigureAPNs(keyPEM []byte, keyID, teamID, topic string) error {
	c, err := newAPNs(keyPEM, keyID, teamID, topic)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.apns = c
	s.mu.Unlock()
	return nil
}

// ConfigureFCM installs a Firebase service-account JSON.
func (s *Sender) ConfigureFCM(credentials []byte) error {
	c, err := newFCM(credentials)
	if err != nil {
		return err
	}
	s.mu.Lock()
	s.fcm = c
	s.mu.Unlock()
	return nil
}

func (s *Sender) DisableAPNs() { s.mu.Lock(); s.apns = nil; s.mu.Unlock() }
func (s *Sender) DisableFCM()  { s.mu.Lock(); s.fcm = nil; s.mu.Unlock() }

// Enabled reports which providers are configured.
func (s *Sender) Enabled() (apns, fcm bool) {
	if s == nil {
		return false, false
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.apns != nil, s.fcm != nil
}

func (s *Sender) Any() bool { a, f := s.Enabled(); return a || f || s.Relay() != nil }

// Send dispatches to the right provider. provider is the device's push_kind;
// env is "development" for debug builds, "production" or "" (unknown).
func (s *Sender) Send(ctx context.Context, provider, token, env string, n Notification) error {
	if s == nil || token == "" {
		return nil
	}
	s.mu.RLock()
	a, f, r := s.apns, s.fcm, s.relay
	s.mu.RUnlock()
	switch provider {
	case "relay":
		if r == nil {
			return nil
		}
		return r.send(ctx, token, n)
	case "apns":
		if a == nil {
			return nil
		}
		return a.send(ctx, token, env, n)
	case "fcm":
		if f == nil {
			return nil
		}
		return f.send(ctx, token, n)
	}
	return nil
}

// VerifyAPNs asks Apple to accept the key without delivering anything: a
// push to an impossible token is rejected as BadDeviceToken only once the
// key, Key ID and Team ID have been accepted.
func VerifyAPNs(ctx context.Context, keyPEM []byte, keyID, teamID, topic string) error {
	c, err := newAPNs(keyPEM, keyID, teamID, topic)
	if err != nil {
		return err
	}
	err = c.post(ctx, productionHost, strings.Repeat("0", 64), Notification{Kind: Background})
	switch {
	case errors.Is(err, ErrUnregistered):
		return nil
	case err == nil:
		return nil
	}
	var ae *apnsError
	if errors.As(err, &ae) {
		switch ae.Reason {
		case "InvalidProviderToken":
			return errors.New("Apple rejected the key. Check the Key ID and Team ID match this .p8 file.")
		case "TopicDisallowed", "BadTopic":
			return fmt.Errorf("this key's team can't send to %q. Use a key from the team that owns the app's bundle ID", topic)
		case "ExpiredProviderToken", "TooManyProviderTokenUpdates":
			return errors.New("Apple rejected the key's token. Check the Mac or server clock is correct.")
		}
	}
	return err
}

// VerifyFCM checks the service account can obtain a Firebase Messaging token.
func VerifyFCM(ctx context.Context, credentials []byte) (projectID string, err error) {
	c, err := newFCM(credentials)
	if err != nil {
		return "", err
	}
	if _, err := c.src.Token(); err != nil {
		return "", fmt.Errorf("Google rejected the service account: %w", err)
	}
	return c.project, nil
}

// ---- APNs ----

const (
	productionHost = "https://api.push.apple.com"
	sandboxHost    = "https://api.sandbox.push.apple.com"
)

type apnsClient struct {
	key    *ecdsa.PrivateKey
	keyID  string
	teamID string
	topic  string
	http   *http.Client

	mu      sync.Mutex
	jwt     string
	jwtTime time.Time
}

type apnsError struct {
	Status int
	Reason string
}

func (e *apnsError) Error() string { return fmt.Sprintf("apns %d: %s", e.Status, e.Reason) }

func newAPNs(raw []byte, keyID, teamID, topic string) (*apnsClient, error) {
	keyID, teamID, topic = strings.TrimSpace(keyID), strings.TrimSpace(teamID), strings.TrimSpace(topic)
	if len(keyID) != 10 || len(teamID) != 10 {
		return nil, errors.New("Key ID and Team ID are both 10 characters (see developer.apple.com › Keys)")
	}
	if topic == "" {
		return nil, errors.New("the app's bundle ID is required")
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("that isn't a .p8 key file")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("the .p8 file couldn't be read")
	}
	ek, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New(".p8 is not an APNs (EC) key")
	}
	return &apnsClient{key: ek, keyID: keyID, teamID: teamID, topic: topic,
		http: &http.Client{Timeout: 15 * time.Second}}, nil
}

func (c *apnsClient) bearer() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.jwt != "" && time.Since(c.jwtTime) < 45*time.Minute {
		return c.jwt, nil
	}
	t := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{"iss": c.teamID, "iat": time.Now().Unix()})
	t.Header["kid"] = c.keyID
	s, err := t.SignedString(c.key)
	if err != nil {
		return "", err
	}
	c.jwt, c.jwtTime = s, time.Now()
	return s, nil
}

// send picks the APNs environment from the device's build. When it is
// unknown, production is tried first and then the sandbox.
func (c *apnsClient) send(ctx context.Context, token, env string, n Notification) error {
	if env == "development" {
		return c.post(ctx, sandboxHost, token, n)
	}
	err := c.post(ctx, productionHost, token, n)
	if env == "" && errors.Is(err, ErrUnregistered) {
		return c.post(ctx, sandboxHost, token, n)
	}
	return err
}

func (c *apnsClient) post(ctx context.Context, host, token string, n Notification) error {
	aps := map[string]any{}
	topic, pushType, priority := c.topic, "alert", "10"
	switch n.Kind {
	case Alert:
		// The Notification Service Extension replaces this with the decrypted text.
		title, text := "Asgard Chat", "New message"
		if n.Body != "" {
			title, text = n.Title, n.Body
		}
		aps["alert"] = map[string]string{"title": title, "body": text}
		aps["mutable-content"] = 1
		aps["sound"] = "default"
		if n.ThreadID != "" {
			aps["thread-id"] = n.ThreadID
		}
	case VoIP:
		topic, pushType = c.topic+".voip", "voip"
	case Background:
		aps["content-available"] = 1
		pushType, priority = "background", "5"
	}
	body := map[string]any{"aps": aps}
	for k, v := range n.Data {
		body[k] = v
	}
	payload, _ := json.Marshal(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+token, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	b, err := c.bearer()
	if err != nil {
		return err
	}
	req.Header.Set("authorization", "bearer "+b)
	req.Header.Set("apns-topic", topic)
	req.Header.Set("apns-push-type", pushType)
	req.Header.Set("apns-priority", priority)
	if n.Collapse != "" {
		req.Header.Set("apns-collapse-id", n.Collapse)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		return nil
	}
	var out struct {
		Reason string `json:"reason"`
	}
	json.NewDecoder(io.LimitReader(resp.Body, 1024)).Decode(&out)
	if resp.StatusCode == http.StatusGone || out.Reason == "BadDeviceToken" || out.Reason == "Unregistered" {
		return ErrUnregistered
	}
	return &apnsError{Status: resp.StatusCode, Reason: out.Reason}
}

// ---- FCM HTTP v1 ----

type fcmClient struct {
	project string
	src     oauth2.TokenSource
	http    *http.Client
}

func newFCM(raw []byte) (*fcmClient, error) {
	var meta struct {
		ProjectID string `json:"project_id"`
		Type      string `json:"type"`
	}
	if err := json.Unmarshal(raw, &meta); err != nil || meta.Type != "service_account" || meta.ProjectID == "" {
		return nil, errors.New("that isn't a Firebase service-account JSON file")
	}
	creds, err := google.CredentialsFromJSONWithType(context.Background(), raw, google.ServiceAccount, "https://www.googleapis.com/auth/firebase.messaging")
	if err != nil {
		return nil, err
	}
	return &fcmClient{project: meta.ProjectID, src: creds.TokenSource, http: &http.Client{Timeout: 15 * time.Second}}, nil
}

func (c *fcmClient) send(ctx context.Context, token string, n Notification) error {
	// Data-only messages so the app always decrypts and renders itself.
	data := map[string]string{}
	for k, v := range n.Data {
		switch vv := v.(type) {
		case string:
			data[k] = vv
		default:
			b, _ := json.Marshal(vv)
			data[k] = string(b)
		}
	}
	switch n.Kind {
	case VoIP:
		data["kind"] = "call"
	case Background:
		data["kind"] = "sync"
	default:
		data["kind"] = "message"
	}
	msg := map[string]any{"message": map[string]any{
		"token":   token,
		"data":    data,
		"android": map[string]any{"priority": "high", "collapse_key": n.Collapse},
	}}
	payload, _ := json.Marshal(msg)
	tok, err := c.src.Token()
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		"https://fcm.googleapis.com/v1/projects/"+c.project+"/messages:send", bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+tok.AccessToken)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		return nil
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	// 404/UNREGISTERED: app uninstalled. 400 "not a valid FCM registration token": token never existed.
	if resp.StatusCode == http.StatusNotFound || bytes.Contains(body, []byte("UNREGISTERED")) ||
		(resp.StatusCode == http.StatusBadRequest && bytes.Contains(body, []byte("registration token"))) {
		return ErrUnregistered
	}
	slog.Debug("fcm error", "status", resp.StatusCode)
	return fmt.Errorf("fcm %d: %s", resp.StatusCode, body)
}
