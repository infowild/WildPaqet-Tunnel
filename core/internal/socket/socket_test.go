package socket

import (
	"errors"
	"net"
	"testing"
	"time"

	"github.com/gopacket/gopacket/pcap"

	"paqet/internal/conf"
)

func TestMimicHandshakeRetriesAndFailsClosed(t *testing.T) {
	peer := &net.UDPAddr{IP: net.IPv4(203, 0, 113, 7), Port: 3000}
	var writes []conf.TCPF
	err := runMimicHandshake(
		peer,
		[]time.Duration{time.Millisecond, time.Millisecond, time.Millisecond},
		func(f conf.TCPF) error { writes = append(writes, f); return nil },
		func(*Packet) error { return pcap.NextErrorTimeoutExpired },
		func(*Packet) bool { return false },
	)
	if err == nil {
		t.Fatal("missing SYN-ACK was accepted")
	}
	if len(writes) != 3 {
		t.Fatalf("writes = %d, want three SYN attempts", len(writes))
	}
	for i, f := range writes {
		if !f.SYN || f.ACK || f.PSH {
			t.Fatalf("write %d was not SYN-only: %+v", i, f)
		}
	}
}

func TestMimicHandshakeAcceptsOnlyMatchingSynAck(t *testing.T) {
	peer := &net.UDPAddr{IP: net.IPv4(203, 0, 113, 7), Port: 3000}
	packets := []Packet{
		{Addr: net.UDPAddr{IP: net.IPv4(198, 51, 100, 1), Port: 3000}, SYN: true, ACK: true},
		{Addr: *peer, SYN: true, ACK: true},
	}
	var writes []conf.TCPF
	err := runMimicHandshake(
		peer,
		[]time.Duration{20 * time.Millisecond},
		func(f conf.TCPF) error { writes = append(writes, f); return nil },
		func(pkt *Packet) error {
			if len(packets) == 0 {
				return errors.New("unexpected extra read")
			}
			*pkt = packets[0]
			packets = packets[1:]
			return nil
		},
		func(*Packet) bool { return true },
	)
	if err != nil {
		t.Fatalf("valid SYN-ACK rejected: %v", err)
	}
	if len(writes) != 2 || !writes[0].SYN || !writes[1].ACK || writes[1].SYN {
		t.Fatalf("wire controls = %+v, want SYN then ACK", writes)
	}
}
