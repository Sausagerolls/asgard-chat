// Package storage stores encrypted media blobs, either on the local
// filesystem (default) or in any S3-compatible bucket (Backblaze B2,
// Cloudflare R2, Garage, AWS...).
package storage

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

type Store interface {
	Put(ctx context.Context, key string, r io.Reader, size int64) error
	Get(ctx context.Context, key string) (io.ReadSeekCloser, int64, error)
	Delete(ctx context.Context, key string) error
	Ping(ctx context.Context) error
}

// ---- filesystem ----

type FS struct{ root string }

func NewFS(root string) (*FS, error) {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, fmt.Errorf("media dir: %w", err)
	}
	return &FS{root: root}, nil
}

func (f *FS) path(key string) (string, error) {
	p := filepath.Join(f.root, filepath.FromSlash(key))
	if !strings.HasPrefix(p, filepath.Clean(f.root)+string(filepath.Separator)) {
		return "", errors.New("storage: bad key")
	}
	return p, nil
}

func (f *FS) Put(ctx context.Context, key string, r io.Reader, size int64) error {
	p, err := f.path(key)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(p), ".upload-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	n, err := io.Copy(tmp, r)
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	if n != size {
		return fmt.Errorf("storage: short upload (%d of %d bytes)", n, size)
	}
	return os.Rename(tmp.Name(), p)
}

func (f *FS) Get(ctx context.Context, key string) (io.ReadSeekCloser, int64, error) {
	p, err := f.path(key)
	if err != nil {
		return nil, 0, err
	}
	file, err := os.Open(p)
	if err != nil {
		return nil, 0, err
	}
	st, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, 0, err
	}
	return file, st.Size(), nil
}

func (f *FS) Delete(ctx context.Context, key string) error {
	p, err := f.path(key)
	if err != nil {
		return err
	}
	if err := os.Remove(p); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func (f *FS) Ping(ctx context.Context) error {
	_, err := os.Stat(f.root)
	return err
}

// ---- S3 ----

type S3 struct {
	client *minio.Client
	bucket string
}

func NewS3(ctx context.Context, endpoint, access, secret, bucket, region string, ssl bool) (*S3, error) {
	c, err := minio.New(endpoint, &minio.Options{Creds: credentials.NewStaticV4(access, secret, ""), Secure: ssl, Region: region})
	if err != nil {
		return nil, err
	}
	exists, err := c.BucketExists(ctx, bucket)
	if err != nil {
		return nil, fmt.Errorf("check bucket: %w", err)
	}
	if !exists {
		if err := c.MakeBucket(ctx, bucket, minio.MakeBucketOptions{Region: region}); err != nil {
			return nil, fmt.Errorf("create bucket: %w", err)
		}
	}
	return &S3{client: c, bucket: bucket}, nil
}

func (s *S3) Put(ctx context.Context, key string, r io.Reader, size int64) error {
	_, err := s.client.PutObject(ctx, s.bucket, key, r, size, minio.PutObjectOptions{ContentType: "application/octet-stream"})
	return err
}

func (s *S3) Get(ctx context.Context, key string) (io.ReadSeekCloser, int64, error) {
	obj, err := s.client.GetObject(ctx, s.bucket, key, minio.GetObjectOptions{})
	if err != nil {
		return nil, 0, err
	}
	st, err := obj.Stat()
	if err != nil {
		obj.Close()
		return nil, 0, err
	}
	return obj, st.Size, nil
}

func (s *S3) Delete(ctx context.Context, key string) error {
	return s.client.RemoveObject(ctx, s.bucket, key, minio.RemoveObjectOptions{})
}

func (s *S3) Ping(ctx context.Context) error {
	_, err := s.client.BucketExists(ctx, s.bucket)
	return err
}
