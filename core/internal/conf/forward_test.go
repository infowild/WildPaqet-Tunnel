package conf

import "testing"

func TestForwardSetupLimits(t *testing.T) {
	f := Forward{Listen_: "127.0.0.1:8080", Target: "127.0.0.1:8081"}
	f.setDefaults()
	if errs := f.validate(); len(errs) != 0 {
		t.Fatal(errs)
	}
	if f.MaxPending != 256 || f.ConnectTimeout.Seconds() != 15 {
		t.Fatal("missing setup defaults")
	}
	f.MaxPending = -1
	if errs := f.validate(); len(errs) == 0 {
		t.Fatal("negative admission limit accepted")
	}
	f.MaxPending = 256
	f.ConnectTimeoutSeconds = 121
	if errs := f.validate(); len(errs) == 0 {
		t.Fatal("unbounded setup accepted")
	}
}
