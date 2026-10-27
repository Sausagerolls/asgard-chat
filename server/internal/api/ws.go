package api

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/coder/websocket"
	"github.com/google/uuid"

	"github.com/giantmushroom/asgard-chat/server/internal/realtime"
)

type wsFrame struct {
	Type string          `json:"type"`
	Data json.RawMessage `json:"data"`
}

func (s *Server) websocket(w http.ResponseWriter, r *http.Request) {
	p := me(r)
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Native apps send no Origin; browsers must come from our own host.
		OriginPatterns: []string{hostOf(s.cfg.PublicURL)},
	})
	if err != nil {
		return
	}
	conn.SetReadLimit(64 << 10)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	client := &realtime.Client{UserID: p.UserID, DeviceID: p.DeviceID, Send: make(chan []byte, 256)}
	s.hub.Register(client)
	defer s.hub.Unregister(client)

	hello, _ := json.Marshal(realtime.Event{Type: "hello", Data: map[string]any{"user_id": p.UserID, "device_id": p.DeviceID, "server_time": time.Now().UTC()}})
	client.Send <- hello

	go func() {
		defer cancel()
		ping := time.NewTicker(25 * time.Second)
		defer ping.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case b := <-client.Send:
				if b == nil {
					conn.Close(websocket.StatusPolicyViolation, "device revoked")
					return
				}
				wctx, c := context.WithTimeout(ctx, 10*time.Second)
				err := conn.Write(wctx, websocket.MessageText, b)
				c()
				if err != nil {
					return
				}
			case <-ping.C:
				pctx, c := context.WithTimeout(ctx, 10*time.Second)
				err := conn.Ping(pctx)
				c()
				if err != nil {
					return
				}
			}
		}
	}()

	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			conn.CloseNow()
			return
		}
		var f wsFrame
		if json.Unmarshal(data, &f) != nil {
			continue
		}
		s.handleFrame(ctx, p, client, f)
	}
}

func (s *Server) handleFrame(ctx context.Context, p *principal, c *realtime.Client, f wsFrame) {
	switch f.Type {
	case "ping":
		b, _ := json.Marshal(realtime.Event{Type: "pong", Data: map[string]any{"server_time": time.Now().UTC()}})
		select {
		case c.Send <- b:
		default:
		}
	case "typing":
		var in struct {
			ConversationID uuid.UUID `json:"conversation_id"`
			State          string    `json:"state"` // typing | recording | uploading | stopped
			ThreadRootID   *uuid.UUID `json:"thread_root_id"`
		}
		if json.Unmarshal(f.Data, &in) != nil {
			return
		}
		if _, err := s.membershipOf(ctx, in.ConversationID, p.UserID); err != nil {
			return
		}
		var share bool
		s.db.QueryRow(ctx, `SELECT coalesce((settings->>'typing_indicators')::boolean, true) FROM users WHERE id = $1`, p.UserID).Scan(&share)
		if !share {
			return
		}
		members := s.memberIDs(ctx, in.ConversationID)
		s.hub.ToUsers(members, realtime.Event{Type: "typing", Data: map[string]any{
			"conversation_id": in.ConversationID, "user_id": p.UserID, "state": in.State, "thread_root_id": in.ThreadRootID}}, p.DeviceID)
	case "read":
		var in struct {
			ConversationID uuid.UUID `json:"conversation_id"`
			Seq            int64     `json:"seq"`
		}
		if json.Unmarshal(f.Data, &in) == nil {
			s.applyRead(ctx, p, in.ConversationID, in.Seq)
		}
	case "ack":
		// Delivery acknowledgements let senders show "delivered" ticks.
		var in struct {
			ConversationID uuid.UUID `json:"conversation_id"`
			Seq            int64     `json:"seq"`
		}
		if json.Unmarshal(f.Data, &in) != nil || in.ConversationID == uuid.Nil {
			return
		}
		tag, err := s.db.Exec(ctx, `UPDATE members SET delivered_seq = GREATEST(delivered_seq, $3) WHERE conversation_id = $1 AND user_id = $2 AND delivered_seq < $3`,
			in.ConversationID, p.UserID, in.Seq)
		if err == nil && tag.RowsAffected() > 0 {
			s.hub.ToUsers(s.memberIDs(ctx, in.ConversationID), realtime.Event{Type: "receipt", Data: map[string]any{
				"conversation_id": in.ConversationID, "user_id": p.UserID, "delivered_seq": in.Seq}}, p.DeviceID)
		}
	}
}

func hostOf(url string) string {
	for _, prefix := range []string{"https://", "http://"} {
		if len(url) > len(prefix) && url[:len(prefix)] == prefix {
			return url[len(prefix):]
		}
	}
	return url
}
