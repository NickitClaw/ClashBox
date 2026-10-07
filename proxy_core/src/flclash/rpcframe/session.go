package rpcframe

import (
	"net"
	"sync"
	"time"
)

// Session owns response writes until the asynchronous result, timeout or peer
// disconnect. A handler returning is not a signal to close its connection.
type Session struct {
	conn net.Conn
	mu   sync.Mutex
	once sync.Once
	done chan struct{}
}

func NewSession(conn net.Conn) *Session {
	return &Session{conn: conn, done: make(chan struct{})}
}

func (s *Session) Done() <-chan struct{} { return s.done }
func (s *Session) Finish()               { s.once.Do(func() { close(s.done) }) }

// Invoke only after reading the complete request; one request per connection.
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
	err := Write(s.conn, payload)
	if err != nil || final {
		s.Finish()
	}
	return err
}

func (s *Session) Close() {
	s.Finish()
	s.mu.Lock()
	defer s.mu.Unlock()
	_ = s.conn.Close()
}
