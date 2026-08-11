package conf

import (
	"fmt"
)

type TCP struct {
	LF_ []string `yaml:"local_flag"`
	RF_ []string `yaml:"remote_flag"`
	LF  []TCPF   `yaml:"-"`
	RF  []TCPF   `yaml:"-"`

	Preset_    string `yaml:"preset"`
	TrackSeq_  *bool  `yaml:"track_seq"`
	Handshake_ string `yaml:"handshake"`
	IPv4TOS_   *int   `yaml:"ipv4_tos"`
	TTL_       *int   `yaml:"ttl"`
	Window_    *int   `yaml:"window"`

	Preset    string `yaml:"-"`
	TrackSeq  bool   `yaml:"-"`
	Handshake string `yaml:"-"`
	TOS       uint8  `yaml:"-"`
	TTL       uint8  `yaml:"-"`
	Window    uint16 `yaml:"-"`
}

type TCPF struct {
	FIN, SYN, RST, PSH, ACK, URG, ECE, CWR, NS bool
}

func (t *TCP) setDefaults() {
	if len(t.LF_) == 0 {
		t.LF_ = []string{"PA"}
	}
	if len(t.RF_) == 0 {
		t.RF_ = []string{"PA"}
	}
}

func (t *TCP) validate() []error {
	var errors []error

	if len(t.LF_) != 0 {
		t.LF = make([]TCPF, len(t.LF_))
		for i, fStr := range t.LF_ {
			f, err := strTCPF(fStr)
			if err != nil {
				errors = append(errors, err)
			}
			t.LF[i] = f
		}
	}
	if len(t.RF_) != 0 {
		t.RF = make([]TCPF, len(t.RF_))
		for i, fStr := range t.RF_ {
			f, err := strTCPF(fStr)
			if err != nil {
				errors = append(errors, err)
			}
			t.RF[i] = f
		}
	}

	if len(t.LF) == 0 || len(t.RF) == 0 {
		errors = append(errors, fmt.Errorf("at least one TCP flag combination required"))
	}

	maxTCPFLen := 64
	if len(t.LF_) > maxTCPFLen {
		errors = append(errors, fmt.Errorf("local_flag exceeds max %d", maxTCPFLen))
	}
	if len(t.RF_) > maxTCPFLen {
		errors = append(errors, fmt.Errorf("remote_flag exceeds max %d", maxTCPFLen))
	}

	errors = append(errors, t.resolveWire()...)

	return errors
}

func (t *TCP) resolveWire() []error {
	var errors []error

	preset := t.Preset_
	switch preset {
	case "", "default", "restrictive":
	default:
		errors = append(errors, fmt.Errorf("tcp preset must be \"\", \"default\", or \"restrictive\""))
		preset = ""
	}
	if preset == "default" {
		preset = ""
	}
	t.Preset = preset
	restrictive := preset == "restrictive"

	handshake := t.Handshake_
	if handshake == "" {
		if restrictive {
			handshake = "mimic"
		} else {
			handshake = "none"
		}
	}
	switch handshake {
	case "none", "mimic":
	default:
		errors = append(errors, fmt.Errorf("tcp handshake must be \"none\" or \"mimic\""))
		handshake = "none"
	}
	t.Handshake = handshake

	if t.TrackSeq_ != nil {
		t.TrackSeq = *t.TrackSeq_
	} else {
		t.TrackSeq = restrictive
	}

	tos := 184
	if restrictive {
		tos = 0
	}
	if t.IPv4TOS_ != nil {
		tos = *t.IPv4TOS_
	}
	if tos < 0 || tos > 255 {
		errors = append(errors, fmt.Errorf("tcp ipv4_tos must be between 0-255"))
		tos = 0
	}
	t.TOS = uint8(tos)

	ttl := 64
	if t.TTL_ != nil {
		ttl = *t.TTL_
	}
	if ttl < 1 || ttl > 255 {
		errors = append(errors, fmt.Errorf("tcp ttl must be between 1-255"))
		ttl = 64
	}
	t.TTL = uint8(ttl)

	window := 65535
	if t.Window_ != nil {
		window = *t.Window_
	}
	if window < 0 || window > 65535 {
		errors = append(errors, fmt.Errorf("tcp window must be between 0-65535"))
		window = 65535
	}
	t.Window = uint16(window)

	return errors
}

func strTCPF(fStr string) (TCPF, error) {
	var f TCPF
	for _, ch := range fStr {
		switch ch {
		case 'F':
			f.FIN = true
		case 'S':
			f.SYN = true
		case 'R':
			f.RST = true
		case 'P':
			f.PSH = true
		case 'A':
			f.ACK = true
		case 'U':
			f.URG = true
		case 'E':
			f.ECE = true
		case 'C':
			f.CWR = true
		case 'N':
			f.NS = true
		default:
			return f, fmt.Errorf("invalid TCP flag '%c' in combination", ch)
		}
	}
	return f, nil
}
