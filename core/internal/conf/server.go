package conf

import (
	"fmt"
	"net"
)

type Server struct {
	Addr_  string         `yaml:"addr"`
	Addrs_ []string       `yaml:"addrs"`
	Addr   *net.UDPAddr   `yaml:"-"`
	Addrs  []*net.UDPAddr `yaml:"-"`
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
