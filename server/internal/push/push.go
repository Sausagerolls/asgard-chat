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
	"os"
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
	Alert Kind = iota // message notification, decrypted by the extension
	VoIP              // incoming call, rings CallKit / ConnectionService
	Background        // silent sync nudge
)

type Notification struct {
	Kind     Kind
	ThreadID string         // groups notifications per conversation
	Data     map[string]any // custom payload (conversation id, envelope...)
	Collapse string
}

type Sender struct {
	apns *apnsClient
	fcm  *fcmClient
}

func New(apnsKeyPath, keyID, teamID, topic string, sandbox bool, fcmCredsPath string) (*Sender, error) {
	s := &Sender{}
	if apnsKeyPath != "" {
		c, err := newAPNs(apnsKeyPath, keyID, teamID, topic, sandbox)
		if err != nil {
			return nil, fmt.Errorf("apns: %w", err)
		}
		s.apns = c
	}
	if fcmCredsPath != "" {
		c, err := newFCM(fcmCredsPath)
		if err != nil {
			return nil, fmt.Errorf("fcm: %w", err)
		}
		s.fcm = c
	}
	return s, nil
}

// Send dispatches to the right provider. kind is the device's push_kind.
func (s *Sender) Send(ctx context.Context, provider, token string, n Notification) error {
	if s == nil || token == "" {
		return nil
	}
	switch provider {
	case "apns":
		if s.apns == nil {
			return nil
		}
		return s.apns.send(ctx, token, n)
	case "fcm":
		if s.fcm == nil {
			return nil
		}
		return s.fcm.send(ctx, token, n)
	}
	return nil
}

// ---- APNs ----

type apnsClient struct {
	key    *ecdsa.PrivateKey
	keyID  string
	teamID string
	topic  string
	host   string
	http   *http.Client

	mu      sync.Mutex
	jwt     string
	jwtTime time.Time
}

func newAPNs(path, keyID, teamID, topic string, sandbox bool) (*apnsClient, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("invalid .p8 file")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	ek, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New(".p8 is not an EC key")
	}
	host := "https://api.push.apple.com"
	if sandbox {
		host = "https://api.sandbox.push.apple.com"
	}
	return &apnsClient{key: ek, keyID: keyID, teamID: teamID, topic: topic, host: host,
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

func (c *apnsClient) send(ctx context.Context, token string, n Notification) error {
	aps := map[string]any{}
	topic, pushType, priority := c.topic, "alert", "10"
	switch n.Kind {
	case Alert:
		// The Notification Service Extension replaces this with the decrypted text.
		aps["alert"] = map[string]string{"title": "Asgard Chat", "body": "New message"}
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
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.host+"/3/device/"+token, bytes.NewReader(payload))
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
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	if resp.StatusCode == http.StatusGone || bytes.Contains(msg, []byte("BadDeviceToken")) {
		return ErrUnregistered
	}
	return fmt.Errorf("apns %d: %s", resp.StatusCode, msg)
}

// ---- FCM HTTP v1 ----

type fcmClient struct {
	project string
	src     oauth2.TokenSource
	http    *http.Client
}

func newFCM(path string) (*fcmClient, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var meta struct {
		ProjectID string `json:"project_id"`
	}
	if err := json.Unmarshal(raw, &meta); err != nil {
		return nil, err
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
	if resp.StatusCode == http.StatusNotFound || bytes.Contains(body, []byte("UNREGISTERED")) {
		return ErrUnregistered
	}
	slog.Debug("fcm error", "status", resp.StatusCode)
	return fmt.Errorf("fcm %d: %s", resp.StatusCode, body)
}
