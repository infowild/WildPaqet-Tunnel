package socket

import (
	"encoding/binary"
	"fmt"
	"net"
	"runtime"
	"sync"
	"time"

	"github.com/gopacket/gopacket"
	"github.com/gopacket/gopacket/layers"
	"github.com/gopacket/gopacket/pcap"

	"paqet/internal/conf"
)

type decoder struct {
	parser  *gopacket.DecodingLayerParser
	eth     layers.Ethernet
	ip4     layers.IPv4
	ip6     layers.IPv6
	tcp     layers.TCP
	decoded []gopacket.LayerType
}

// Packet is a decoded inbound TCP segment. Payload aliases the pcap capture
// buffer and is only valid until the next Read on the same handle.
type Packet struct {
	Payload []byte
	Addr    net.UDPAddr
	Seq     uint32
	Ack     uint32
	TSVal   uint32
	TSOK    bool
	SYN     bool
	ACK     bool
	FIN     bool
	RST     bool
}

type RecvHandle struct {
	handle *pcap.Handle
	dPool  sync.Pool
}

func NewRecvHandle(cfg *conf.Network) (*RecvHandle, error) {
	handle, err := newHandle(cfg, cfg.PCAP.Sockbuf, 65536, time.Millisecond)
	if err != nil {
		return nil, fmt.Errorf("failed to open pcap handle: %w", err)
	}

	// SetDirection is not fully supported on Windows Npcap, so skip it
	if runtime.GOOS != "windows" {
		if err := handle.SetDirection(pcap.DirectionIn); err != nil {
			return nil, fmt.Errorf("failed to set pcap direction in: %v", err)
		}
	}

	filter := fmt.Sprintf("tcp and dst port %d", cfg.Port)
	if err := handle.SetBPFFilter(filter); err != nil {
		return nil, fmt.Errorf("failed to set BPF filter: %w", err)
	}

	h := &RecvHandle{handle: handle}
	h.dPool.New = func() any {
		d := &decoder{decoded: make([]gopacket.LayerType, 0, 4)}
		d.parser = gopacket.NewDecodingLayerParser(layers.LayerTypeEthernet, &d.eth, &d.ip4, &d.ip6, &d.tcp)
		d.parser.IgnoreUnsupported = true
		return d
	}

	return h, nil
}

// Read decodes the next inbound segment into pkt. Control segments (SYN,
// SYN-ACK, bare ACK) are returned too, so the handshake can be driven from
// them; callers that only want data must check len(pkt.Payload).
func (h *RecvHandle) Read(pkt *Packet) error {
	data, _, err := h.handle.ReadPacketData()
	if err != nil {
		return err
	}

	d := h.dPool.Get().(*decoder)
	defer h.dPool.Put(d)

	if err := d.parser.DecodeLayers(data, &d.decoded); err != nil {
		return errNoPayload
	}

	*pkt = Packet{}
	var sawTCP bool
	for _, t := range d.decoded {
		switch t {
		case layers.LayerTypeIPv4:
			pkt.Addr.IP = d.ip4.SrcIP
		case layers.LayerTypeIPv6:
			pkt.Addr.IP = d.ip6.SrcIP
		case layers.LayerTypeTCP:
			sawTCP = true
			pkt.Addr.Port = int(d.tcp.SrcPort)
			pkt.Payload = d.tcp.Payload
			pkt.Seq = d.tcp.Seq
			pkt.Ack = d.tcp.Ack
			pkt.SYN, pkt.ACK, pkt.FIN, pkt.RST = d.tcp.SYN, d.tcp.ACK, d.tcp.FIN, d.tcp.RST
			for _, o := range d.tcp.Options {
				if o.OptionType == layers.TCPOptionKindTimestamps && len(o.OptionData) >= 8 {
					pkt.TSVal = binary.BigEndian.Uint32(o.OptionData[0:4])
					pkt.TSOK = true
					break
				}
			}
		}
	}

	if pkt.Addr.IP == nil || !sawTCP {
		return errNoPayload
	}

	return nil
}

func (h *RecvHandle) Close() {
	if h.handle != nil {
		h.handle.Close()
	}
}
