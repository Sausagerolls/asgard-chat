package e2ee

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/crypto/curve25519"
)

// Cross-implementation vectors shared with ios/Packages/AsgardKit tests.
//
//	ASGARD_WRITE_VECTOR=1 go test ./internal/e2ee -run Vector   # regenerate go_vector.json
const fixtures = "../../../ios/Packages/AsgardKit/Tests/AsgardKitTests/Fixtures"

type vector struct {
	RecipientIdentityPrivate string `json:"recipient_identity_private"`
	SenderSigningSeed        string `json:"sender_signing_seed"`
	SenderSigningPublic      string `json:"sender_signing_public"`
	RecipientIdentityPublic  string `json:"recipient_identity_public"`
	ConversationID           string `json:"conversation_id"`
	SenderDeviceID           string `json:"sender_device_id"`
	ClientID                 string `json:"client_id"`
	Plaintext                string `json:"plaintext"`
	Ciphertext               string `json:"ciphertext"`
	Signature                string `json:"signature"`
	WrappedKey               string `json:"wrapped_key"`
}

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }
func unb64(t *testing.T, s string) []byte {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestWriteGoVector(t *testing.T) {
	if os.Getenv("ASGARD_WRITE_VECTOR") == "" {
		t.Skip("set ASGARD_WRITE_VECTOR=1 to regenerate")
	}
	var recipPriv [32]byte
	for i := range recipPriv {
		recipPriv[i] = byte(i + 1)
	}
	recipPub, _ := curve25519.X25519(recipPriv[:], curve25519.Basepoint)
	seed := make([]byte, 32)
	for i := range seed {
		seed[i] = byte(100 + i)
	}
	signer := ed25519.NewKeyFromSeed(seed)
	v := vector{
		RecipientIdentityPrivate: b64(recipPriv[:]), RecipientIdentityPublic: b64(recipPub),
		SenderSigningSeed: b64(seed), SenderSigningPublic: b64(signer.Public().(ed25519.PublicKey)),
		ConversationID: "6f1f5a4e-2b1c-4c8e-9a51-0c9b1b8f7a10", SenderDeviceID: "0b7e2d3c-11aa-4f00-8c2d-5e6f7a8b9c0d",
		ClientID: "c1a2b3c4-d5e6-4f70-8a9b-0c1d2e3f4a5b", Plaintext: `{"v":1,"type":"text","text":"Hail from Go"}`,
	}
	aad := AAD(v.ConversationID, v.SenderDeviceID, v.ClientID)
	key, ct, err := Seal([]byte(v.Plaintext), aad)
	if err != nil {
		t.Fatal(err)
	}
	wk, err := Wrap(key, recipPub, v.ClientID)
	if err != nil {
		t.Fatal(err)
	}
	v.Ciphertext, v.Signature, v.WrappedKey = b64(ct), b64(Sign(signer, aad, ct)), b64(wk)
	b, _ := json.MarshalIndent(v, "", "  ")
	if err := os.WriteFile(filepath.Join(fixtures, "go_vector.json"), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestSwiftVector opens an envelope produced by the CryptoKit implementation.
func TestSwiftVector(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join(fixtures, "swift_vector.json"))
	if err != nil {
		t.Skip("no swift_vector.json yet; run the AsgardKit tests with ASGARD_WRITE_VECTOR=1")
	}
	var v vector
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	var priv, pub [32]byte
	copy(priv[:], unb64(t, v.RecipientIdentityPrivate))
	copy(pub[:], unb64(t, v.RecipientIdentityPublic))
	aad := AAD(v.ConversationID, v.SenderDeviceID, v.ClientID)
	ct := unb64(t, v.Ciphertext)
	if !Verify(unb64(t, v.SenderSigningPublic), aad, ct, unb64(t, v.Signature)) {
		t.Fatal("swift signature did not verify")
	}
	key, err := Unwrap(unb64(t, v.WrappedKey), priv, pub, v.ClientID)
	if err != nil {
		t.Fatal("unwrap swift key:", err)
	}
	pt, err := Open(key, ct, aad)
	if err != nil || string(pt) != v.Plaintext {
		t.Fatalf("open swift ciphertext: %v %q", err, pt)
	}
}
