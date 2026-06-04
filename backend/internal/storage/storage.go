// Package storage wraps an S3-compatible object store (Backblaze B2) for
// SUPPORT-CHAT attachments. The backend never proxies file bytes: it issues
// short-lived presigned PUT URLs the client uploads to directly, and presigned
// GET URLs to serve them back. Keys live under the `support/` prefix of the
// shared bucket (madfrog-vpn-backups) — there is no separate attachment bucket.
package storage

import (
	"context"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

// Client wraps a minio S3 client bound to a single bucket.
type Client struct {
	mc     *minio.Client
	bucket string
}

// New builds a B2 (S3-compatible) client. endpoint is the host only (no
// scheme), e.g. "s3.us-east-005.backblazeb2.com"; TLS is always on.
func New(endpoint, region, keyID, appKey, bucket string) (*Client, error) {
	mc, err := minio.New(endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(keyID, appKey, ""),
		Secure: true,
		Region: region,
	})
	if err != nil {
		return nil, err
	}
	return &Client{mc: mc, bucket: bucket}, nil
}

// PresignPut returns a presigned PUT URL valid for ttl. Note: PresignedPutObject
// does NOT bind the Content-Type — the client sends its own Content-Type header
// on the upload, which is sufficient for our purposes (we record the declared
// MIME separately in the DB).
func (c *Client) PresignPut(ctx context.Context, key, contentType string, ttl time.Duration) (string, error) {
	u, err := c.mc.PresignedPutObject(ctx, c.bucket, key, ttl)
	if err != nil {
		return "", err
	}
	return u.String(), nil
}

// PresignGet returns a presigned GET URL valid for ttl.
func (c *Client) PresignGet(ctx context.Context, key string, ttl time.Duration) (string, error) {
	u, err := c.mc.PresignedGetObject(ctx, c.bucket, key, ttl, nil)
	if err != nil {
		return "", err
	}
	return u.String(), nil
}

// Delete best-effort removes each key. It does not stop on the first error so a
// single missing object can't strand the rest (retention cleanup); the last
// error encountered is returned for the caller to log.
func (c *Client) Delete(ctx context.Context, keys []string) error {
	var lastErr error
	for _, k := range keys {
		if k == "" {
			continue
		}
		if err := c.mc.RemoveObject(ctx, c.bucket, k, minio.RemoveObjectOptions{}); err != nil {
			lastErr = err
		}
	}
	return lastErr
}
