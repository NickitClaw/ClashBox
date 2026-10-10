package rpcframe

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

type shortWriter struct{ bytes.Buffer }

func (w *shortWriter) Write(p []byte) (int, error) {
	if len(p) > 3 {
		p = p[:3]
	}
	return w.Buffer.Write(p)
}
func TestLargeFragmentedRoundTrip(t *testing.T) {
	payload := []byte(`{"result":"` + strings.Repeat("节点EOF😀", 8192) + `"}`)
	var wire shortWriter
	if err := Write(&wire, payload); err != nil {
		t.Fatal(err)
	}
	decoded, err := Read(&wire)
	if err != nil || !bytes.Equal(decoded, payload) {
		t.Fatalf("roundtrip failed: %v", err)
	}
}
func TestCoalescedFrames(t *testing.T) {
	var wire bytes.Buffer
	for _, s := range []string{"first", "第二帧EOF"} {
		if err := Write(&wire, []byte(s)); err != nil {
			t.Fatal(err)
		}
	}
	for _, want := range []string{"first", "第二帧EOF"} {
		got, err := Read(&wire)
		if err != nil || string(got) != want {
			t.Fatalf("got %q, %v", got, err)
		}
	}
}
func TestTruncationAndLimits(t *testing.T) {
	var wire bytes.Buffer
	_ = Write(&wire, []byte("payload"))
	frame := wire.Bytes()
	for n := 0; n < len(frame); n++ {
		if _, err := Read(bytes.NewReader(frame[:n])); err == nil {
			t.Fatalf("accepted %d bytes", n)
		}
	}
	for _, size := range []uint32{0, MaxSize + 1, ^uint32(0)} {
		var h [4]byte
		binary.BigEndian.PutUint32(h[:], size)
		if _, err := Read(bytes.NewReader(h[:])); err == nil {
			t.Fatal("accepted invalid length")
		}
	}
	if err := Write(io.Discard, make([]byte, MaxSize+1)); err == nil {
		t.Fatal("accepted oversize write")
	}
}
func TestDelayedResponseOverFragmentedConnection(t *testing.T) {
	server, client := net.Pipe()
	defer client.Close()
	result := make(chan error, 1)
	go func() {
		defer server.Close()
		payload, err := Read(server)
		if err != nil {
			result <- err
			return
		}
		time.Sleep(10 * time.Millisecond)
		result <- Write(server, payload)
	}()
	_ = client.SetDeadline(time.Now().Add(time.Second))
	var frame bytes.Buffer
	_ = Write(&frame, []byte(strings.Repeat("x", 64*1024)))
	for _, b := range frame.Bytes() {
		if _, err := client.Write([]byte{b}); err != nil {
			t.Fatal(err)
		}
	}
	response, err := Read(client)
	if err != nil || len(response) != 64*1024 {
		t.Fatalf("missing async response: %v", err)
	}
	if err := <-result; err != nil {
		t.Fatal(err)
	}
}

func TestAsyncSessionKeepsConnectionUntilCallback(t *testing.T) {
	server, client := net.Pipe()
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(time.Second))
	session := NewSession(server)
	session.WatchDisconnect()
	callback := func() { _ = session.Send([]byte(`{"result":"delayed"}`), true) }
	// Dispatch has returned, but its callback has not executed yet.
	go func() { time.Sleep(10 * time.Millisecond); callback() }()
	go func() { <-session.Done(); session.Close() }()
	result, err := Read(client)
	if err != nil || string(result) != `{"result":"delayed"}` {
		t.Fatalf("async result lost: %q %v", result, err)
	}
	if err := session.Send([]byte("late callback"), true); err == nil {
		t.Fatal("accepted a callback after final response")
	}
}

func TestStreamSessionDisconnectCancelsLateCallbacks(t *testing.T) {
	server, client := net.Pipe()
	session := NewSession(server)
	defer session.Close()
	session.WatchDisconnect()
	_ = client.SetDeadline(time.Now().Add(time.Second))
	sent := make(chan error, 1)
	go func() {
		for _, frame := range []string{"first", "第二帧"} {
			if err := session.Send([]byte(frame), false); err != nil {
				sent <- err
				return
			}
		}
		sent <- nil
	}()
	for _, want := range []string{"first", "第二帧"} {
		got, err := Read(client)
		if err != nil || string(got) != want {
			t.Fatalf("stream result %q %v", got, err)
		}
	}
	if err := <-sent; err != nil {
		t.Fatal(err)
	}
	_ = client.Close()
	select {
	case <-session.Done():
	case <-time.After(time.Second):
		t.Fatal("disconnect was not observed")
	}
	if err := session.Send([]byte("late"), false); err == nil {
		t.Fatal("late callback wrote to closed peer")
	}
}

func TestFinalResponseWaitsForPeerClose(t *testing.T) {
	server, client := net.Pipe()
	defer client.Close()
	_ = client.SetDeadline(time.Now().Add(time.Second))
	session := NewSession(server)
	defer session.Close()
	session.WatchDisconnect()
	sent := make(chan error, 1)
	go func() { sent <- session.Send([]byte(`{"result":"complete"}`), true) }()
	if _, err := Read(client); err != nil {
		t.Fatal(err)
	}
	if err := <-sent; err != nil {
		t.Fatal(err)
	}
	// Native recv may finish before ArkTS dispatches its queued message event.
	// A successful write is not permission to publish a close event first.
	select {
	case <-session.Done():
		t.Fatal("server closed before the peer consumed the response")
	default:
	}
	if err := session.Send([]byte("duplicate response"), true); err == nil {
		t.Fatal("accepted a second final response")
	}
	_ = client.Close()
	select {
	case <-session.Done():
	case <-time.After(time.Second):
		t.Fatal("client acknowledgement did not release session")
	}
}

type shortReadDeadlineConn struct {
	net.Conn
	deadline time.Time
}

func TestReceiptClosesServerBeforeClientReleasesDescriptor(t *testing.T) {
	for _, final := range []bool{true, false} {
		t.Run(fmt.Sprintf("final=%v", final), func(t *testing.T) {
			server, client := net.Pipe()
			defer client.Close()
			_ = client.SetDeadline(time.Now().Add(time.Second))
			session := NewSession(server)
			defer session.Close()
			session.WatchDisconnect()
			go func() { <-session.Done(); session.Close() }()
			sent := make(chan error, 1)
			go func() { sent <- session.Send([]byte("result"), final) }()
			if _, err := Read(client); err != nil {
				t.Fatal(err)
			}
			if err := <-sent; err != nil {
				t.Fatal(err)
			}
			select {
			case <-session.Done():
				t.Fatal("server closed before ArkTS consumed the response")
			default:
			}
			if _, err := client.Write([]byte{0x06}); err != nil {
				t.Fatal(err)
			}
			var b [1]byte
			if _, err := client.Read(b[:]); err != io.EOF {
				t.Fatalf("expected server EOF while client is still open, got %v", err)
			}
			if err := session.Send([]byte("late"), final); err == nil {
				t.Fatal("accepted a callback after receipt/cancellation")
			}
		})
	}
}

func (c *shortReadDeadlineConn) SetReadDeadline(deadline time.Time) error {
	c.deadline = deadline
	return c.Conn.SetReadDeadline(time.Now().Add(20 * time.Millisecond))
}

func TestFinalResponseReleasesUnresponsivePeer(t *testing.T) {
	server, client := net.Pipe()
	defer client.Close()
	conn := &shortReadDeadlineConn{Conn: server}
	session := NewSession(conn)
	defer session.Close()
	session.WatchDisconnect()
	sent := make(chan error, 1)
	go func() { sent <- session.Send([]byte("result"), true) }()
	if _, err := Read(client); err != nil {
		t.Fatal(err)
	}
	if err := <-sent; err != nil {
		t.Fatal(err)
	}
	if remaining := time.Until(conn.deadline); remaining <= 0 || remaining > 5*time.Second {
		t.Fatalf("unbounded or expired peer acknowledgement deadline: %v", remaining)
	}
	select {
	case <-session.Done():
	case <-time.After(time.Second):
		t.Fatal("unresponsive peer leaked the session")
	}
}
