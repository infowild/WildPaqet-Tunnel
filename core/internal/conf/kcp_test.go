package conf

import (
	"testing"
	"time"
)

func TestKCPKeepaliveDefaultsAreConservative(t *testing.T) {
	k := &KCP{Block_: "none"}
	k.setDefaults("client")
	if errs := k.validate(); len(errs) != 0 {
		t.Fatalf("default KCP config rejected: %v", errs)
	}
	if k.Smuxkalive != 15*time.Second {
		t.Errorf("keepalive = %s, want 15s", k.Smuxkalive)
	}
	if k.Smuxktimeout != 60*time.Second {
		t.Errorf("keepalive timeout = %s, want 60s", k.Smuxktimeout)
	}
}

func TestExplicitKCPKeepaliveIsPreserved(t *testing.T) {
	k := &KCP{Block_: "none", Smuxkalive_: 22, Smuxktimeout_: 75}
	k.setDefaults("client")
	if errs := k.validate(); len(errs) != 0 {
		t.Fatalf("explicit KCP config rejected: %v", errs)
	}
	if k.Smuxkalive != 22*time.Second || k.Smuxktimeout != 75*time.Second {
		t.Fatalf("explicit keepalive changed: interval=%s timeout=%s", k.Smuxkalive, k.Smuxktimeout)
	}
}
