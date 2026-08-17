package client

import (
	"context"
	"time"

	"paqet/internal/flog"
)

const connectionCheckInterval = 5 * time.Second

func (c *Client) ticker(ctx context.Context) {
	for _, tc := range c.iter.Items {
		go maintainTimedConn(ctx, tc, connectionCheckInterval)
	}
	<-ctx.Done()
}

func maintainTimedConn(ctx context.Context, tc *timedConn, interval time.Duration) {
	timer := time.NewTimer(interval)
	defer timer.Stop()
	attempt := 0
	for {
		select {
		case <-timer.C:
		case <-ctx.Done():
			return
		}

		for tc.isClosed() {
			if _, err := tc.ensureConn(ctx); err == nil {
				flog.Infof("background connection to %s restored", tc.remoteAddr())
				attempt = 0
				break
			} else {
				flog.Warnf("background reconnect failed: %v", err)
			}
			if err := waitRetry(ctx, attempt); err != nil {
				return
			}
			attempt++
		}
		if !tc.isClosed() {
			attempt = 0
		}
		timer.Reset(interval)
	}
}
