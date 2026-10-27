package auth

import "testing"

func TestPasswordRoundTrip(t *testing.T) {
	h, err := HashPassword("correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	ok, err := VerifyPassword("correct horse battery staple", h)
	if err != nil || !ok {
		t.Fatalf("expected match, got ok=%v err=%v", ok, err)
	}
	ok, _ = VerifyPassword("wrong", h)
	if ok {
		t.Fatal("wrong password matched")
	}
}

func TestRandomCode(t *testing.T) {
	c := RandomCode(3)
	if len(c) != 14 || c[4] != '-' || c[9] != '-' {
		t.Fatalf("unexpected code %q", c)
	}
}
