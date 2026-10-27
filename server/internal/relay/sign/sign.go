// Package sign holds the request signature shared by the push relay and the
// Asgard servers that call it.
package sign

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"time"
)

// Headers returns X-Asgard-Server/-Timestamp/-Signature for a relay request:
// signature = hex(HMAC-SHA256(secret, timestamp + "." + body)).
func Headers(serverID, secret string, body []byte, now time.Time) map[string]string {
	ts := strconv.FormatInt(now.Unix(), 10)
	return map[string]string{"X-Asgard-Server": serverID, "X-Asgard-Timestamp": ts, "X-Asgard-Signature": hex.EncodeToString(MAC(secret, ts, body))}
}

func MAC(secret, ts string, body []byte) []byte {
	m := hmac.New(sha256.New, []byte(secret))
	m.Write([]byte(ts + "." + string(body)))
	return m.Sum(nil)
}
