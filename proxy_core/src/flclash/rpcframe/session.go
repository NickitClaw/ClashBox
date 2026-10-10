package rpcframe

import (
	"net"
	"sync"
	"time"
)

// Session owns response writes until the asynchronous result, timeout or peer
// disconnect. A handler returning is not a signal to close its connection.
type Session struct {
	conn  net.Conn
	mu    sync.Mutex
	once  sync.Once
	done  chan struct{}
	final bool
}

func NewSession(conn net.Conn) *Session {
	return &Session{conn: conn, done: make(chan struct{})}
}

func (s *Session) Done() <-chan struct{} { return s.done }
func (s *Session) Finish()               { s.once.Do(func() { close(s.done) }) }

// Invoke only after reading the complete request; one request per connection.
// The peer sends 0x06 after consuming the final response (or to cancel a stream),
// then waits for server EOF before releasing its LocalSocket descriptor. EOF
// from older peers is still accepted; any extra request data ends the session.
func (s *Session) WatchDisconnect() {
	go func() { var b [1]byte; _, _ = s.conn.Read(b[:]); s.Finish() }()
}

func (s *Session) Send(payload []byte, final bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	select {
	case <-s.done:
		return net.ErrClosed
	default:
	}
	_ = s.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if s.final {
		return net.ErrClosed
	}
	err := Write(s.conn, payload)
	if err != nil {
		s.Finish()
	} else if final {
		s.final = true
		// Wait for the receipt before closing: a successful write does not mean
		// ArkTS dispatched its message callback. Bound peers that never reply.
		_ = s.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	}
	return err
}

func (s *Session) Close() {
	s.Finish()
	s.mu.Lock()
	defer s.mu.Unlock()
	_ = s.conn.Close()
}
