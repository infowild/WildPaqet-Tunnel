package socket

import (
	"encoding/binary"
	"fmt"
	"math/rand"
	"net"
	"runtime"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gopacket/gopacket"
	"github.com/gopacket/gopacket/layers"
	"github.com/gopacket/gopacket/pcap"

	"paqet/internal/conf"
	"paqet/internal/pkg/hash"
	"paqet/internal/pkg/iterator"
)

// Largest jump we will accept in one step for the peer's sequence space. Well
// above any real in-flight window, low enough that a forged segment cannot
// strand our ACK in the far future.
const maxAckAdvance = 1 << 24

const (
	retransmitTick = 50 * time.Millisecond
	initialRTO     = 200 * time.Millisecond
	maxRTO         = 3 * time.Second
	maxRetransmits = 5
	maxOutstanding = 2048
)

type txSegment struct {
	payload []byte
	seq     uint32
	last    time.Time
	retries int
}

type seqRange struct {
	start uint32
	end   uint32
}

type tcpF struct {
	tcpF       iterator.Iterator[conf.TCPF]
	clientTCPF map[uint64]*iterator.Iterator[conf.TCPF]
	mu         sync.RWMutex
}

// flowState mirrors the sequence space of one peer so the flow on the wire is
// internally consistent: seq counts bytes we sent, ack counts bytes we received.
type flowState struct {
	seq, ack, isn uint32
	peerTS        uint32
	dstIP         net.IP
	dstPort       uint16
	inited        bool
	rcvInit       bool
	peerTSSet     bool
	peerAck       uint32
	peerAckSet    bool
	tx            map[uint32]*txSegment
	received      []seqRange
}

type encoder struct {
	eth layers.Ethernet
	ip4 layers.IPv4
	ip6 layers.IPv6
	tcp layers.TCP

	opts [5]layers.TCPOption
	ts   [8]byte
	mss  [2]byte
	ws   [1]byte

	buf gopacket.SerializeBuffer
}

type SendHandle struct {
	handle      *pcap.Handle
	writeMu     sync.Mutex
	srcIPv4     net.IP
	srcIPv4RHWA net.HardwareAddr
	srcIPv6     net.IP
	srcIPv6RHWA net.HardwareAddr
	srcPort     uint16
	time        uint32
	tsCounter   atomic.Uint32
	tsStarted   time.Time
	now         func() time.Time
	ipID        atomic.Uint32
	tcpF        tcpF
	ePool       sync.Pool

	tos      uint8
	ttl      uint8
	window   uint16
	trackSeq bool
	flows    map[uint64]*flowState
	flowMu   sync.Mutex
	stop     chan struct{}
	done     chan struct{}
	close    sync.Once
}

func NewSendHandle(cfg *conf.Network) (*SendHandle, error) {
	handle, err := newHandle(cfg, 256*1024, 128, pcap.BlockForever)
	if err != nil {
		return nil, fmt.Errorf("failed to open pcap handle: %w", err)
	}

	// SetDirection is not fully supported on Windows Npcap, so skip it
	if runtime.GOOS != "windows" {
		if err := handle.SetDirection(pcap.DirectionOut); err != nil {
			return nil, fmt.Errorf("failed to set pcap direction out: %v", err)
		}
	}

	if err := handle.SetBPFFilter("less 0"); err != nil {
		return nil, fmt.Errorf("failed to set BPF filter: %w", err)
	}

	now := time.Now()
	sh := &SendHandle{
		handle:    handle,
		srcPort:   uint16(cfg.Port),
		tcpF:      tcpF{tcpF: iterator.Iterator[conf.TCPF]{Items: cfg.TCP.LF}, clientTCPF: make(map[uint64]*iterator.Iterator[conf.TCPF])},
		time:      uint32(now.UnixMilli()),
		tsStarted: now,
		now:       time.Now,
		tos:       cfg.TCP.TOS,
		ttl:       cfg.TCP.TTL,
		window:    cfg.TCP.Window,
		trackSeq:  cfg.TCP.TrackSeq,
		flows:     make(map[uint64]*flowState),
		stop:      make(chan struct{}),
		done:      make(chan struct{}),
		ePool: sync.Pool{
			New: func() any {
				return &encoder{
					eth: layers.Ethernet{SrcMAC: cfg.Interface.HardwareAddr},
					mss: [2]byte{0x05, 0xb4},
					ws:  [1]byte{8},
					buf: gopacket.NewSerializeBuffer(),
				}
			},
		},
	}
	sh.ipID.Store(rand.Uint32())
	if cfg.IPv4.Addr != nil {
		sh.srcIPv4 = cfg.IPv4.Addr.IP
		sh.srcIPv4RHWA = cfg.IPv4.Router
	}
	if cfg.IPv6.Addr != nil {
		sh.srcIPv6 = cfg.IPv6.Addr.IP
		sh.srcIPv6RHWA = cfg.IPv6.Router
	}
	go sh.retransmitLoop()
	return sh, nil
}

func (h *SendHandle) buildIPv4Header(e *encoder, dstIP net.IP) {
	// A fixed IP.id of 0 on every DF packet is a bulk-tunnel signature; real
	// Linux stacks emit a moving value. Start random per handle, then increment.
	e.ip4 = layers.IPv4{
		Version:  4,
		IHL:      5,
		TOS:      h.tos,
		Id:       uint16(h.ipID.Add(1)),
		TTL:      h.ttl,
		Flags:    layers.IPv4DontFragment,
		Protocol: layers.IPProtocolTCP,
		SrcIP:    h.srcIPv4,
		DstIP:    dstIP,
	}
}

func (h *SendHandle) buildIPv6Header(e *encoder, dstIP net.IP) {
	e.ip6 = layers.IPv6{
		Version:      6,
		TrafficClass: h.tos,
		FlowLabel:    h.ipID.Add(1) & 0xFFFFF,
		HopLimit:     h.ttl,
		NextHeader:   layers.IPProtocolTCP,
		SrcIP:        h.srcIPv6,
		DstIP:        dstIP,
	}
}

func (h *SendHandle) buildTCPHeader(e *encoder, dstIP net.IP, dstPort uint16, f conf.TCPF, payload []byte) {
	h.buildTCPHeaderAtSeq(e, dstIP, dstPort, f, payload, nil)
}

func (h *SendHandle) buildTCPHeaderAtSeq(e *encoder, dstIP net.IP, dstPort uint16, f conf.TCPF, payload []byte, seqOverride *uint32) {
	e.tcp = layers.TCP{
		SrcPort: layers.TCPPort(h.srcPort),
		DstPort: layers.TCPPort(dstPort),
		FIN:     f.FIN, SYN: f.SYN, RST: f.RST, PSH: f.PSH, ACK: f.ACK, URG: f.URG, ECE: f.ECE, CWR: f.CWR, NS: f.NS,
		Window: h.window,
	}

	counter := h.tsCounter.Add(1)
	tsVal := h.timestamp()

	var tsEcr uint32
	if h.trackSeq {
		// In tracked mode tsEcr is the peer's real TSval, or 0 until we have
		// heard from the peer — a real stack does not echo a timestamp it
		// never received, so we do not fabricate one here.
		tsEcr = h.applyTrackedSeq(e, dstIP, dstPort, f, payload, seqOverride)
	} else if f.SYN {
		e.tcp.Seq = 1 + (counter & 0x7)
		e.tcp.Ack = 0
		if f.ACK {
			e.tcp.Ack = e.tcp.Seq + 1
		}
		tsEcr = tsVal - (counter%200 + 50)
	} else {
		seq := h.time + (counter << 7)
		e.tcp.Seq = seq
		e.tcp.Ack = seq - (counter & 0x3FF) + 1400
		tsEcr = tsVal - (counter%200 + 50)
	}

	opts := e.opts[:0]
	if f.SYN {
		binary.BigEndian.PutUint32(e.ts[0:4], tsVal)
		binary.BigEndian.PutUint32(e.ts[4:8], 0)
		if f.ACK {
			binary.BigEndian.PutUint32(e.ts[4:8], tsEcr)
		}
		opts = append(opts,
			layers.TCPOption{OptionType: layers.TCPOptionKindMSS, OptionLength: 4, OptionData: e.mss[:]},
			layers.TCPOption{OptionType: layers.TCPOptionKindSACKPermitted, OptionLength: 2},
			layers.TCPOption{OptionType: layers.TCPOptionKindTimestamps, OptionLength: 10, OptionData: e.ts[:]},
			layers.TCPOption{OptionType: layers.TCPOptionKindNop},
			layers.TCPOption{OptionType: layers.TCPOptionKindWindowScale, OptionLength: 3, OptionData: e.ws[:]},
		)
	} else {
		binary.BigEndian.PutUint32(e.ts[0:4], tsVal)
		binary.BigEndian.PutUint32(e.ts[4:8], tsEcr)
		opts = append(opts,
			layers.TCPOption{OptionType: layers.TCPOptionKindNop},
			layers.TCPOption{OptionType: layers.TCPOptionKindNop},
			layers.TCPOption{OptionType: layers.TCPOptionKindTimestamps, OptionLength: 10, OptionData: e.ts[:]},
		)
	}
	e.tcp.Options = opts
}

// timestamp advances with elapsed monotonic time rather than packet count. It
// therefore continues to reflect idle periods and cannot speed up with bursts.
func (h *SendHandle) timestamp() uint32 {
	if h.now == nil || h.tsStarted.IsZero() {
		return h.time
	}
	elapsed := h.now().Sub(h.tsStarted)
	if elapsed < 0 {
		elapsed = 0
	}
	return h.time + uint32(elapsed/time.Millisecond)
}

// applyTrackedSeq stamps a coherent SEQ/ACK pair on the segment and returns the
// timestamp value to echo, or 0 when the peer has not advertised one yet.
func (h *SendHandle) applyTrackedSeq(e *encoder, dstIP net.IP, dstPort uint16, f conf.TCPF, payload []byte, seqOverride *uint32) uint32 {
	h.flowMu.Lock()
	defer h.flowMu.Unlock()

	flow := h.flow(flowKey(dstIP, dstPort))
	if flow.dstIP == nil {
		flow.dstIP = append(net.IP(nil), dstIP...)
		flow.dstPort = dstPort
	}

	if f.SYN {
		// A SYN or SYN-ACK carries no data but consumes one sequence number.
		e.tcp.Seq = flow.isn
		e.tcp.Ack = 0
		if f.ACK {
			e.tcp.Ack = flow.ack
		}
		flow.seq = flow.isn + 1
	} else {
		e.tcp.Seq = flow.seq
		e.tcp.Ack = flow.ack
		if seqOverride != nil {
			e.tcp.Seq = *seqOverride
		} else {
			flow.seq += uint32(len(payload))
		}
	}

	if flow.peerTSSet {
		return flow.peerTS
	}
	return 0
}

// flowKey normalises IPv4 to its 4-byte form first, otherwise the same peer
// hashes to two different keys depending on how the address was built.
func flowKey(ip net.IP, port uint16) uint64 {
	if v4 := ip.To4(); v4 != nil {
		return hash.IPAddr(v4, port)
	}
	return hash.IPAddr(ip, port)
}

// flow returns the state for key, seeding it on first use. Callers hold flowMu.
func (h *SendHandle) flow(key uint64) *flowState {
	flow := h.flows[key]
	if flow == nil {
		flow = &flowState{}
		h.flows[key] = flow
	}
	if !flow.inited {
		flow.isn = h.newISN()
		flow.seq = flow.isn
		// Leave ack at 0 until the peer's sequence space is actually seen; a
		// random placeholder would advertise an ACK that matches no peer byte,
		// which stateful DPI can flag. In the normal (both-hardened) path the
		// SYN-ACK is processed before any data, so ack is set before it matters.
		flow.ack = 0
		flow.inited = true
	}
	return flow
}

func (h *SendHandle) newISN() uint32 {
	v := rand.Uint32() ^ h.time ^ h.tsCounter.Load()
	if v == 0 {
		v = 1
	}
	return v
}

// noteRecv folds an inbound segment into our view of the peer's sequence space
// so subsequent ACK numbers are the ones a real stack would send.
func (h *SendHandle) noteRecv(pkt *Packet) {
	if !h.trackSeq || pkt.RST {
		return
	}

	h.flowMu.Lock()
	defer h.flowMu.Unlock()

	flow := h.flow(flowKey(pkt.Addr.IP, uint16(pkt.Addr.Port)))
	if flow.dstIP == nil {
		flow.dstIP = append(net.IP(nil), pkt.Addr.IP...)
		flow.dstPort = uint16(pkt.Addr.Port)
	}

	next := pkt.Seq + uint32(len(pkt.Payload))
	if pkt.SYN || pkt.FIN {
		next++
	}
	h.noteReceived(flow, pkt.Seq, next)
	if pkt.ACK && seqLessOrEqual(pkt.Ack, flow.seq) {
		if !flow.peerAckSet || seqLessOrEqual(flow.peerAck, pkt.Ack) {
			flow.peerAck = pkt.Ack
			flow.peerAckSet = true
		}
		for seq, segment := range flow.tx {
			end := seq + uint32(len(segment.payload))
			if seqLessOrEqual(end, pkt.Ack) {
				delete(flow.tx, seq)
			}
		}
	}

	if pkt.TSOK {
		flow.peerTS = pkt.TSVal
		flow.peerTSSet = true
	}
}

// noteReceived maintains a cumulative TCP ACK. Out-of-order data is retained
// as a bounded range but cannot acknowledge across a gap.
func (h *SendHandle) noteReceived(flow *flowState, start, end uint32) {
	if !flow.rcvInit {
		flow.ack = end
		flow.rcvInit = true
		return
	}
	if seqLessOrEqual(end, flow.ack) {
		return
	}
	if seqLessOrEqual(start, flow.ack) {
		flow.ack = end
		h.consumeReceivedRanges(flow)
		return
	}
	if d := int32(start - flow.ack); d <= 0 || d >= maxAckAdvance || len(flow.received) >= 128 {
		return
	}
	flow.received = append(flow.received, seqRange{start: start, end: end})
}

func (h *SendHandle) consumeReceivedRanges(flow *flowState) {
	for {
		advanced := false
		for i := 0; i < len(flow.received); {
			r := flow.received[i]
			if seqLessOrEqual(r.end, flow.ack) {
				flow.received = append(flow.received[:i], flow.received[i+1:]...)
				continue
			}
			if seqLessOrEqual(r.start, flow.ack) {
				flow.ack = r.end
				flow.received = append(flow.received[:i], flow.received[i+1:]...)
				advanced = true
				continue
			}
			i++
		}
		if !advanced {
			return
		}
	}
}

func seqLessOrEqual(a, b uint32) bool {
	return int32(a-b) <= 0
}

// syncSynAck records the peer's ISN from a SYN-ACK and moves our own sequence
// past the SYN we already sent, so the first data segment continues the flow.
// It returns false when the segment does not acknowledge the SYN we sent, so a
// spoofed or stale SYN-ACK cannot desync the flow.
func (h *SendHandle) syncSynAck(pkt *Packet) bool {
	if !h.trackSeq {
		return true
	}
	h.flowMu.Lock()
	flow := h.flow(flowKey(pkt.Addr.IP, uint16(pkt.Addr.Port)))
	if pkt.Ack != flow.isn+1 {
		h.flowMu.Unlock()
		return false
	}
	flow.seq = flow.isn + 1
	h.flowMu.Unlock()

	h.noteRecv(pkt)
	return true
}

func (h *SendHandle) deleteFlow(ip net.IP, port uint16) {
	h.flowMu.Lock()
	delete(h.flows, flowKey(ip, port))
	h.flowMu.Unlock()
}

func (h *SendHandle) Write(payload []byte, addr *net.UDPAddr) error {
	return h.write(payload, addr, h.getClientTCPF(addr.IP, uint16(addr.Port)))
}

// WriteControl emits a payload-less segment such as SYN, SYN-ACK or a bare ACK.
func (h *SendHandle) WriteControl(addr *net.UDPAddr, f conf.TCPF) error {
	return h.write(nil, addr, f)
}

func (h *SendHandle) write(payload []byte, addr *net.UDPAddr, f conf.TCPF) error {
	return h.writeAtSeq(payload, addr, f, nil, true)
}

func (h *SendHandle) writeAtSeq(payload []byte, addr *net.UDPAddr, f conf.TCPF, seqOverride *uint32, remember bool) error {
	e := h.ePool.Get().(*encoder)
	defer func() {
		e.buf.Clear()
		h.ePool.Put(e)
	}()

	dstIP := addr.IP
	dstPort := uint16(addr.Port)

	h.buildTCPHeaderAtSeq(e, dstIP, dstPort, f, payload, seqOverride)

	var ipLayer gopacket.SerializableLayer
	if dstIP.To4() != nil {
		h.buildIPv4Header(e, dstIP)
		ipLayer = &e.ip4
		e.tcp.SetNetworkLayerForChecksum(&e.ip4)
		e.eth.DstMAC = h.srcIPv4RHWA
		e.eth.EthernetType = layers.EthernetTypeIPv4
	} else {
		h.buildIPv6Header(e, dstIP)
		ipLayer = &e.ip6
		e.tcp.SetNetworkLayerForChecksum(&e.ip6)
		e.eth.DstMAC = h.srcIPv6RHWA
		e.eth.EthernetType = layers.EthernetTypeIPv6
	}

	opts := gopacket.SerializeOptions{FixLengths: true, ComputeChecksums: true}
	if err := gopacket.SerializeLayers(e.buf, opts, &e.eth, ipLayer, &e.tcp, gopacket.Payload(payload)); err != nil {
		return err
	}

	// pcap_sendpacket is not guaranteed thread-safe.
	h.writeMu.Lock()
	err := h.handle.WritePacketData(e.buf.Bytes())
	h.writeMu.Unlock()
	if err == nil && remember && h.trackSeq && len(payload) != 0 {
		h.rememberSent(dstIP, dstPort, e.tcp.Seq, payload)
	}
	return err
}

func (h *SendHandle) rememberSent(dstIP net.IP, dstPort uint16, seq uint32, payload []byte) {
	h.flowMu.Lock()
	defer h.flowMu.Unlock()
	flow := h.flow(flowKey(dstIP, dstPort))
	if flow.tx == nil {
		flow.tx = make(map[uint32]*txSegment)
	}
	if flow.peerAckSet && seqLessOrEqual(seq+uint32(len(payload)), flow.peerAck) {
		return
	}
	if len(flow.tx) >= maxOutstanding {
		var oldestSeq uint32
		var oldest time.Time
		for candidate, segment := range flow.tx {
			if oldest.IsZero() || segment.last.Before(oldest) {
				oldestSeq, oldest = candidate, segment.last
			}
		}
		delete(flow.tx, oldestSeq)
	}
	flow.tx[seq] = &txSegment{payload: append([]byte(nil), payload...), seq: seq, last: h.clockNow()}
}

func (h *SendHandle) clockNow() time.Time {
	if h.now != nil {
		return h.now()
	}
	return time.Now()
}

func retransmitTimeout(retries int) time.Duration {
	rto := initialRTO << retries
	if rto > maxRTO {
		return maxRTO
	}
	return rto
}

type retransmission struct {
	addr    net.UDPAddr
	payload []byte
	seq     uint32
}

func (h *SendHandle) dueRetransmissions(now time.Time) []retransmission {
	h.flowMu.Lock()
	defer h.flowMu.Unlock()
	var due []retransmission
	for _, flow := range h.flows {
		for seq, segment := range flow.tx {
			if segment.retries >= maxRetransmits {
				delete(flow.tx, seq)
				continue
			}
			if now.Sub(segment.last) < retransmitTimeout(segment.retries) {
				continue
			}
			segment.last = now
			segment.retries++
			due = append(due, retransmission{
				addr:    net.UDPAddr{IP: append(net.IP(nil), flow.dstIP...), Port: int(flow.dstPort)},
				payload: append([]byte(nil), segment.payload...),
				seq:     segment.seq,
			})
		}
	}
	return due
}

func (h *SendHandle) retransmitLoop() {
	defer close(h.done)
	ticker := time.NewTicker(retransmitTick)
	defer ticker.Stop()
	for {
		select {
		case <-h.stop:
			return
		case now := <-ticker.C:
			for _, segment := range h.dueRetransmissions(now) {
				seq := segment.seq
				_ = h.writeAtSeq(segment.payload, &segment.addr, conf.TCPF{PSH: true, ACK: true}, &seq, false)
			}
		}
	}
}

func (h *SendHandle) getClientTCPF(dstIP net.IP, dstPort uint16) conf.TCPF {
	h.tcpF.mu.RLock()
	defer h.tcpF.mu.RUnlock()
	if ff := h.tcpF.clientTCPF[flowKey(dstIP, dstPort)]; ff != nil {
		return ff.Next()
	}
	return h.tcpF.tcpF.Next()
}

func (h *SendHandle) setClientTCPF(addr net.Addr, f []conf.TCPF) {
	a, ok := addr.(*net.UDPAddr)
	if !ok {
		return
	}
	h.tcpF.mu.Lock()
	h.tcpF.clientTCPF[flowKey(a.IP, uint16(a.Port))] = &iterator.Iterator[conf.TCPF]{Items: f}
	h.tcpF.mu.Unlock()
}

func (h *SendHandle) deleteClientTCPF(addr net.Addr) {
	a, ok := addr.(*net.UDPAddr)
	if !ok {
		return
	}
	h.tcpF.mu.Lock()
	delete(h.tcpF.clientTCPF, flowKey(a.IP, uint16(a.Port)))
	h.tcpF.mu.Unlock()

	h.deleteFlow(a.IP, uint16(a.Port))
}

// teardown sends a best-effort FIN,ACK to every peer we actually exchanged data
// with, so flows end the way a real TCP connection does instead of going silent
// mid-stream — a lingering half-open flow is a cheap signature for a tunnel.
func (h *SendHandle) teardown() {
	if !h.trackSeq {
		return
	}
	type peer struct {
		ip   net.IP
		port uint16
	}
	var peers []peer
	h.flowMu.Lock()
	for _, f := range h.flows {
		if f.rcvInit && f.dstIP != nil {
			peers = append(peers, peer{ip: f.dstIP, port: f.dstPort})
		}
	}
	h.flowMu.Unlock()

	for _, p := range peers {
		_ = h.WriteControl(&net.UDPAddr{IP: p.ip, Port: int(p.port)}, conf.TCPF{FIN: true, ACK: true})
	}
}

func (h *SendHandle) Close() {
	h.close.Do(func() {
		if h.stop != nil {
			close(h.stop)
			<-h.done
		}
		h.teardown()
		if h.handle != nil {
			h.handle.Close()
		}
	})
}
