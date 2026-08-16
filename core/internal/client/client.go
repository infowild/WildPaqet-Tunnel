package client

import (
	"context"
	"strings"

	"paqet/internal/conf"
	"paqet/internal/flog"
	"paqet/internal/pkg/iterator"
)

type Client struct {
	cfg       *conf.Conf
	iter      *iterator.Iterator[*timedConn]
	udpPool   *udpPool
	endpoints *endpointPool
}

func New(cfg *conf.Conf) (*Client, error) {
	c := &Client{
		cfg:     cfg,
		iter:    &iterator.Iterator[*timedConn]{},
		udpPool: newUDPPool(),
	}
	if cfg.Transport.Protocol == "tls" && cfg.Transport.TLS != nil {
		c.endpoints = newEndpointPool(cfg.Transport.TLS)
	}
	return c, nil
}

func (c *Client) Start(ctx context.Context) error {
	for i := range c.cfg.Transport.Conn {
		attempt := 0
		var tc *timedConn
		for {
			var err error
			tc, err = newTimedConn(ctx, c.cfg, c.endpoints, i)
			if err == nil {
				break
			}
			flog.Warnf("failed to create connection %d, retrying with backoff: %v", i+1, err)
			if err := waitRetry(ctx, attempt); err != nil {
				return err
			}
			attempt++
		}
		flog.Debugf("client connection %d created successfully", i+1)
		c.iter.Items = append(c.iter.Items, tc)
	}
	context.AfterFunc(ctx, func() {
		for _, tc := range c.iter.Items {
			tc.close()
		}
	})

	go c.ticker(ctx)
	go c.udpPool.ticker(ctx)

	ipv4Addr := "<nil>"
	ipv6Addr := "<nil>"
	if c.cfg.Network.IPv4.Addr != nil {
		ipv4Addr = c.cfg.Network.IPv4.Addr.IP.String()
	}
	if c.cfg.Network.IPv6.Addr != nil {
		ipv6Addr = c.cfg.Network.IPv6.Addr.IP.String()
	}
	flog.Infof("Client started: IPv4:%s IPv6:%s -> %s (%d connections)", ipv4Addr, ipv6Addr, formatServerAddrs(c.cfg.Server), len(c.iter.Items))
	return nil
}

func formatServerAddrs(s conf.Server) string {
	if len(s.Endpoints) > 0 {
		return strings.Join(s.Endpoints, ", ")
	}
	if len(s.Addrs) == 0 {
		if s.Addr != nil {
			return s.Addr.String()
		}
		return "<nil>"
	}
	parts := make([]string, 0, len(s.Addrs))
	for _, a := range s.Addrs {
		if a != nil {
			parts = append(parts, a.String())
		}
	}
	if len(parts) == 0 {
		return "<nil>"
	}
	return strings.Join(parts, ", ")
}
