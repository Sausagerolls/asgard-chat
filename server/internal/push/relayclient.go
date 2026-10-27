package push

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/giantmushroom/asgard-chat/server/internal/relay/sign"
)

// RelayClient sends pushes through the Asgard push relay, for devices that
// registered a relay handle instead of a raw APNs/FCM token.
type RelayClient struct {
	URL      string
	ServerID string
	Secret   string
	// OnAuthFailure runs when the relay no longer accepts this server's
	// signature (its master key was rotated), so the server can re-register.
	OnAuthFailure func()
	http          *http.Client
	once          sync.Once
}

func NewRelayClient(url, serverID, secret string) *RelayClient {
	return &RelayClient{URL: strings.TrimRight(url, "/"), ServerID: serverID, Secret: secret, http: &http.Client{Timeout: 20 * time.Second}}
}

// RegisterServer asks a relay for a server id and secret (done once per server).
func RegisterServer(ctx context.Context, url string) (id, secret string, err error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(url, "/")+"/v1/servers", strings.NewReader("{}"))
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: 15 * time.Second}).Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()
	var out struct {
		ServerID string `json:"server_id"`
		Secret   string `json:"secret"`
	}
	if resp.StatusCode != http.StatusCreated || json.NewDecoder(resp.Body).Decode(&out) != nil || out.ServerID == "" {
		return "", "", fmt.Errorf("relay registration failed: %s", resp.Status)
	}
	return out.ServerID, out.Secret, nil
}

func (c *RelayClient) send(ctx context.Context, handle string, n Notification) error {
	kind := "alert"
	switch n.Kind {
	case VoIP:
		kind = "voip"
	case Background:
		kind = "background"
	}
	body, _ := json.Marshal(map[string]any{"handle": handle, "kind": kind, "thread_id": n.ThreadID, "collapse": n.Collapse,
		"title": n.Title, "body": n.Body, "data": n.Data})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.URL+"/v1/push", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	for k, v := range sign.Headers(c.ServerID, c.Secret, body, time.Now()) {
		req.Header.Set(k, v)
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusNoContent, http.StatusOK:
		return nil
	case http.StatusGone:
		return ErrUnregistered
	case http.StatusUnauthorized:
		if c.OnAuthFailure != nil {
			c.once.Do(func() { go c.OnAuthFailure() })
		}
	}
	msg, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
	return errors.New("relay " + resp.Status + ": " + string(msg))
}
