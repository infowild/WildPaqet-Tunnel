package socket

import (
	"errors"
	"fmt"
	"math/rand"
	"net"
	"os"
	"sync/atomic"
	"time"

	"github.com/gopacket/gopacket/pcap"

	"paqet/internal/conf"
	"paqet/internal/flog"
)

var synRetryDelays = [...]time.Duration{time.Second, 2 * time.Second, 4 * time.Second}

type PacketConn struct {
	cfg           *conf.Network
	sendHandle    *SendHandle
	recvHandle    *RecvHandle
	readDeadline  atomic.Value
	writeDeadline atomic.Value
}

func New(cfg *conf.Network) (*PacketConn, error) {
	if cfg.Port == 0 {
		cfg.Port = 32768 + rand.Intn(32768)
	}

	sendHandle, err := NewSendHandle(cfg)
	if err != nil {
		return nil, fmt.Errorf("failed to create send handle on %s: %v", cfg.Interface.Name, err)
	}

	recvHandle, err := NewRecvHandle(cfg)
	if err != nil {
		sendHandle.Close()
		return nil, fmt.Errorf("failed to create receive handle on %s: %v", cfg.Interface.Name, err)
	}

	conn := &PacketConn{
		cfg:        cfg,
		sendHandle: sendHandle,
		recvHandle: recvHandle,
	}

	return conn, nil
}

func (c *PacketConn) ReadFrom(data []byte) (n int, addr net.Addr, err error) {
	var pkt Packet
	for {
		if d, ok := c.readDeadline.Load().(time.Time); ok && !d.IsZero() && !time.Now().Before(d) {
			return 0, nil, os.ErrDeadlineExceeded
		}

		if err := c.recvHandle.Read(&pkt); err != nil {
			if errors.Is(err, pcap.NextErrorTimeoutExpired) || errors.Is(err, errNoPayload) {
				continue
			}
			return 0, nil, err
		}

		c.sendHandle.noteRecv(&pkt)

		// A peer opening a flow gets a real SYN-ACK, otherwise the port stays
		// silent while carrying a heavy data flow, which is itself a giveaway.
		if pkt.SYN && !pkt.ACK {
			if c.mimic() {
				peer := &net.UDPAddr{IP: pkt.Addr.IP, Port: pkt.Addr.Port}
				if err := c.sendHandle.WriteControl(peer, conf.TCPF{SYN: true, ACK: true}); err != nil {
					flog.Debugf("socket: failed to answer SYN from %s: %v", peer, err)
				}
			}
			continue
		}

		if len(pkt.Payload) == 0 {
			continue
		}
		peer := &net.UDPAddr{IP: pkt.Addr.IP, Port: pkt.Addr.Port}
		if c.mimic() {
			if err := c.sendHandle.WriteControl(peer, conf.TCPF{ACK: true}); err != nil {
				flog.Debugf("socket: failed to ACK data from %s: %v", peer, err)
			}
		}

		return copy(data, pkt.Payload), peer, nil
	}
}

func (c *PacketConn) WriteTo(data []byte, addr net.Addr) (n int, err error) {
	if d, ok := c.writeDeadline.Load().(time.Time); ok && !d.IsZero() && !time.Now().Before(d) {
		return 0, os.ErrDeadlineExceeded
	}

	daddr, ok := addr.(*net.UDPAddr)
	if !ok {
		return 0, net.InvalidAddrError("invalid address")
	}

	err = c.sendHandle.Write(data, daddr)
	if err != nil {
		return 0, err
	}

	return len(data), nil
}

func (c *PacketConn) Close() error {
	if c.sendHandle != nil {
		c.sendHandle.Close()
	}
	if c.recvHandle != nil {
		c.recvHandle.Close()
	}
	return nil
}

func (c *PacketConn) LocalAddr() net.Addr {
	return nil
	// return &net.UDPAddr{
	// 	IP:   append([]byte(nil), c.cfg.PrimaryAddr().IP...),
	// 	Port: c.cfg.PrimaryAddr().Port,
	// 	Zone: c.cfg.PrimaryAddr().Zone,
	// }
}

func (c *PacketConn) SetDeadline(t time.Time) error {
	c.readDeadline.Store(t)
	c.writeDeadline.Store(t)
	return nil
}

func (c *PacketConn) SetReadDeadline(t time.Time) error {
	c.readDeadline.Store(t)
	return nil
}

func (c *PacketConn) SetWriteDeadline(t time.Time) error {
	c.writeDeadline.Store(t)
	return nil
}

func (c *PacketConn) SetDSCP(dscp int) error {
	return nil
}

func (c *PacketConn) SetClientTCPF(addr net.Addr, f []conf.TCPF) {
	c.sendHandle.setClientTCPF(addr, f)
}

func (c *PacketConn) DeleteClientTCPF(addr net.Addr) {
	c.sendHandle.deleteClientTCPF(addr)
}

func (c *PacketConn) mimic() bool {
	return c.cfg.TCP.Handshake == "mimic"
}

// MimicHandshake performs the client half of a three-way handshake before any
// tunnel data is sent. Every SYN retransmission uses the original sequence
// number and failure is closed: tunnel data is never emitted on a flow that did
// not receive a valid SYN-ACK.
func (c *PacketConn) MimicHandshake(addr *net.UDPAddr) error {
	err := runMimicHandshake(
		addr,
		synRetryDelays[:],
		func(f conf.TCPF) error { return c.sendHandle.WriteControl(addr, f) },
		c.recvHandle.Read,
		c.sendHandle.syncSynAck,
	)
	if err != nil {
		c.sendHandle.deleteFlow(addr.IP, uint16(addr.Port))
	}
	return err
}

func runMimicHandshake(addr *net.UDPAddr, delays []time.Duration, write func(conf.TCPF) error, read func(*Packet) error, syncSynAck func(*Packet) bool) error {
	var pkt Packet
	for attempt, wait := range delays {
		if err := write(conf.TCPF{SYN: true}); err != nil {
			return fmt.Errorf("send SYN attempt %d: %w", attempt+1, err)
		}
		deadline := time.Now().Add(wait)
		for time.Now().Before(deadline) {
			if err := read(&pkt); err != nil {
				if errors.Is(err, pcap.NextErrorTimeoutExpired) || errors.Is(err, errNoPayload) {
					continue
				}
				return err
			}

			if !pkt.SYN || !pkt.ACK || pkt.Addr.Port != addr.Port || !pkt.Addr.IP.Equal(addr.IP) {
				continue
			}

			if !syncSynAck(&pkt) {
				continue
			}
			return write(conf.TCPF{ACK: true})
		}
	}

	return fmt.Errorf("handshake with %s failed after %d SYN attempts", addr, len(delays))
}
