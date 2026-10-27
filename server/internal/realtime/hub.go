// Package realtime fans events out to connected WebSocket clients.
//
// Asgard targets a single instance (< 100 users), so the hub is in-process.
// To run several instances, replace Publish with a Postgres LISTEN/NOTIFY or
// Redis fan-out; the Client contract does not change.
package realtime

import (
	"encoding/json"
	"sync"
	"time"

	"github.com/google/uuid"
)

type Event struct {
	Type string `json:"type"`
	Data any    `json:"data"`
}

type Client struct {
	UserID   uuid.UUID
	DeviceID uuid.UUID
	Send     chan []byte
}

type Hub struct {
	mu       sync.RWMutex
	byDevice map[uuid.UUID]map[*Client]struct{}
	byUser   map[uuid.UUID]map[*Client]struct{}
	lastSeen map[uuid.UUID]time.Time
	// OnPresence is called when a user's first device connects or last disconnects.
	OnPresence func(user uuid.UUID, online bool)
}

func NewHub() *Hub {
	return &Hub{
		byDevice: map[uuid.UUID]map[*Client]struct{}{},
		byUser:   map[uuid.UUID]map[*Client]struct{}{},
		lastSeen: map[uuid.UUID]time.Time{},
	}
}

func (h *Hub) Register(c *Client) {
	h.mu.Lock()
	first := len(h.byUser[c.UserID]) == 0
	add(h.byDevice, c.DeviceID, c)
	add(h.byUser, c.UserID, c)
	h.mu.Unlock()
	if first && h.OnPresence != nil {
		h.OnPresence(c.UserID, true)
	}
}

func (h *Hub) Unregister(c *Client) {
	h.mu.Lock()
	remove(h.byDevice, c.DeviceID, c)
	remove(h.byUser, c.UserID, c)
	last := len(h.byUser[c.UserID]) == 0
	if last {
		h.lastSeen[c.UserID] = time.Now()
	}
	h.mu.Unlock()
	if last && h.OnPresence != nil {
		h.OnPresence(c.UserID, false)
	}
}

func (h *Hub) DeviceOnline(id uuid.UUID) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.byDevice[id]) > 0
}

func (h *Hub) UserOnline(id uuid.UUID) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.byUser[id]) > 0
}

// ToDevice sends ev to every connection of one device. Returns false if none.
func (h *Hub) ToDevice(id uuid.UUID, ev Event) bool {
	b, err := json.Marshal(ev)
	if err != nil {
		return false
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for c := range h.byDevice[id] {
		trySend(c, b)
	}
	return len(h.byDevice[id]) > 0
}

// ToUsers sends ev to every connection of the given users, except skipDevice.
func (h *Hub) ToUsers(users []uuid.UUID, ev Event, skipDevice uuid.UUID) {
	b, err := json.Marshal(ev)
	if err != nil {
		return
	}
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, u := range users {
		for c := range h.byUser[u] {
			if c.DeviceID != skipDevice {
				trySend(c, b)
			}
		}
	}
}

// DisconnectDevice closes all sockets of a device (e.g. after revocation).
func (h *Hub) DisconnectDevice(id uuid.UUID) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for c := range h.byDevice[id] {
		trySend(c, nil) // nil frame tells the writer to close
	}
}

func (h *Hub) Stats() (devices, users int) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.byDevice), len(h.byUser)
}

func trySend(c *Client, b []byte) {
	select {
	case c.Send <- b:
	default:
		// Slow consumer: drop. The client catches up via /sync on reconnect.
	}
}

func add(m map[uuid.UUID]map[*Client]struct{}, k uuid.UUID, c *Client) {
	if m[k] == nil {
		m[k] = map[*Client]struct{}{}
	}
	m[k][c] = struct{}{}
}

func remove(m map[uuid.UUID]map[*Client]struct{}, k uuid.UUID, c *Client) {
	delete(m[k], c)
	if len(m[k]) == 0 {
		delete(m, k)
	}
}
