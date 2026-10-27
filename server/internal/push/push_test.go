package push

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"testing"
)

func testKey(t *testing.T) []byte {
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	der, err := x509.MarshalPKCS8PrivateKey(k)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
}

func TestConfigureAPNs(t *testing.T) {
	s := New()
	if a, f := s.Enabled(); a || f {
		t.Fatal("new sender should have no providers")
	}
	cases := []struct {
		name               string
		key                []byte
		keyID, team, topic string
	}{
		{"not pem", []byte("hello"), "ABCDE12345", "TEAM123456", "com.example.app"},
		{"short key id", testKey(t), "ABC", "TEAM123456", "com.example.app"},
		{"short team", testKey(t), "ABCDE12345", "T1", "com.example.app"},
		{"no topic", testKey(t), "ABCDE12345", "TEAM123456", ""},
	}
	for _, c := range cases {
		if err := s.ConfigureAPNs(c.key, c.keyID, c.team, c.topic); err == nil {
			t.Errorf("%s: expected error", c.name)
		}
	}
	if err := s.ConfigureAPNs(testKey(t), "ABCDE12345", "TEAM123456", "com.example.app"); err != nil {
		t.Fatal(err)
	}
	if a, _ := s.Enabled(); !a || !s.Any() {
		t.Fatal("apns should be enabled")
	}
	s.DisableAPNs()
	if s.Any() {
		t.Fatal("apns should be disabled")
	}
}

func TestConfigureFCMRejectsNonServiceAccount(t *testing.T) {
	if err := New().ConfigureFCM([]byte(`{"type":"authorized_user"}`)); err == nil {
		t.Fatal("expected error")
	}
}

func TestNilSender(t *testing.T) {
	var s *Sender
	if s.Any() {
		t.Fatal("nil sender has no providers")
	}
	if err := s.Send(t.Context(), "apns", "tok", "", Notification{}); err != nil {
		t.Fatal(err)
	}
}
