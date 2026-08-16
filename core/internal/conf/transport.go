package conf

import (
	"fmt"
	"slices"
)

type Transport struct {
	Protocol string `yaml:"protocol"`
	Conn     int    `yaml:"conn"`
	KCP      *KCP   `yaml:"kcp"`
	TLS      *TLS   `yaml:"tls"`
}

func (t *Transport) setDefaults(role string, endpointCount int) {
	if t.Conn == 0 {
		if role == "client" && t.Protocol == "tls" && endpointCount > 0 {
			t.Conn = endpointCount
		} else {
			t.Conn = 1
		}
	}

	switch t.Protocol {
	case "kcp":
		if t.KCP != nil {
			t.KCP.setDefaults(role)
		}
	case "tls":
		if t.TLS != nil {
			t.TLS.setDefaults()
		}
	}
}

func (t *Transport) validate(role string) []error {
	var errors []error

	validProtocols := []string{"kcp", "tls"}
	if !slices.Contains(validProtocols, t.Protocol) {
		errors = append(errors, fmt.Errorf("transport protocol must be one of: %v", validProtocols))
	}

	if t.Conn < 1 || t.Conn > 256 {
		errors = append(errors, fmt.Errorf("transport conn must be between 1-256 connections"))
	}

	switch t.Protocol {
	case "kcp":
		if t.KCP == nil {
			errors = append(errors, fmt.Errorf("transport.kcp configuration is required"))
		} else {
			errors = append(errors, t.KCP.validate()...)
		}
	case "tls":
		if t.TLS == nil {
			errors = append(errors, fmt.Errorf("transport.tls configuration is required"))
		} else {
			errors = append(errors, t.TLS.validate(role)...)
		}
	}

	return errors
}
