package storage

import (
	"context"
	"io"
	"strings"
	"testing"
)

func TestFSRoundTrip(t *testing.T) {
	ctx := context.Background()
	fs, err := NewFS(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := fs.Put(ctx, "media/ab/abc", strings.NewReader("ciphertext"), 10); err != nil {
		t.Fatal(err)
	}
	r, size, err := fs.Get(ctx, "media/ab/abc")
	if err != nil || size != 10 {
		t.Fatalf("get: %v size=%d", err, size)
	}
	b, _ := io.ReadAll(r)
	r.Close()
	if string(b) != "ciphertext" {
		t.Fatalf("got %q", b)
	}
	if err := fs.Put(ctx, "../escape", strings.NewReader("x"), 1); err == nil {
		t.Fatal("path traversal allowed")
	}
	if err := fs.Put(ctx, "media/short", strings.NewReader("abc"), 10); err == nil {
		t.Fatal("short upload accepted")
	}
	if err := fs.Delete(ctx, "media/ab/abc"); err != nil {
		t.Fatal(err)
	}
}
