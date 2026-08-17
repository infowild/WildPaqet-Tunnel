package client

import (
	"context"
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
	tc := c.iter.Next()
	return tc.ensureConn(ctx)
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
		return strm, nil
	}
}
