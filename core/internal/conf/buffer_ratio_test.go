package conf

import "testing"

// smuxbuf is a token bucket for the whole smux session; streambuf is the most
// one stream may hold. Unread bytes keep their tokens, so smuxbuf/streambuf is
// how many stalled streams it takes to empty the bucket - and an empty bucket
// stops smux reading the outer connection for every user on it, not only for
// the stalled ones.
//
// Measured with 20 active streams sharing one session, throughput of the active
// streams as stalled streams were added:
//
//	8 MiB / 4 MiB      1 stalled: 99%    2 stalled: 0%    6 stalled: 0%
//	8 MiB / 512 KiB    1 stalled: 97%    2 stalled: 96%   6 stalled: 99%
//
// The old 2:1 default froze everyone behind two paused downloads. This test
// exists so raising streambuf for single-flow speed cannot quietly walk back
// into that: if the ratio has to change, change it here deliberately and say
// why.
const minSessionStallTolerance = 16

func TestDefaultBuffersSurviveStalledStreams(t *testing.T) {
	if defaultStreambuf > defaultSmuxbuf/minSessionStallTolerance {
		t.Fatalf("defaults let %d stalled streams empty the session bucket (want at least %d): smuxbuf=%d streambuf=%d",
			defaultSmuxbuf/defaultStreambuf, minSessionStallTolerance,
			defaultSmuxbuf, defaultStreambuf)
	}
}

// A config that sets only one of the two keys still gets a safe pair, because
// setDefaults fills the other from the constants above.
func TestPartialBufferConfigStillGetsASafeRatio(t *testing.T) {
	for _, tc := range []struct {
		name      string
		smuxbuf   int
		streambuf int
	}{
		{"neither set", 0, 0},
		{"only smuxbuf set", 8 * 1024 * 1024, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tls := &TLS{Mode: "h2", Smuxbuf: tc.smuxbuf, Streambuf: tc.streambuf}
			tls.setDefaults()
			if tls.Streambuf > tls.Smuxbuf/minSessionStallTolerance {
				t.Fatalf("resolved to smuxbuf=%d streambuf=%d, a %d:1 ratio",
					tls.Smuxbuf, tls.Streambuf, tls.Smuxbuf/tls.Streambuf)
			}
		})
	}
}
