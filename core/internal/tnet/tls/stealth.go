package tls

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"github.com/flynn/noise"
	"golang.org/x/crypto/hkdf"
)

// The stealth carrier: a tunnel that looks like nothing at all.
//
// The h2 cover answers the question "what is this connection?" with a plausible
// lie - a browser talking to a website. That is the right answer where a censor
// classifies traffic and blocks what it does not recognise. It is the wrong
// answer where the connection is being filtered rather than fingerprinted: a
// route that throttles or resets a long-lived flow to a foreign address does
// not care how convincing the TLS is.
//
// So this carrier gives no answer. The handshake is Noise NNpsk0, which puts
// two short messages on the wire that are indistinguishable from random bytes,
// and the stream that follows is a ChaCha20-Poly1305 record layer that looks
// the same. There is no ClientHello, no certificate, no version number and no
// recognisable framing - nothing for pattern matching to hold on to.
//
// The pre-shared key comes from the tunnel secret both ends already share, so
// this needs no key material of its own. Because NNpsk0 mixes that key in from
// the very first message, a peer without the secret cannot produce a message
// the responder will accept: the responder drops it and replies with nothing,
// so a port scan finds a dead port rather than a service to probe. That is the
// opposite trade from the h2 cover, which answers every probe on purpose.
//
// Honest limits, because this is not strictly better than the h2 cover:
//
//   - Traffic with no recognisable protocol is itself a category. A censor that
//     allows known protocols and blocks the rest sees unstructured bytes on
//     port 443 and can act on exactly that. Where the h2 cover still works, it
//     is the better answer.
//   - There is no cover story to fall back on. A probe gets silence, which is
//     unremarkable for a closed port and odd for one a scan already found open.
//
// Both ends must run this carrier; there is nothing to negotiate and a peer
// speaking anything else simply fails the handshake.

const (
	// stealthPrologue binds the handshake transcript to this application. It
	// never travels on the wire - both ends mix it in and must agree - so a
	// handshake captured elsewhere cannot be replayed into this one.
	stealthPrologue = "wildpaqet-stealth-v1"

	// stealthMaxChunk is the most plaintext one record carries. Well under the
	// 65535-byte Noise message ceiling, and a size that keeps buffers small.
	stealthMaxChunk = 16384

	// stealthMaxFiller is the most filler a record can carry. A byte's worth is
	// enough that a record's length says little about its payload, and cheap
	// enough that the average cost is noise next to a full-sized record.
	stealthMaxFiller = 255

	stealthHeaderSize = 2 // big-endian length of the Noise message that follows
	stealthMaxMessage = stealthMaxChunk + 1 + stealthMaxFiller + 16
)

// stealthSuite is fixed rather than negotiated. One good choice both ends
// assume needs nothing on the wire, and a negotiation is one more thing to
// fingerprint.
var stealthSuite = noise.NewCipherSuite(noise.DH25519, noise.CipherChaChaPoly, noise.HashBLAKE2s)

// stealthPSK turns the tunnel secret into the 32-byte pre-shared key.
func stealthPSK(secret string) ([]byte, error) {
	psk := make([]byte, 32)
	r := hkdf.New(sha256.New, []byte(secret), []byte("wildpaqet-stealth-psk-v1"), nil)
	if _, err := io.ReadFull(r, psk); err != nil {
		return nil, fmt.Errorf("stealth: derive pre-shared key: %w", err)
	}
	return psk, nil
}

// stealthHandshake runs NNpsk0 over raw and returns an encrypted net.Conn.
//
// A responder that cannot decrypt the first message returns an error without
// having written anything, which is what makes the port look dead.
func stealthHandshake(raw net.Conn, secret string, initiator bool, timeout time.Duration) (net.Conn, error) {
	psk, err := stealthPSK(secret)
	if err != nil {
		return nil, err
	}
	hs, err := noise.NewHandshakeState(noise.Config{
		CipherSuite:           stealthSuite,
		Random:                rand.Reader,
		Pattern:               noise.HandshakeNN,
		Initiator:             initiator,
		Prologue:              []byte(stealthPrologue),
		PresharedKey:          psk,
		PresharedKeyPlacement: 0,
	})
	if err != nil {
		return nil, fmt.Errorf("stealth: handshake setup: %w", err)
	}

	if timeout > 0 {
		if err := raw.SetDeadline(time.Now().Add(timeout)); err != nil {
			return nil, fmt.Errorf("stealth: set handshake deadline: %w", err)
		}
	}

	var send, recv *noise.CipherState
	if initiator {
		msg, _, _, err := hs.WriteMessage(nil, nil)
		if err != nil {
			return nil, fmt.Errorf("stealth: build first message: %w", err)
		}
		if err := writeStealthFrame(raw, msg); err != nil {
			return nil, fmt.Errorf("stealth: send first message: %w", err)
		}
		reply, err := readStealthFrame(raw)
		if err != nil {
			return nil, fmt.Errorf("stealth: read reply: %w", err)
		}
		if _, send, recv, err = hs.ReadMessage(nil, reply); err != nil {
			return nil, fmt.Errorf("stealth: reply did not authenticate: %w", err)
		}
	} else {
		first, err := readStealthFrame(raw)
		if err != nil {
			return nil, fmt.Errorf("stealth: read first message: %w", err)
		}
		// Nothing is written back on failure: a peer without the secret must
		// see silence, not an error it can fingerprint.
		if _, _, _, err = hs.ReadMessage(nil, first); err != nil {
			return nil, fmt.Errorf("stealth: first message did not authenticate: %w", err)
		}
		msg, recvCS, sendCS, err := hs.WriteMessage(nil, nil)
		if err != nil {
			return nil, fmt.Errorf("stealth: build reply: %w", err)
		}
		if err := writeStealthFrame(raw, msg); err != nil {
			return nil, fmt.Errorf("stealth: send reply: %w", err)
		}
		// WriteMessage always returns the initiator's sending state first, so
		// the responder's own directions are the other way round.
		send, recv = sendCS, recvCS
	}

	if timeout > 0 {
		if err := raw.SetDeadline(time.Time{}); err != nil {
			return nil, fmt.Errorf("stealth: clear handshake deadline: %w", err)
		}
	}
	return &stealthConn{Conn: raw, send: send, recv: recv}, nil
}

// stealthConn is the record layer over a completed handshake.
type stealthConn struct {
	net.Conn

	writeMu sync.Mutex
	send    *noise.CipherState
	plain   []byte
	sealed  []byte

	readMu  sync.Mutex
	recv    *noise.CipherState
	pending []byte

	fillerMu  sync.Mutex
	fillerBuf [256]byte
	fillerAt  int
}

// fillerLen draws the next filler length. It must be unpredictable rather than
// merely varied: an observer who can guess it can subtract it again and recover
// the true record size, which is what the filler exists to hide.
func (c *stealthConn) fillerLen() int {
	c.fillerMu.Lock()
	defer c.fillerMu.Unlock()
	if c.fillerAt >= len(c.fillerBuf) {
		if _, err := io.ReadFull(rand.Reader, c.fillerBuf[:]); err != nil {
			return 0
		}
		c.fillerAt = 0
	}
	n := int(c.fillerBuf[c.fillerAt])
	c.fillerAt++
	return n
}

func (c *stealthConn) Write(p []byte) (int, error) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	written := 0
	for len(p) > 0 {
		chunk := p
		if len(chunk) > stealthMaxChunk {
			chunk = chunk[:stealthMaxChunk]
		}
		filler := c.fillerLen()

		need := 1 + len(chunk) + filler
		if cap(c.plain) < need {
			c.plain = make([]byte, need)
		}
		c.plain = c.plain[:need]
		c.plain[0] = byte(filler)
		copy(c.plain[1:], chunk)
		// The buffer is reused, so the filler has to be cleared rather than
		// left holding the tail of an earlier record's plaintext.
		clear(c.plain[1+len(chunk):])

		sealed, err := c.send.Encrypt(c.sealed[:0], nil, c.plain)
		if err != nil {
			return written, fmt.Errorf("stealth: encrypt: %w", err)
		}
		c.sealed = sealed
		if err := writeStealthFrame(c.Conn, sealed); err != nil {
			return written, err
		}
		written += len(chunk)
		p = p[len(chunk):]
	}
	return written, nil
}

func (c *stealthConn) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	c.readMu.Lock()
	defer c.readMu.Unlock()

	// A record may be nothing but filler, so keep going until one carries
	// payload rather than returning a bare (0, nil).
	for len(c.pending) == 0 {
		msg, err := readStealthFrame(c.Conn)
		if err != nil {
			return 0, err
		}
		plain, err := c.recv.Decrypt(nil, nil, msg)
		if err != nil {
			return 0, fmt.Errorf("stealth: decrypt: %w", err)
		}
		if len(plain) < 1 {
			return 0, fmt.Errorf("stealth: record carries no length byte")
		}
		filler := int(plain[0])
		if 1+filler > len(plain) {
			return 0, fmt.Errorf("stealth: record claims %d bytes of filler in %d", filler, len(plain))
		}
		c.pending = plain[1 : len(plain)-filler]
	}

	n := copy(p, c.pending)
	c.pending = c.pending[n:]
	return n, nil
}

func writeStealthFrame(w io.Writer, msg []byte) error {
	if len(msg) > stealthMaxMessage {
		return fmt.Errorf("stealth: message of %d bytes exceeds the %d-byte limit", len(msg), stealthMaxMessage)
	}
	var hdr [stealthHeaderSize]byte
	binary.BigEndian.PutUint16(hdr[:], uint16(len(msg)))
	if _, err := w.Write(append(hdr[:], msg...)); err != nil {
		return err
	}
	return nil
}

func readStealthFrame(r io.Reader) ([]byte, error) {
	var hdr [stealthHeaderSize]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return nil, err
	}
	n := int(binary.BigEndian.Uint16(hdr[:]))
	if n > stealthMaxMessage {
		return nil, fmt.Errorf("stealth: frame of %d bytes exceeds the %d-byte limit", n, stealthMaxMessage)
	}
	msg := make([]byte, n)
	if _, err := io.ReadFull(r, msg); err != nil {
		return nil, err
	}
	return msg, nil
}
