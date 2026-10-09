package regression

import (
	"bytes"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/netip"
	"os"
	"testing"
	"time"

	N "github.com/metacubex/mihomo/common/net"
	"github.com/metacubex/mihomo/component/sniffer"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	S "github.com/metacubex/mihomo/constant/sniffer"
	// Supplies the core config parser's temporaryUpdateGeneral linkname target.
	_ "github.com/metacubex/mihomo/hub/executor"
)

// Capture a real Go TLS ClientHello without making any network connection.
type helloRecorder struct {
	net.Conn
	hello []byte
}

func (c *helloRecorder) Write(p []byte) (int, error) {
	c.hello = bytes.Clone(p)
	return len(p), io.ErrClosedPipe
}

func clientHello(t *testing.T, host string) []byte {
	t.Helper()
	c := &helloRecorder{}
	_ = tls.Client(c, &tls.Config{ServerName: host, InsecureSkipVerify: true}).Handshake()
	if len(c.hello) == 0 {
		t.Fatal("TLS client did not emit ClientHello")
	}
	return c.hello
}

func TestTLSDestinationRecovery(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	data, err := os.ReadFile(os.Getenv("CLASHBOX_SNIFFER_FIXTURES"))
	if err != nil {
		t.Fatal(err)
	}
	var settings map[string]config.RawSniffer
	if err := json.Unmarshal(data, &settings); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, settings, host, src, dst string
		port                           uint16
		sniffed, replaced, optOut      bool
	}{
		{"legacy retains stale IP", "legacy", "m.youtube.com", "172.19.0.1", "104.244.42.197", 443, true, false, false},
		{"fresh corrects stale IP", "fresh", "m.youtube.com", "172.19.0.1", "104.244.42.197", 443, true, true, false},
		{"migrated corrects stale IP", "migrated", "m.youtube.com", "172.19.0.1", "104.244.42.197", 443, true, true, false},
		{"alternate TLS port", "fresh", "example.com", "172.19.0.1", "192.0.2.1", 8443, true, true, false},
		{"explicit opt out", "fresh", "m.youtube.com", "172.19.0.1", "104.244.42.197", 443, true, false, true},
		{"skipped domain", "fresh", "api.push.apple.com", "172.19.0.1", "192.0.2.1", 443, false, false, false},
		{"skipped source", "fresh", "m.youtube.com", "192.168.0.3", "104.244.42.197", 443, false, false, false},
		{"skipped destination", "fresh", "m.youtube.com", "172.19.0.1", "91.108.4.1", 443, false, false, false},
		{"unlisted port", "fresh", "m.youtube.com", "172.19.0.1", "104.244.42.197", 9443, false, false, false},
		{"no SNI", "fresh", "", "172.19.0.1", "104.244.42.197", 443, false, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// Deserialize each time: RawSniffer contains a map modified by the opt-out case.
			if err := json.Unmarshal(data, &settings); err != nil {
				t.Fatal(err)
			}
			raw := config.DefaultRawConfig()
			raw.Sniffer = settings[tc.settings]
			if tc.optOut {
				policy := raw.Sniffer.Sniff["TLS"]
				value := false
				policy.OverrideDest = &value
				raw.Sniffer.Sniff["TLS"] = policy
			}
			parsed, err := config.ParseRawConfig(raw)
			if err != nil {
				t.Fatal(err)
			}
			if parsed.Sniffer.Sniffers[S.QUIC].OverrideDest {
				t.Fatal("TLS fix unexpectedly enabled QUIC destination override")
			}
			dispatcher, err := sniffer.NewDispatcher(parsed.Sniffer)
			if err != nil {
				t.Fatal(err)
			}
			payload := clientHello(t, tc.host)
			reader, writer := net.Pipe()
			defer reader.Close()
			defer writer.Close()
			_ = reader.SetDeadline(time.Now().Add(3 * time.Second))
			_ = writer.SetDeadline(time.Now().Add(3 * time.Second))
			go func() { _, _ = writer.Write(payload); _ = writer.Close() }()
			conn := N.NewBufferedConn(reader)
			metadata := &C.Metadata{NetWork: C.TCP, SrcIP: netip.MustParseAddr(tc.src),
				DstIP: netip.MustParseAddr(tc.dst), DstPort: tc.port}
			if got := dispatcher.TCPSniff(conn, metadata); got != tc.sniffed {
				t.Fatalf("sniffed = %v, want %v", got, tc.sniffed)
			}
			if tc.replaced {
				if metadata.Host != tc.host || metadata.DstIP.IsValid() {
					t.Fatalf("stale destination survived: host=%q ip=%v", metadata.Host, metadata.DstIP)
				}
			} else if metadata.Host != "" || metadata.DstIP.String() != tc.dst {
				t.Fatalf("destination changed despite opt-out/exception: %+v", metadata)
			}
			remaining, err := io.ReadAll(conn)
			if err != nil || !bytes.Equal(remaining, payload) {
				t.Fatalf("sniffing consumed or altered ClientHello: err=%v", err)
			}
		})
	}
}
