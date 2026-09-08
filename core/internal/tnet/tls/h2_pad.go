package tls

import (
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"sync"
)

// Hiding the shape of the traffic, not only its contents.
//
// TLS settles what is inside a record and says nothing about how long the
// record is, and on a stream an observer cannot read, length and timing are all
// that is left to work with. Measured on an idle h2 tunnel before this existed,
// the wire carried a TLS record of *exactly 39 bytes* every few seconds, in
// alternating directions, for as long as the connection lived: 5 bytes of TLS
// header, a 9-byte HTTP/2 DATA header, an 8-byte smux keepalive, the AEAD tag.
// Twelve of the sixteen records after the handshake were that same length.
//
// A constant-size heartbeat forever on a long-lived HTTPS connection is not
// what a browser talking to a website looks like, and it does not need to be
// decrypted to be counted. So each record carries a random amount of filler,
// which moves the length without changing anything the peer reads.
//
// Two decisions about where the filler goes:
//
// It is *inside* the encryption. Padding an observer can find and subtract is
// not padding, so the length byte and the filler are both under the TLS AEAD;
// all that reaches the wire is a record whose size moved.
//
// It is only added to small records. A bulk transfer already fills records to
// the maximum and looks like every other download; padding those would cost
// throughput to hide nothing. The tell is in the small frames, so that is where
// the filler goes.
//
// The filler itself is left as zeroes. It is encrypted before it is sent, so its
// content is already indistinguishable from anything else; only its *length*
// has to be unpredictable, and that is what is drawn.
//
// This changes the bytes between the two smux endpoints, so both ends must
// agree. It is off unless `padding: true` is set on the server and the client;
// a mismatch desynchronises the framing and the session drops rather than
// degrading quietly, in the same way a `smux_version` mismatch does.
const (
	padHeaderSize = 3     // padLen(1) + payloadLen(2)
	padMaxChunk   = 16384 // most payload one record carries
	padMaxFiller  = 255
	// padSmallFrame is the size below which a record is worth padding. smux
	// keepalives, window updates and stream control frames all sit far under
	// it; a data frame carrying real payload sits far above.
	padSmallFrame = 512
)

// paddedConn wraps the cover stream in a record layer that varies its lengths.
type paddedConn struct {
	net.Conn

	writeMu sync.Mutex
	wbuf    []byte

	readMu  sync.Mutex
	hdr     [padHeaderSize]byte
	rbuf    []byte // reusable record buffer
	pending []byte // decoded payload not yet handed to the caller

	fillerMu  sync.Mutex
	fillerBuf [256]byte
	fillerAt  int
}

func newPaddedConn(inner net.Conn) *paddedConn {
	c := &paddedConn{Conn: inner}
	c.fillerAt = len(c.fillerBuf) // force a refill on first use
	return c
}

// fillerLen draws the next filler length.
//
// It has to be unpredictable, not merely varied: an observer who can guess the
// length can subtract it again and recover the true record size, which is the
// whole thing this is hiding. Bytes are drawn from crypto/rand in blocks so the
// cost is one syscall per few hundred records rather than one per record.
func (c *paddedConn) fillerLen() int {
	c.fillerMu.Lock()
	defer c.fillerMu.Unlock()
	if c.fillerAt >= len(c.fillerBuf) {
		if _, err := io.ReadFull(rand.Reader, c.fillerBuf[:]); err != nil {
			// Padding is a traffic-analysis defence, not a security boundary.
			// If the pool cannot be refilled the connection must still work.
			return 0
		}
		c.fillerAt = 0
	}
	n := int(c.fillerBuf[c.fillerAt])
	c.fillerAt++
	return n
}

func (c *paddedConn) Write(p []byte) (int, error) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()

	written := 0
	for len(p) > 0 {
		chunk := p
		if len(chunk) > padMaxChunk {
			chunk = chunk[:padMaxChunk]
		}
		filler := 0
		if len(chunk) < padSmallFrame {
			filler = c.fillerLen()
		}

		need := padHeaderSize + len(chunk) + filler
		if cap(c.wbuf) < need {
			c.wbuf = make([]byte, need)
		}
		c.wbuf = c.wbuf[:need]
		c.wbuf[0] = byte(filler)
		binary.BigEndian.PutUint16(c.wbuf[1:3], uint16(len(chunk)))
		copy(c.wbuf[padHeaderSize:], chunk)
		// The filler is reused across records, so it has to be cleared rather
		// than left holding the tail of an earlier record's plaintext.
		clear(c.wbuf[padHeaderSize+len(chunk):])

		if _, err := c.Conn.Write(c.wbuf); err != nil {
			return written, err
		}
		written += len(chunk)
		p = p[len(chunk):]
	}
	return written, nil
}

func (c *paddedConn) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	c.readMu.Lock()
	defer c.readMu.Unlock()

	// A record may be nothing but filler, so keep reading until one carries
	// payload. Returning (0, nil) instead would look like a broken reader.
	for len(c.pending) == 0 {
		if _, err := io.ReadFull(c.Conn, c.hdr[:]); err != nil {
			return 0, err
		}
		filler := int(c.hdr[0])
		size := int(binary.BigEndian.Uint16(c.hdr[1:3]))
		if size > padMaxChunk {
			return 0, fmt.Errorf("h2 pad: record claims %d payload bytes, limit is %d", size, padMaxChunk)
		}
		need := size + filler
		if cap(c.rbuf) < need {
			c.rbuf = make([]byte, need)
		}
		c.rbuf = c.rbuf[:need]
		if _, err := io.ReadFull(c.Conn, c.rbuf); err != nil {
			return 0, err
		}
		// Safe to alias the reusable buffer: another record is only read once
		// this one has been handed over in full.
		c.pending = c.rbuf[:size]
	}

	n := copy(p, c.pending)
	c.pending = c.pending[n:]
	return n, nil
}
