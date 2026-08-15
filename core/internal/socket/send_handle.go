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
	inited        bool
	rcvInit       bool
	peerTSSet     bool
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
	tcpF        tcpF
	ePool       sync.Pool

	tos      uint8
	ttl      uint8
	window   uint16
	trackSeq bool
	flows    map[uint64]*flowState
	flowMu   sync.Mutex
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

	sh := &SendHandle{
		handle:   handle,
		srcPort:  uint16(cfg.Port),
		tcpF:     tcpF{tcpF: iterator.Iterator[conf.TCPF]{Items: cfg.TCP.LF}, clientTCPF: make(map[uint64]*iterator.Iterator[conf.TCPF])},
		time:     uint32(time.Now().UnixNano() / int64(time.Millisecond)),
		tos:      cfg.TCP.TOS,
		ttl:      cfg.TCP.TTL,
		window:   cfg.TCP.Window,
		trackSeq: cfg.TCP.TrackSeq,
		flows:    make(map[uint64]*flowState),
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
	if cfg.IPv4.Addr != nil {
		sh.srcIPv4 = cfg.IPv4.Addr.IP
		sh.srcIPv4RHWA = cfg.IPv4.Router
	}
	if cfg.IPv6.Addr != nil {
		sh.srcIPv6 = cfg.IPv6.Addr.IP
		sh.srcIPv6RHWA = cfg.IPv6.Router
	}
	return sh, nil
}

func (h *SendHandle) buildIPv4Header(e *encoder, dstIP net.IP) {
	e.ip4 = layers.IPv4{
		Version:  4,
		IHL:      5,
		TOS:      h.tos,
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
		HopLimit:     h.ttl,
		NextHeader:   layers.IPProtocolTCP,
		SrcIP:        h.srcIPv6,
		DstIP:        dstIP,
	}
}

func (h *SendHandle) buildTCPHeader(e *encoder, dstIP net.IP, dstPort uint16, f conf.TCPF, payloadLen int) {
	e.tcp = layers.TCP{
		SrcPort: layers.TCPPort(h.srcPort),
		DstPort: layers.TCPPort(dstPort),
		FIN:     f.FIN, SYN: f.SYN, RST: f.RST, PSH: f.PSH, ACK: f.ACK, URG: f.URG, ECE: f.ECE, CWR: f.CWR, NS: f.NS,
		Window: h.window,
	}

	counter := h.tsCounter.Add(1)
	tsVal := h.time + (counter >> 3)

	var tsEcr uint32
	if h.trackSeq {
		tsEcr = h.applyTrackedSeq(e, dstIP, dstPort, f, payloadLen)
	} else if f.SYN {
		e.tcp.Seq = 1 + (counter & 0x7)
		e.tcp.Ack = 0
		if f.ACK {
			e.tcp.Ack = e.tcp.Seq + 1
		}
	} else {
		seq := h.time + (counter << 7)
		e.tcp.Seq = seq
		e.tcp.Ack = seq - (counter & 0x3FF) + 1400
	}
	if tsEcr == 0 {
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

// applyTrackedSeq stamps a coherent SEQ/ACK pair on the segment and returns the
// timestamp value to echo, or 0 when the peer has not advertised one yet.
func (h *SendHandle) applyTrackedSeq(e *encoder, dstIP net.IP, dstPort uint16, f conf.TCPF, payloadLen int) uint32 {
	h.flowMu.Lock()
	defer h.flowMu.Unlock()

	flow := h.flow(flowKey(dstIP, dstPort))

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
		flow.seq += uint32(payloadLen)
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
		// Plausible placeholder until the peer's real sequence space is seen,
		// so we never advertise ACK 0 on a data segment.
		flow.ack = h.newISN()
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

	next := pkt.Seq + uint32(len(pkt.Payload))
	if pkt.SYN || pkt.FIN {
		next++
	}
	if !flow.rcvInit {
		flow.ack = next
		flow.rcvInit = true
	} else if d := int32(next - flow.ack); d > 0 && d < maxAckAdvance {
		// Retransmits and reordering must not rewind the ACK we advertise, and
		// an injected segment must not drag it far past the real data either.
		flow.ack = next
	}

	if pkt.TSOK {
		flow.peerTS = pkt.TSVal
		flow.peerTSSet = true
	}
}

// syncSynAck records the peer's ISN from a SYN-ACK and moves our own sequence
// past the SYN we already sent, so the first data segment continues the flow.
func (h *SendHandle) syncSynAck(pkt *Packet) {
	if !h.trackSeq {
		return
	}
	h.flowMu.Lock()
	flow := h.flow(flowKey(pkt.Addr.IP, uint16(pkt.Addr.Port)))
	flow.seq = flow.isn + 1
	h.flowMu.Unlock()

	h.noteRecv(pkt)
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
	e := h.ePool.Get().(*encoder)
	defer func() {
		e.buf.Clear()
		h.ePool.Put(e)
	}()

	dstIP := addr.IP
	dstPort := uint16(addr.Port)

	h.buildTCPHeader(e, dstIP, dstPort, f, len(payload))

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
	return err
}

func (h *SendHandle) getClientTCPF(dstIP net.IP, dstPort uint16) conf.TCPF {
	h.tcpF.mu.RLock()
	defer h.tcpF.mu.RUnlock()
	if ff := h.tcpF.clientTCPF[hash.IPAddr(dstIP, dstPort)]; ff != nil {
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
	h.tcpF.clientTCPF[hash.IPAddr(a.IP, uint16(a.Port))] = &iterator.Iterator[conf.TCPF]{Items: f}
	h.tcpF.mu.Unlock()
}

func (h *SendHandle) deleteClientTCPF(addr net.Addr) {
	a, ok := addr.(*net.UDPAddr)
	if !ok {
		return
	}
	h.tcpF.mu.Lock()
	delete(h.tcpF.clientTCPF, hash.IPAddr(a.IP, uint16(a.Port)))
	h.tcpF.mu.Unlock()

	h.deleteFlow(a.IP, uint16(a.Port))
}

func (h *SendHandle) Close() {
	if h.handle != nil {
		h.handle.Close()
	}
}
