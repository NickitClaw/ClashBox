package integration_test

import (
	"context"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
)

func TestSocketHookPreparedDialCannotUseStoppedOrReplacementVPN(t *testing.T) {
	defer dialer.SetSocketHook(nil)
	for _, replace := range []bool{false, true} {
		var calls atomic.Int32
		dialer.SetSocketHook(func(_, _ string, _ syscall.RawConn) error { calls.Add(1); return nil })
		entered, release := make(chan struct{}), make(chan struct{})
		result := make(chan error, 1)
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			conn, err := dialer.DialContext(ctx, "tcp4", "127.0.0.1:1", dialer.WithNetDialer(&net.Dialer{
				ControlContext: func(context.Context, string, string, syscall.RawConn) error {
					close(entered)
					<-release
					return nil
				},
			}))
			if conn != nil {
				conn.Close()
			}
			result <- err
		}()
		<-entered
		dialer.SetSocketHook(nil)
		if replace {
			dialer.SetSocketHook(func(_, _ string, _ syscall.RawConn) error { calls.Add(1); return nil })
		}
		close(release)
		if err := <-result; !errors.Is(err, dialer.ErrSocketHookExpired) {
			t.Fatalf("stale dial: %v", err)
		}
		if calls.Load() != 0 {
			t.Fatal("stale dial invoked a protect callback")
		}
	}
}

func TestSocketHookConcurrentPublicationAndCallbackCompletion(t *testing.T) {
	defer dialer.SetSocketHook(nil)
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				dialer.SetSocketHook(func(_, _ string, _ syscall.RawConn) error { return nil })
				if hook := dialer.GetSocketHook(); hook != nil {
					_ = hook("tcp", "", nil)
				}
				dialer.SetSocketHook(nil)
			}
		}()
	}
	wg.Wait()
	entered, release, completed := make(chan struct{}), make(chan struct{}), make(chan struct{})
	dialer.SetSocketHook(func(_, _ string, _ syscall.RawConn) error { close(entered); <-release; close(completed); return nil })
	hook := dialer.GetSocketHook()
	go hook("tcp", "", nil)
	<-entered
	go func() { close(release) }()
	dialer.SetSocketHook(nil)
	select {
	case <-completed:
	default:
		t.Fatal("stop returned before active callback completed")
	}
}
