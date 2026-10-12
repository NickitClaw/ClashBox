package integration_test

import (
	"bytes"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"sync/atomic"
	"testing"

	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/metacubex/mihomo/component/updater"
	C "github.com/metacubex/mihomo/constant"
)

func TestMMDBAndASNUpdatesPreserveInFlightReadersAndFailedUpdates(t *testing.T) {
	_, source, _, _ := runtime.Caller(0)
	for _, asn := range []bool{false, true} {
		name := "geoip.metadb"
		if asn {
			name = "ASN.mmdb"
		}
		t.Run(name, func(t *testing.T) {
			C.SetHomeDir(t.TempDir())
			data, err := os.ReadFile(filepath.Join(filepath.Dir(source), "../entry/src/main/resources/resfile", name))
			if err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(C.Path.HomeDir(), name)
			install, update, periodic, setURL := mmdb.InstallIP, updater.UpdateMMDBWithPath, updater.UpdateMMDB, geodata.SetMmdbUrl
			lookup := func() string { return fmt.Sprint(mmdb.IPInstance().LookupCode(net.ParseIP("8.8.8.8"))) }
			if asn {
				install, update, periodic, setURL = mmdb.InstallASN, updater.UpdateASNWithPath, updater.UpdateASN, geodata.SetASNUrl
				lookup = func() string { a, b := mmdb.ASNInstance().LookupASN(net.ParseIP("8.8.8.8")); return a + b }
			}
			if err := install(path, data); err != nil {
				t.Fatal(err)
			}
			oldLookup := func() string { return "" }
			if asn {
				r := mmdb.ASNInstance()
				oldLookup = func() string { a, b := r.LookupASN(net.ParseIP("8.8.8.8")); return a + b }
			} else {
				r := mmdb.IPInstance()
				oldLookup = func() string { return fmt.Sprint(r.LookupCode(net.ParseIP("8.8.8.8"))) }
			}
			expected := oldLookup()
			var response atomic.Value
			response.Store(data)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.Write(response.Load().([]byte)) }))
			defer server.Close()
			setURL(server.URL)
			stop, done := make(chan struct{}), make(chan struct{})
			go func() {
				defer close(done)
				for {
					select {
					case <-stop:
						return
					default:
					}
					if lookup() != expected || oldLookup() != expected {
						t.Error("update invalidated a live reader")
						return
					}
				}
			}()
			defer func() { close(stop); <-done }()
			for i := 0; i < 3; i++ {
				data = append(append([]byte{}, data...), 0) // valid metadata, different HTTP content/hash
				response.Store(data)
				if err := update(path); err != nil {
					t.Fatal(err)
				}
				data = append(append([]byte{}, data...), 0)
				response.Store(data)
				if err := periodic(); err != nil {
					t.Fatal(err)
				}
				runtime.GC()
			}
			response.Store([]byte("invalid database"))
			if err := update(path); err == nil {
				t.Fatal("invalid update accepted")
			}
			got, err := os.ReadFile(path)
			if err != nil || !bytes.Equal(got, data) {
				t.Fatal("failed update replaced the saved database", err)
			}
			response.Store(data)
			badPath := path + ".directory"
			if err := os.Mkdir(badPath, 0700); err != nil {
				t.Fatal(err)
			}
			if err := update(badPath); err == nil {
				t.Fatal("failed rename reported success")
			}
			if lookup() != expected || oldLookup() != expected {
				t.Fatal("failed update retired current readers")
			}
			if files, _ := filepath.Glob(filepath.Join(C.Path.HomeDir(), ".mmdb-*")); len(files) != 0 {
				t.Fatal("staging files leaked", files)
			}
		})
	}
}
