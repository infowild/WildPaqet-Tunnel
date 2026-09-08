package conf

import (
	"fmt"
	"net"
	"time"
)

type Forward struct {
	Listen_               string        `yaml:"listen"`
	Target                string        `yaml:"target"`
	Protocol              string        `yaml:"protocol"`
	Listen                *net.UDPAddr  `yaml:"-"`
	ConnectTimeoutSeconds int           `yaml:"connect_timeout"`
	MaxPending            int           `yaml:"max_pending"`
	ConnectTimeout        time.Duration `yaml:"-"`
}

func (c *Forward) setDefaults() {
	if c.ConnectTimeoutSeconds == 0 {
		c.ConnectTimeoutSeconds = 15
	}
	if c.MaxPending == 0 {
		c.MaxPending = 256
	}
}
func (c *Forward) validate() []error {
	var errors []error
	if c.ConnectTimeoutSeconds < 1 || c.ConnectTimeoutSeconds > 120 {
		errors = append(errors, fmt.Errorf("connect_timeout must be between 1-120 seconds"))
	}
	if c.MaxPending < 1 || c.MaxPending > 65535 {
		errors = append(errors, fmt.Errorf("max_pending must be between 1-65535"))
	}
	c.ConnectTimeout = time.Duration(c.ConnectTimeoutSeconds) * time.Second
	l, err := validateAddr(c.Listen_, true)
	if err != nil {
		errors = append(errors, err)
	}
	c.Listen = l

	if err := validateHostPort(c.Target, true); err != nil {
		errors = append(errors, err)
	}

	return errors
}
