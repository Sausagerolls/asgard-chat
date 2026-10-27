package e2ee

import (
	"bytes"
	"testing"
)

func TestEnvelopeRoundTrip(t *testing.T) {
	sender, _ := GenerateDeviceKeys()
	recipient, _ := GenerateDeviceKeys()
	aad := AAD("conv-1", "dev-sender", "client-1")
	content := []byte(`{"v":1,"type":"text","text":"Hail, Odin"}`)

	key, ct, err := Seal(content, aad)
	if err != nil {
		t.Fatal(err)
	}
	sig := Sign(sender.SigningPrivate, aad, ct)
	wrapped, err := Wrap(key, recipient.IdentityPublic[:], "client-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(wrapped) != WrappedKeySize {
		t.Fatalf("wrapped key is %d bytes, want %d", len(wrapped), WrappedKeySize)
	}

	if !Verify(sender.SigningPublic, aad, ct, sig) {
		t.Fatal("signature did not verify")
	}
	got, err := Unwrap(wrapped, recipient.IdentityPrivate, recipient.IdentityPublic, "client-1")
	if err != nil {
		t.Fatal(err)
	}
	pt, err := Open(got, ct, aad)
	if err != nil || !bytes.Equal(pt, content) {
		t.Fatalf("open failed: %v", err)
	}

	// Tampering is detected.
	if _, err := Open(got, ct, AAD("conv-2", "dev-sender", "client-1")); err == nil {
		t.Fatal("ciphertext opened under wrong conversation")
	}
	if _, err := Unwrap(wrapped, recipient.IdentityPrivate, recipient.IdentityPublic, "client-2"); err == nil {
		t.Fatal("wrapped key opened under wrong client id")
	}
	other, _ := GenerateDeviceKeys()
	if _, err := Unwrap(wrapped, other.IdentityPrivate, other.IdentityPublic, "client-1"); err == nil {
		t.Fatal("wrong device unwrapped key")
	}
	ct[len(ct)-1] ^= 1
	if Verify(sender.SigningPublic, aad, ct, sig) {
		t.Fatal("tampered ciphertext verified")
	}
}
