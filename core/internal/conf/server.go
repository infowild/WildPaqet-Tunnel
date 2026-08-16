package conf

import (
	"fmt"
	"net"
)

type Server struct {
	Addr_     string         `yaml:"addr"`
	Addrs_    []string       `yaml:"addrs"`
	Addr      *net.UDPAddr   `yaml:"-"`
	Addrs     []*net.UDPAddr `yaml:"-"`
	Endpoints []string       `yaml:"-"`
}

func (s *Server) setDefaults() {}
func (s *Server) validate() []error {
	var errors []error
	addr, err := validateAddr(s.Addr_, true)
	if err != nil {
		errors = append(errors, err)
	}
	s.Addr = addr

	s.Addrs = nil
	if s.Addr != nil {
		s.Addrs = []*net.UDPAddr{s.Addr}
		seen := map[string]struct{}{s.Addr.String(): {}}
		for i, raw := range s.Addrs_ {
			a, err := validateAddr(raw, true)
			if err != nil {
				errors = append(errors, fmt.Errorf("addrs[%d]: %v", i, err))
				continue
			}
			key := a.String()
			if _, ok := seen[key]; ok {
				continue
			}
			seen[key] = struct{}{}
			s.Addrs = append(s.Addrs, a)
		}
	}

	return errors
}

func (s *Server) validateTLS() []error {
	var errors []error
	values := append([]string(nil), s.Addr_)
	values = append(values, s.Addrs_...)
	s.Endpoints = nil
	seen := make(map[string]struct{}, len(values))
	for i, addr := range values {
		if err := validateHostPort(addr, true); err != nil {
			errors = append(errors, fmt.Errorf("TLS endpoint[%d]: %v", i, err))
			continue
		}
		if _, ok := seen[addr]; ok {
			continue
		}
		seen[addr] = struct{}{}
		s.Endpoints = append(s.Endpoints, addr)
	}
	return errors
}
