package forward

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"sync"
	"time"

	"paqet/internal/client"
	"paqet/internal/flog"
	"paqet/internal/tnet"
)

type Forward struct {
	dialTCP        func(context.Context, string) (tnet.Strm, error)
	client         *client.Client
	pending        chan struct{}
	connectTimeout time.Duration
	listenAddr     string
	targetAddr     string

	udpMu   sync.RWMutex
	udpPool map[netip.AddrPort]*udpSess
}

func New(client *client.Client, listenAddr, targetAddr string) (*Forward, error) {
	return &Forward{
		client:         client,
		dialTCP:        client.TCP,
		pending:        make(chan struct{}, 256),
		connectTimeout: 15 * time.Second,
		listenAddr:     listenAddr,
		targetAddr:     targetAddr,
		udpPool:        make(map[netip.AddrPort]*udpSess),
	}, nil
}

func (f *Forward) Start(ctx context.Context, protocol string) error {
	flog.Debugf("starting %s forwarder: %s -> %s", protocol, f.listenAddr, f.targetAddr)
	switch protocol {
	case "tcp":
		return f.startTCP(ctx)
	case "udp":
		return f.startUDP(ctx)
	default:
		flog.Errorf("unsupported protocol: %s", protocol)
		return fmt.Errorf("unsupported protocol: %s", protocol)
	}
}

func (f *Forward) startTCP(ctx context.Context) error {
	listener, err := net.Listen("tcp", f.listenAddr)
	if err != nil {
		flog.Errorf("failed to bind TCP socket on %s: %v", f.listenAddr, err)
		return err
	}

	go f.serveTCP(ctx, listener)
	context.AfterFunc(ctx, func() { listener.Close() })

	return nil
}

func (f *Forward) startUDP(ctx context.Context) error {
	laddr, err := net.ResolveUDPAddr("udp", f.listenAddr)
	if err != nil {
		flog.Errorf("failed to resolve UDP listen address '%s': %v", f.listenAddr, err)
		return err
	}
	conn, err := net.ListenUDP("udp", laddr)
	if err != nil {
		flog.Errorf("failed to bind UDP socket on %s: %v", laddr, err)
		return err
	}

	go f.serveUDP(ctx, conn)
	context.AfterFunc(ctx, func() { conn.Close() })

	return nil
}

// SetConnectLimits must be called before Start. Active relays do not consume
// pending slots and are not subject to the setup timeout.
func (f *Forward) SetConnectLimits(timeout time.Duration, maximum int) {
	if timeout > 0 {
		f.connectTimeout = timeout
	}
	if maximum > 0 {
		f.pending = make(chan struct{}, maximum)
	}
}
