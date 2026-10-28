package demo

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"testing"
)

// Same vector the Android tests check against CryptoKit.
func TestHistoryKeysMatchApps(t *testing.T) {
	raw, err := os.ReadFile("../../../android/app/src/test/resources/history_vector.json")
	if err != nil {
		t.Skip("vector not found:", err)
	}
	var v map[string]string
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	key, _ := base64.StdEncoding.DecodeString(v["bytes"])
	id, sign := historyKeys(key)
	if got := base64.StdEncoding.EncodeToString(id); got != v["identity_public"] {
		t.Errorf("identity %s, want %s", got, v["identity_public"])
	}
	if got := base64.StdEncoding.EncodeToString(sign); got != v["signing_public"] {
		t.Errorf("signing %s, want %s", got, v["signing_public"])
	}
}
