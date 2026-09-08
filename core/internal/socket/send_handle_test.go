package socket

import (
	"encoding/binary"
	"net"
	"testing"
	"time"

	"github.com/gopacket/gopacket"
	"github.com/gopacket/gopacket/layers"
	"paqet/internal/conf"
)

func newTestHandle() *SendHandle {
	started := time.Unix(100, 0)
	return &SendHandle{
		srcPort:   40000,
		time:      1000,
		tsStarted: started,
		now:       func() time.Time { return started },
		window:    65535,
		trackSeq:  true,
		flows:     make(map[uint64]*flowState),
	}
}

func stamp(t *testing.T, h *SendHandle, ip net.IP, port uint16, f conf.TCPF, payload []byte) (seq, ack uint32) {
	t.Helper()
	e := &encoder{}
	h.buildTCPHeader(e, ip, port, f, payload)
	return e.tcp.Seq, e.tcp.Ack
}

// A client dial must look like a real open: SYN, then the first data segment
// continues one byte after the SYN and acknowledges the server's ISN.
func TestHandshakeSequenceIsContinuous(t *testing.T) {
	h := newTestHandle()
	peer := net.IPv4(203, 0, 113, 7)
	const port = 3000

	synSeq, synAck := stamp(t, h, peer, port, conf.TCPF{SYN: true}, nil)
	if synAck != 0 {
		t.Fatalf("SYN must not acknowledge anything, got ack=%d", synAck)
	}

	// Server answers with its own ISN and acknowledges our SYN.
	const serverISN = 900000
	synAckPkt := &Packet{
		Addr: net.UDPAddr{IP: peer, Port: port},
		Seq:  serverISN,
		Ack:  synSeq + 1,
		SYN:  true,
		ACK:  true,
	}
	if !h.syncSynAck(synAckPkt) {
		t.Fatal("valid SYN-ACK was rejected")
	}

	ackSeq, ackAck := stamp(t, h, peer, port, conf.TCPF{ACK: true}, nil)
	if ackSeq != synSeq+1 {
		t.Errorf("handshake ACK seq = %d, want %d (SYN consumes one octet)", ackSeq, synSeq+1)
	}
	if ackAck != serverISN+1 {
		t.Errorf("handshake ACK ack = %d, want %d", ackAck, serverISN+1)
	}

	// A pure ACK consumes no sequence space, so data starts at the same seq.
	dataSeq, _ := stamp(t, h, peer, port, conf.TCPF{PSH: true, ACK: true}, make([]byte, 120))
	if dataSeq != ackSeq {
		t.Errorf("first data seq = %d, want %d", dataSeq, ackSeq)
	}

	nextSeq, _ := stamp(t, h, peer, port, conf.TCPF{PSH: true, ACK: true}, make([]byte, 80))
	if nextSeq != dataSeq+120 {
		t.Errorf("second data seq = %d, want %d (must advance by payload bytes)", nextSeq, dataSeq+120)
	}
}

// A SYN-ACK that does not acknowledge the SYN we sent must be rejected, so a
// spoofed or stale segment cannot desync the flow.
func TestSynAckRejectsWrongAck(t *testing.T) {
	h := newTestHandle()
	peer := net.IPv4(203, 0, 113, 7)
	const port = 3000

	synSeq, _ := stamp(t, h, peer, port, conf.TCPF{SYN: true}, nil)

	bad := &Packet{Addr: net.UDPAddr{IP: peer, Port: port}, Seq: 111, Ack: synSeq + 999, SYN: true, ACK: true}
	if h.syncSynAck(bad) {
		t.Fatal("SYN-ACK with wrong ack was accepted")
	}

	good := &Packet{Addr: net.UDPAddr{IP: peer, Port: port}, Seq: 111, Ack: synSeq + 1, SYN: true, ACK: true}
	if !h.syncSynAck(good) {
		t.Fatal("SYN-ACK with correct ack was rejected")
	}
	if _, ack := stamp(t, h, peer, port, conf.TCPF{ACK: true}, nil); ack != 112 {
		t.Errorf("ack after valid SYN-ACK = %d, want 112", ack)
	}
}

func TestAckFollowsReceivedBytes(t *testing.T) {
	h := newTestHandle()
	peer := net.IPv4(203, 0, 113, 7)
	const port = 3000

	h.noteRecv(&Packet{Addr: net.UDPAddr{IP: peer, Port: port}, Seq: 5000, Payload: make([]byte, 100)})
	if _, ack := stamp(t, h, peer, port, conf.TCPF{PSH: true, ACK: true}, []byte("first-data")); ack != 5100 {
		t.Errorf("ack = %d, want 5100", ack)
	}

	h.noteRecv(&Packet{Addr: net.UDPAddr{IP: peer, Port: port}, Seq: 5100, Payload: make([]byte, 40)})
	if _, ack := stamp(t, h, peer, port, conf.TCPF{PSH: true, ACK: true}, []byte("second-data")); ack != 5140 {
		t.Errorf("ack = %d, want 5140", ack)
	}

	// A retransmit of older data must not rewind the ACK.
	h.noteRecv(&Packet{Addr: net.UDPAddr{IP: peer, Port: port}, Seq: 5000, Payload: make([]byte, 100)})
	if _, ack := stamp(t, h, peer, port, conf.TCPF{PSH: true, ACK: true}, []byte("third-data")); ack != 5140 {
		t.Errorf("ack after retransmit = %d, want 5140", ack)
	}

	// A forged segment far in the future must not strand the ACK there.
	h.noteRecv(&Packet{Addr: net.UDPAddr{IP: peer, Port: port}, Seq: 5140 + maxAckAdvance + 1})
	if _, ack := stamp(t, h, peer, port, conf.TCPF{PSH: true, ACK: true}, []byte("fourth-data")); ack != 5140 {
		t.Errorf("ack after forged jump = %d, want 5140", ack)
	}
}

func TestAckDoesNotAdvanceAcrossOutOfOrderGap(t *testing.T) {
	h := newTestHandle()
	peer := net.IPv4(203, 0, 113, 7)
	const port = 3000

	h.noteRecv(&Packet{Addr: net.UDPAddr{IP: peer, Port: port}, Seq: 1000, SYN: true})
	h.noteRecv(&Packet{Addr: net.UDPAddr{IP: peer, Port: port}, Seq: 1101, Payload: make([]byte, 50)})
	if _, ack := stamp(t, h, peer, port, conf.TCPF{ACK: true}, nil); ack != 1001 {
		t.Fatalf("ACK crossed a receive gap: got %d, want 1001", ack)
	}

	h.noteRecv(&Packet{Addr: net.UDPAddr{IP: peer, Port: port}, Seq: 1001, Payload: make([]byte, 100)})
	if _, ack := stamp(t, h, peer, port, conf.TCPF{ACK: true}, nil); ack != 1151 {
		t.Fatalf("ACK did not consume buffered range: got %d, want 1151", ack)
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

	first, _ := stamp(t, h, peer, 3000, conf.TCPF{PSH: true, ACK: true}, make([]byte, 100))
	second, _ := stamp(t, h, peer, 3000, conf.TCPF{PSH: true, ACK: true}, make([]byte, 100))
	if first == second {
		t.Error("untracked mode should not produce a stable sequence")
	}
	if len(h.flows) != 0 {
		t.Errorf("untracked mode must not allocate flow state, got %d entries", len(h.flows))
	}
}

func timestampOption(t *testing.T, e *encoder) uint32 {
	t.Helper()
	for _, opt := range e.tcp.Options {
		if opt.OptionType == layers.TCPOptionKindTimestamps && len(opt.OptionData) == 8 {
			return binary.BigEndian.Uint32(opt.OptionData[:4])
		}
	}
	t.Fatal("TCP timestamp option missing")
	return 0
}

func TestTimestampUsesMonotonicElapsedTime(t *testing.T) {
	h := newTestHandle()
	peer := net.IPv4(203, 0, 113, 7)
	now := h.tsStarted
	h.now = func() time.Time { return now }

	e := &encoder{}
	h.buildTCPHeader(e, peer, 3000, conf.TCPF{SYN: true}, nil)
	first := timestampOption(t, e)
	for range 100 {
		h.buildTCPHeader(&encoder{}, peer, 3000, conf.TCPF{ACK: true}, nil)
	}
	if got := timestampOption(t, e); got != first {
		t.Fatalf("timestamp changed without elapsed time: got %d want %d", got, first)
	}

	now = now.Add(2750 * time.Millisecond)
	e = &encoder{}
	h.buildTCPHeader(e, peer, 3000, conf.TCPF{ACK: true}, nil)
	if got, want := timestampOption(t, e), first+2750; got != want {
		t.Fatalf("timestamp after idle = %d, want %d", got, want)
	}
}

func TestRetransmissionReusesOuterSequence(t *testing.T) {
	h := newTestHandle()
	peer := net.IPv4(203, 0, 113, 7)
	payload := []byte("encrypted-kcp-datagram-with-stable-header")

	first, _ := stamp(t, h, peer, 3000, conf.TCPF{PSH: true, ACK: true}, payload)
	e := &encoder{}
	h.buildTCPHeaderAtSeq(e, peer, 3000, conf.TCPF{PSH: true, ACK: true}, payload, &first)
	if e.tcp.Seq != first {
		t.Fatalf("retransmission seq = %d, want original %d", e.tcp.Seq, first)
	}
	next, _ := stamp(t, h, peer, 3000, conf.TCPF{PSH: true, ACK: true}, []byte("next encrypted datagram"))
	if want := first + uint32(len(payload)); next != want {
		t.Fatalf("next seq = %d, want %d", next, want)
	}
}

func wireTCP(t *testing.T, h *SendHandle, peer net.IP, f conf.TCPF, payload []byte) *layers.TCP {
	return wireTCPAtSeq(t, h, peer, f, payload, nil)
}

func wireTCPAtSeq(t *testing.T, h *SendHandle, peer net.IP, f conf.TCPF, payload []byte, seqOverride *uint32) *layers.TCP {
	t.Helper()
	e := &encoder{buf: gopacket.NewSerializeBuffer()}
	h.srcIPv4 = net.IPv4(192, 0, 2, 10)
	h.buildTCPHeaderAtSeq(e, peer, 3000, f, payload, seqOverride)
	h.buildIPv4Header(e, peer)
	e.tcp.SetNetworkLayerForChecksum(&e.ip4)
	if err := gopacket.SerializeLayers(e.buf, gopacket.SerializeOptions{FixLengths: true, ComputeChecksums: true}, &e.ip4, &e.tcp, gopacket.Payload(payload)); err != nil {
		t.Fatalf("serialize packet: %v", err)
	}
	pkt := gopacket.NewPacket(e.buf.Bytes(), layers.LayerTypeIPv4, gopacket.Default)
	if errLayer := pkt.ErrorLayer(); errLayer != nil {
		t.Fatalf("decode packet: %v", errLayer.Error())
	}
	tcpLayer := pkt.Layer(layers.LayerTypeTCP)
	if tcpLayer == nil {
		t.Fatal("serialized packet has no TCP layer")
	}
	tcp := tcpLayer.(*layers.TCP)
	copyTCP := *tcp
	return &copyTCP
}

func TestPacketLevelSynAndDataRetransmissions(t *testing.T) {
	h := newTestHandle()
	peer := net.IPv4(203, 0, 113, 7)

	firstSYN := wireTCP(t, h, peer, conf.TCPF{SYN: true}, nil)
	retrySYN := wireTCP(t, h, peer, conf.TCPF{SYN: true}, nil)
	if !firstSYN.SYN || firstSYN.ACK || firstSYN.Seq != retrySYN.Seq {
		t.Fatalf("SYN retransmission mismatch: first flags SYN=%v ACK=%v seq=%d, retry seq=%d", firstSYN.SYN, firstSYN.ACK, firstSYN.Seq, retrySYN.Seq)
	}

	payload := []byte("encrypted KCP packet bytes")
	firstData := wireTCP(t, h, peer, conf.TCPF{PSH: true, ACK: true}, payload)
	retryData := wireTCPAtSeq(t, h, peer, conf.TCPF{PSH: true, ACK: true}, payload, &firstData.Seq)
	if !firstData.PSH || !firstData.ACK || firstData.Seq != retryData.Seq {
		t.Fatalf("data retransmission mismatch: flags PSH=%v ACK=%v seq=%d, retry seq=%d", firstData.PSH, firstData.ACK, firstData.Seq, retryData.Seq)
	}
}

func TestOutstandingPacketIsRetransmittedUntilAcknowledged(t *testing.T) {
	h := newTestHandle()
	peer := net.IPv4(203, 0, 113, 7)
	now := h.tsStarted
	h.now = func() time.Time { return now }
	payload := []byte("outer tcp payload")
	seq, _ := stamp(t, h, peer, 3000, conf.TCPF{PSH: true, ACK: true}, payload)
	h.rememberSent(peer, 3000, seq, payload)

	if due := h.dueRetransmissions(now.Add(initialRTO - time.Millisecond)); len(due) != 0 {
		t.Fatalf("packet retransmitted before RTO: %d due", len(due))
	}
	due := h.dueRetransmissions(now.Add(initialRTO))
	if len(due) != 1 || due[0].seq != seq {
		t.Fatalf("due retransmissions = %+v, want one packet at seq %d", due, seq)
	}

	h.noteRecv(&Packet{Addr: net.UDPAddr{IP: peer, Port: 3000}, Seq: 7000, Ack: seq + uint32(len(payload)), ACK: true})
	if due := h.dueRetransmissions(now.Add(10 * time.Second)); len(due) != 0 {
		t.Fatalf("acknowledged packet remained pending: %d due", len(due))
	}
}
