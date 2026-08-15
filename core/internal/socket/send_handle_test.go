package socket

import (
	"net"
	"testing"

	"paqet/internal/conf"
)

func newTestHandle() *SendHandle {
	return &SendHandle{
		srcPort:  40000,
		time:     1000,
		window:   65535,
		trackSeq: true,
		flows:    make(map[uint64]*flowState),
	}
}

func stamp(t *testing.T, h *SendHandle, ip net.IP, port uint16, f conf.TCPF, payloadLen int) (seq, ack uint32) {
	t.Helper()
	e := &encoder{}
	h.buildTCPHeader(e, ip, port, f, payloadLen)
	return e.tcp.Seq, e.tcp.Ack
}

// A client dial must look like a real open: SYN, then the first data segment
// continues one byte after the SYN and acknowledges the server's ISN.
func TestHandshakeSequenceIsContinuous(t *testing.T) {
	h := newTestHandle()
	peer := net.IPv4(203, 0, 113, 7)
	const port = 3000

	synSeq, synAck := stamp(t, h, peer, port, conf.TCPF{SYN: true}, 0)
	if synAck != 0 {
		t.Fatalf("SYN must not acknowledge anything, got ack=%d", synAck)
	}

	// Server answers with its own ISN.
	const serverISN = 900000
	synAckPkt := &Packet{
		Addr: net.UDPAddr{IP: peer, Port: port},
		Seq:  serverISN,
		SYN:  true,
		ACK:  true,
	}
	h.syncSynAck(synAckPkt)

	ackSeq, ackAck := stamp(t, h, peer, port, conf.TCPF{ACK: true}, 0)
	if ackSeq != synSeq+1 {
		t.Errorf("handshake ACK seq = %d, want %d (SYN consumes one octet)", ackSeq, synSeq+1)
	}
	if ackAck != serverISN+1 {
		t.Errorf("handshake ACK ack = %d, want %d", ackAck, serverISN+1)
	}

	// A pure ACK consumes no sequence space, so data starts at the same seq.
	dataSeq, _ := stamp(t, h, peer, port, conf.TCPF{PSH: true, ACK: true}, 120)
	if dataSeq != ackSeq {
		t.Errorf("first data seq = %d, want %d", dataSeq, ackSeq)
	}

	nextSeq, _ := stamp(t, h, peer, port, conf.TCPF{PSH: true, ACK: true}, 80)
	if nextSeq != dataSeq+120 {
		t.Errorf("second data seq = %d, want %d (must advance by payload bytes)", nextSeq, dataSeq+120)
	}
}

func TestAckFollowsReceivedBytes(t *testing.T) {
	h := newTestHandle()
	peer := net.IPv4(203, 0, 113, 7)
	const port = 3000

	h.noteRecv(&Packet{Addr: net.UDPAddr{IP: peer, Port: port}, Seq: 5000, Payload: make([]byte, 100)})
	if _, ack := stamp(t, h, peer, port, conf.TCPF{PSH: true, ACK: true}, 10); ack != 5100 {
		t.Errorf("ack = %d, want 5100", ack)
	}

	h.noteRecv(&Packet{Addr: net.UDPAddr{IP: peer, Port: port}, Seq: 5100, Payload: make([]byte, 40)})
	if _, ack := stamp(t, h, peer, port, conf.TCPF{PSH: true, ACK: true}, 10); ack != 5140 {
		t.Errorf("ack = %d, want 5140", ack)
	}

	// A retransmit of older data must not rewind the ACK.
	h.noteRecv(&Packet{Addr: net.UDPAddr{IP: peer, Port: port}, Seq: 5000, Payload: make([]byte, 100)})
	if _, ack := stamp(t, h, peer, port, conf.TCPF{PSH: true, ACK: true}, 10); ack != 5140 {
		t.Errorf("ack after retransmit = %d, want 5140", ack)
	}

	// A forged segment far in the future must not strand the ACK there.
	h.noteRecv(&Packet{Addr: net.UDPAddr{IP: peer, Port: port}, Seq: 5140 + maxAckAdvance + 1})
	if _, ack := stamp(t, h, peer, port, conf.TCPF{PSH: true, ACK: true}, 10); ack != 5140 {
		t.Errorf("ack after forged jump = %d, want 5140", ack)
	}
}

// The same peer must map to one flow whether its address arrived as a 4-byte
// or 16-byte net.IP, otherwise sending and receiving track separate state.
func TestFlowKeyIgnoresIPWidth(t *testing.T) {
	four := net.IP{198, 51, 100, 9}
	sixteen := net.IPv4(198, 51, 100, 9)
	if len(sixteen) != 16 {
		t.Fatalf("expected a 16-byte IPv4, got %d bytes", len(sixteen))
	}
	if flowKey(four, 3000) != flowKey(sixteen, 3000) {
		t.Error("4-byte and 16-byte forms of one address produced different flow keys")
	}
}

// Legacy peers get the old wire behaviour, so an operator can still fall back.
func TestLegacyPresetKeepsUntrackedSequences(t *testing.T) {
	h := newTestHandle()
	h.trackSeq = false
	peer := net.IPv4(203, 0, 113, 7)

	first, _ := stamp(t, h, peer, 3000, conf.TCPF{PSH: true, ACK: true}, 100)
	second, _ := stamp(t, h, peer, 3000, conf.TCPF{PSH: true, ACK: true}, 100)
	if first == second {
		t.Error("untracked mode should not produce a stable sequence")
	}
	if len(h.flows) != 0 {
		t.Errorf("untracked mode must not allocate flow state, got %d entries", len(h.flows))
	}
}
