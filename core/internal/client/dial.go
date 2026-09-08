package client

import (
	"context"
	"fmt"
	"math/rand"
	"time"

	"paqet/internal/flog"
	"paqet/internal/tnet"
)

const (
	retryBase = time.Second
	retryMax  = 30 * time.Second
)

func retryDelay(attempt int, jitter float64) time.Duration {
	if attempt > 5 {
		attempt = 5
	}
	d := retryBase << attempt
	if d > retryMax {
		d = retryMax
	}
	// Symmetric 20% jitter avoids synchronising many clients after an outage.
	return time.Duration(float64(d) * (0.8 + 0.4*jitter))
}

func waitRetry(ctx context.Context, attempt int) error {
	t := time.NewTimer(retryDelay(attempt, rand.Float64()))
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

func (c *Client) newConn(ctx context.Context) (tnet.Conn, error) {
	if len(c.iter.Items) == 0 {
		return nil, fmt.Errorf("connection pool is empty")
	}
	if c.cfg.Transport.Protocol == "tls" {
		// The supervisor owns the lifetime of shared TLS sessions. A user's
		// setup deadline must never become the parent of an HTTP/2 session.
		for range c.iter.Items {
			tc := c.iter.Next()
			if !tc.mu.TryLock() {
				continue
			}
			conn := tc.conn
			tc.mu.Unlock()
			if conn != nil && !conn.IsClosed() {
				return conn, nil
			}
		}
		return nil, fmt.Errorf("no healthy TLS pool connection")
	}
	return c.iter.Next().ensureConn(ctx)
}

func (c *Client) newStrm(ctx context.Context) (tnet.Strm, error) {
	attempt := 0
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		conn, err := c.newConn(ctx)
		if err != nil {
			flog.Debugf("failed to open conn, retrying: %v", err)
			if err := waitRetry(ctx, attempt); err != nil {
				return nil, err
			}
			attempt++
			continue
		}
		strm, err := conn.OpenStrm()
		if err != nil {
			flog.Debugf("failed to open stream, retrying: %v", err)
			if err := waitRetry(ctx, attempt); err != nil {
				return nil, err
			}
			attempt++
			continue
		}
		if err := ctx.Err(); err != nil {
			_ = strm.Close()
			return nil, err
		}
		return strm, nil
	}
}
