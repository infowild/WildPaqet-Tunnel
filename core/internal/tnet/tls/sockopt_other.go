//go:build !linux

package tls

import "syscall"

// setNotsentLowat is Linux-only; elsewhere the tunnel runs without it.
func setNotsentLowat(syscall.RawConn) error { return nil }
