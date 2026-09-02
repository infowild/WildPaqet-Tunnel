package tls

import (
	"errors"
	"io"
	"sync"
)

// h2PipeBuffer is the amount of upload data that may sit between smux and the
// HTTP/2 writer. It is deliberately small: enough to keep both loops busy
// across one flow-control round trip, not enough to add queueing latency.
const h2PipeBuffer = 256 * 1024

var errPipeClosed = errors.New("h2: cover stream closed")

// bufferedPipe is an in-memory pipe with a bounded ring buffer.
//
// It replaces io.Pipe on the HTTP/2 request-body path. io.Pipe hands every
// write off synchronously, so smux's single sendLoop stayed blocked for the
// whole duration of each HTTP/2 DATA frame write - flow-control wait, TLS
// encryption and syscall included. Because that loop serialises every stream on
// the session, one upload stalling on the peer's receive window stopped all
// other streams on the same outer connection. A small buffer decouples them.
type bufferedPipe struct {
	mu       sync.Mutex
	notEmpty sync.Cond
	notFull  sync.Cond

	buf  []byte
	head int
	size int

	writeClosed bool
	writeErr    error
	readClosed  bool
	readErr     error
}

func newBufferedPipe(capacity int) *bufferedPipe {
	if capacity <= 0 {
		capacity = h2PipeBuffer
	}
	p := &bufferedPipe{buf: make([]byte, capacity)}
	p.notEmpty.L = &p.mu
	p.notFull.L = &p.mu
	return p
}

// push copies as much of b as currently fits. Caller holds p.mu.
func (p *bufferedPipe) push(b []byte) int {
	free := len(p.buf) - p.size
	if free > len(b) {
		free = len(b)
	}
	if free == 0 {
		return 0
	}
	tail := (p.head + p.size) % len(p.buf)
	n := copy(p.buf[tail:], b[:free])
	if n < free {
		n += copy(p.buf, b[n:free])
	}
	p.size += n
	return n
}

// pop copies as much buffered data as fits in b. Caller holds p.mu.
func (p *bufferedPipe) pop(b []byte) int {
	n := p.size
	if n > len(b) {
		n = len(b)
	}
	if n == 0 {
		return 0
	}
	c := copy(b[:n], p.buf[p.head:])
	if c < n {
		c += copy(b[c:n], p.buf)
	}
	p.head = (p.head + n) % len(p.buf)
	p.size -= n
	return n
}

func (p *bufferedPipe) Write(b []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	written := 0
	for len(b) > 0 {
		for p.size == len(p.buf) && !p.readClosed && !p.writeClosed {
			p.notFull.Wait()
		}
		if p.readClosed {
			return written, p.readErr
		}
		if p.writeClosed {
			return written, io.ErrClosedPipe
		}
		n := p.push(b)
		written += n
		b = b[n:]
		p.notEmpty.Broadcast()
	}
	return written, nil
}

func (p *bufferedPipe) Read(b []byte) (int, error) {
	if len(b) == 0 {
		return 0, nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	for {
		if p.readClosed {
			return 0, p.readErr
		}
		if p.size > 0 {
			n := p.pop(b)
			p.notFull.Broadcast()
			return n, nil
		}
		// Buffered data is drained before a closed write end reports EOF.
		if p.writeClosed {
			return 0, p.writeErr
		}
		p.notEmpty.Wait()
	}
}

func (p *bufferedPipe) closeWrite(err error) {
	if err == nil {
		err = io.EOF
	}
	p.mu.Lock()
	if !p.writeClosed {
		p.writeClosed = true
		p.writeErr = err
	}
	p.mu.Unlock()
	p.notEmpty.Broadcast()
	p.notFull.Broadcast()
}

func (p *bufferedPipe) closeRead(err error) {
	if err == nil {
		err = errPipeClosed
	}
	p.mu.Lock()
	if !p.readClosed {
		p.readClosed = true
		p.readErr = err
	}
	p.mu.Unlock()
	p.notEmpty.Broadcast()
	p.notFull.Broadcast()
}

// bufferedPipeReader is handed to net/http as the request body.
type bufferedPipeReader struct{ p *bufferedPipe }

func (r bufferedPipeReader) Read(b []byte) (int, error) { return r.p.Read(b) }
func (r bufferedPipeReader) Close() error               { r.p.closeRead(errPipeClosed); return nil }
func (r bufferedPipeReader) CloseWithError(err error) error {
	r.p.closeRead(err)
	return nil
}

// bufferedPipeWriter is the net.Conn write side handed to smux.
type bufferedPipeWriter struct{ p *bufferedPipe }

func (w bufferedPipeWriter) Write(b []byte) (int, error) { return w.p.Write(b) }
func (w bufferedPipeWriter) Close() error                { w.p.closeWrite(io.EOF); return nil }
func (w bufferedPipeWriter) CloseWithError(err error) error {
	w.p.closeWrite(err)
	return nil
}
