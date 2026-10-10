package integration_test

import (
	"core/configops"
	"encoding/json"
	"fmt"
	AP "github.com/metacubex/mihomo/adapter/provider"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/resource"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	_ "github.com/metacubex/mihomo/hub/executor"
	RP "github.com/metacubex/mihomo/rules/provider"
	T "github.com/metacubex/mihomo/tunnel"
)

func TestHTTPRuleProviderDownloadRefreshAndCache(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	RP.SetTunnel(T.Tunnel)
	var count atomic.Int32
	var reject atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		count.Add(1)
		if reject.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		fmt.Fprint(w, "payload:\n  - example.invalid\n")
	}))
	defer server.Close()
	newProvider := func() P.RuleProvider {
		p, err := RP.ParseRuleProvider("review", map[string]any{
			"type": "http", "behavior": "domain", "format": "yaml", "url": server.URL,
			"path": "rules/review.yaml", "interval": 0,
		}, nil, func(string) resource.BundleFile { return nil })
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { p.(interface{ Close() error }).Close() })
		return p
	}
	p := newProvider()
	if err := p.Initial(); err != nil {
		t.Fatal(err)
	}
	if p.Count() != 1 || count.Load() != 1 {
		t.Fatal("initial rule download did not populate provider")
	}
	if err := p.Update(); err != nil {
		t.Fatal(err)
	}
	if count.Load() != 2 {
		t.Fatal("manual refresh did not reach server")
	}
	reject.Store(true)
	if err := p.Update(); err == nil {
		t.Fatal("failed refresh must be reported")
	}
	if p.Count() != 1 {
		t.Fatal("failed refresh discarded working rules")
	}
	cached := newProvider()
	if err := cached.Initial(); err != nil {
		t.Fatal("cached rules must work offline:", err)
	}
	if cached.Count() != 1 {
		t.Fatal("cache was not restored")
	}
}

func TestHTTPRuleProviderRetainsPeriodicRefresh(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	RP.SetTunnel(T.Tunnel)
	requests := make(chan struct{}, 20)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, "payload:\n  - example.invalid\n")
		requests <- struct{}{}
	}))
	defer server.Close()
	p := RP.NewRuleSetProvider("periodic", P.Domain, P.YamlRule, 30*time.Millisecond,
		resource.NewHTTPVehicle(server.URL, C.Path.Resolve("periodic.yaml"), "", nil, time.Second, 0), nil, nil, nil)
	defer p.(interface{ Close() error }).Close()
	if err := p.Initial(); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		select {
		case <-requests:
		case <-time.After(3 * time.Second):
			t.Fatal("periodic refresh was disabled")
		}
	}
}

func TestProviderSideUpdateReportsErrorsAndAcceptsRulePointers(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	RP.SetTunnel(T.Tunnel)
	proxy, err := AP.ParseProxyProvider("proxy", map[string]any{"type": "file", "path": "proxies/upload.yaml"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer proxy.(interface{ Close() error }).Close()
	good := []byte("proxies:\n  - {name: node, type: trojan, server: example.invalid, port: 443, password: secret}\n")
	if err := configops.SideUpdate(proxy, good); err != nil {
		t.Fatal(err)
	}
	if err := configops.SideUpdate(proxy, []byte("proxies: [invalid")); err == nil {
		t.Fatal("invalid proxy upload reported success")
	}
	if proxy.Count() != 1 {
		t.Fatal("bad upload discarded working proxies")
	}
	rules := RP.NewRuleSetProvider("rules", P.Domain, P.YamlRule, 0, resource.NewFileVehicle(C.Path.Resolve("rules/upload.yaml")), nil, nil, nil)
	defer rules.(interface{ Close() error }).Close()
	if err := configops.SideUpdate(rules, []byte("payload:\n  - example.invalid\n")); err != nil {
		t.Fatal(err)
	}
	if rules.Count() != 1 {
		t.Fatal("uploaded rules were not applied")
	}
	if err := configops.SideUpdate(rules, []byte("payload: [invalid")); err == nil {
		t.Fatal("invalid rule upload reported success")
	}
	if rules.Count() != 1 {
		t.Fatal("bad upload discarded working rules")
	}
}

func TestConcurrentRuleRefreshAndRouting(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	RP.SetTunnel(T.Tunnel)
	p := RP.NewRuleSetProvider("rules", P.Domain, P.YamlRule, 0, resource.NewFileVehicle(C.Path.Resolve("rules.yaml")), nil, nil, nil)
	defer p.(interface{ Close() error }).Close()
	if err := configops.SideUpdate(p, []byte("payload:\n  - example.invalid\n")); err != nil {
		t.Fatal(err)
	}
	var workers sync.WaitGroup
	workers.Add(2)
	go func() {
		defer workers.Done()
		for i := 0; i < 2000; i++ {
			p.Match(&C.Metadata{Host: "example.invalid"}, C.RuleMatchHelper{})
			p.Count()
			p.Strategy()
			if _, err := json.Marshal(p); err != nil {
				t.Error(err)
			}
		}
	}()
	go func() {
		defer workers.Done()
		for i := 0; i < 100; i++ {
			if err := configops.SideUpdate(p, []byte(fmt.Sprintf("payload:\n  - %d.example.invalid\n", i))); err != nil {
				t.Error(err)
			}
		}
	}()
	workers.Wait()
}
