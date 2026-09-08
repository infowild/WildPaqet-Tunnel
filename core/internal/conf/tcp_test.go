package conf

import "testing"

func resolve(t *testing.T, preset string) *TCP {
	t.Helper()
	tcp := &TCP{Preset_: preset}
	tcp.setDefaults()
	if errs := tcp.validate(); len(errs) != 0 {
		t.Fatalf("preset %q rejected: %v", preset, errs)
	}
	return tcp
}

// Configs already deployed in the field carry no preset, "default" or the older
// "restrictive"; all three must keep validating and land on the hardened wire.
func TestDeployedPresetsStayValidAndHardened(t *testing.T) {
	for _, preset := range []string{"", "default", "restrictive"} {
		tcp := resolve(t, preset)
		if tcp.Handshake != "mimic" {
			t.Errorf("preset %q: handshake = %q, want mimic", preset, tcp.Handshake)
		}
		if !tcp.TrackSeq {
			t.Errorf("preset %q: track_seq disabled", preset)
		}
		if tcp.TOS != 0 {
			t.Errorf("preset %q: tos = %d, want 0 (no DSCP mark)", preset, tcp.TOS)
		}
	}
}

func TestLegacyPresetRestoresOldWire(t *testing.T) {
	tcp := resolve(t, "legacy")
	if tcp.Handshake != "none" {
		t.Errorf("handshake = %q, want none", tcp.Handshake)
	}
	if tcp.TrackSeq {
		t.Error("track_seq should be off for legacy")
	}
	if tcp.TOS != 184 {
		t.Errorf("tos = %d, want 184", tcp.TOS)
	}
}

func TestExplicitOverridesWinOverPreset(t *testing.T) {
	trackSeq := false
	tos := 72
	tcp := &TCP{Preset_: "default", TrackSeq_: &trackSeq, IPv4TOS_: &tos, Handshake_: "none"}
	tcp.setDefaults()
	if errs := tcp.validate(); len(errs) != 0 {
		t.Fatalf("unexpected errors: %v", errs)
	}
	if tcp.TrackSeq || tcp.Handshake != "none" || tcp.TOS != 72 {
		t.Errorf("overrides ignored: track_seq=%v handshake=%q tos=%d", tcp.TrackSeq, tcp.Handshake, tcp.TOS)
	}
}

func TestUnknownPresetIsRejected(t *testing.T) {
	tcp := &TCP{Preset_: "banana"}
	tcp.setDefaults()
	if errs := tcp.validate(); len(errs) == 0 {
		t.Error("expected an error for an unknown preset")
	}
}
