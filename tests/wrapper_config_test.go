package main

import (
	"encoding/json"
	"fmt"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/geodata/router"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"google.golang.org/protobuf/proto"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type liveTracker struct {
	C.Connection
	closed bool
}

func (r *liveTracker) ID() string                   { return "live-connection" }
func (r *liveTracker) Info() *statistic.TrackerInfo { return &statistic.TrackerInfo{} }
func (r *liveTracker) Close() error                 { r.closed = true; return nil }

func parseConfig(t *testing.T, yaml string) *config.RawConfig {
	t.Helper()
	raw, err := config.UnmarshalRawConfig([]byte(yaml))
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestRuntimeSnapshotDoesNotReloadOrReadReplacedSubscription(t *testing.T) {
	dir := t.TempDir()
	C.SetHomeDir(dir)
	liveSnapshot = nil
	output := filepath.Join(dir, "snapshot.json")
	if loaded, err := handleGetConfigSnapshot(output); err != nil || loaded {
		t.Fatalf("fresh core: %v %v", loaded, err)
	}
	source := "proxy-groups: [{name: PROXY, type: select, proxies: [DIRECT, REJECT]}]\nrules: ['MATCH,PROXY']\n"
	input := filepath.Join(dir, "source.yaml")
	if err := os.WriteFile(input, []byte(source), 0600); err != nil {
		t.Fatal(err)
	}
	request, err := json.Marshal(map[string]any{"profile-id": "A/config", "source-path": input, "config": config.DefaultRawConfig(), "params": ConfigExtendedParams{SelectedMap: map[string]string{"PROXY": "DIRECT"}}})
	if err != nil {
		t.Fatal(err)
	}
	if err := handleUpdateConfig(request); err != "" {
		t.Fatal(err)
	}
	connection := &liveTracker{}
	statistic.DefaultManager.Join(connection)
	defer statistic.DefaultManager.Leave(connection)
	result := make(chan string, 1)
	handleChangeProxy(`{"group-name":"PROXY","proxy-name":"REJECT"}`, func(s string) { result <- s })
	if err := <-result; err != "" {
		t.Fatal(err)
	}
	if err := os.WriteFile(input, []byte("invalid: ["), 0600); err != nil {
		t.Fatal(err)
	}
	if loaded, err := handleGetConfigSnapshot(output); err != nil || !loaded {
		t.Fatalf("snapshot: %v %v", loaded, err)
	}
	data, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	var snapshot appliedSnapshot
	if err := json.Unmarshal(data, &snapshot); err != nil {
		t.Fatal(err)
	}
	if snapshot.Source != source || snapshot.ProfileID != "A" || snapshot.Params.SelectedMap["PROXY"] != "REJECT" {
		t.Fatalf("wrong snapshot: %+v", snapshot)
	}
	if connection.closed {
		t.Fatal("attaching closed a live connection")
	}
	if err := handleUpdateConfig(request); err == "" {
		t.Fatal("invalid source accepted")
	}
	if liveSnapshot.Source != source {
		t.Fatal("failed apply replaced snapshot")
	}
}

func TestResourceURLPatchChangesEveryDownloadSourceWithoutDisconnecting(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	configParams = ConfigExtendedParams{}
	if err := applyConfig(parseConfig(t, "rules: ['MATCH,DIRECT']\ngeox-url: {geoip: 'http://127.0.0.1/old'}")); err != nil {
		t.Fatal(err)
	}
	connection := &liveTracker{}
	statistic.DefaultManager.Join(connection)
	defer statistic.DefaultManager.Leave(connection)
	configParams.IsPatch = true
	next := parseConfig(t, "rules: ['MATCH,DIRECT']\ngeox-url: {geoip: 'http://127.0.0.1/ip', geosite: 'http://127.0.0.1/site', mmdb: 'http://127.0.0.1/mmdb', asn: 'http://127.0.0.1/asn'}")
	if err := applyConfig(next); err != nil {
		t.Fatal(err)
	}
	if geodata.GeoIpUrl() != next.GeoXUrl.GeoIp || geodata.GeoSiteUrl() != next.GeoXUrl.GeoSite || geodata.MmdbUrl() != next.GeoXUrl.Mmdb || geodata.ASNUrl() != next.GeoXUrl.ASN {
		t.Fatal("downloader retained old URLs")
	}
	if connection.closed {
		t.Fatal("resource URL patch closed a live connection")
	}
}

func TestProviderOperationsUseCurrentConfigurationAfterSwitch(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	configParams = ConfigExtendedParams{}
	for _, id := range []string{"A", "B"} {
		raw := parseConfig(t, fmt.Sprintf("proxy-providers:\n  nodes:\n    type: file\n    path: %s.yaml\n    payload: [{name: %s, type: trojan, server: example.invalid, port: 443, password: secret}]\nproxy-groups: [{name: PROXY, type: select, use: [nodes]}]\nrules: ['MATCH,PROXY']\n", id, id))
		if err := applyConfig(raw); err != nil {
			t.Fatal(err)
		}
		if id == "A" {
			handleGetExternalProviders()
		}
	}
	result := make(chan string, 1)
	handleSideLoadExternalProvider("nodes", []byte("proxies: []"), func(s string) { result <- s }, C.Path.Resolve("A.yaml"))
	if err := <-result; err == "" {
		t.Fatal("stale page uploaded into a different profile")
	}
	handleUpdateExternalProvider("nodes", func(s string) { result <- s }, C.Path.Resolve("A.yaml"))
	if err := <-result; err == "" {
		t.Fatal("stale page updated a different profile")
	}
	if tunnel.Providers()["nodes"].Proxies()[0].Name() != "B" {
		t.Fatal("rejected upload changed live nodes")
	}
	handleSideLoadExternalProvider("nodes", []byte("proxies: [{name: uploaded, type: trojan, server: example.invalid, port: 443, password: secret}]"), func(s string) { result <- s })
	if err := <-result; err != "" {
		t.Fatal(err)
	}
	if tunnel.Providers()["nodes"].Proxies()[0].Name() != "uploaded" {
		t.Fatal("upload targeted retired provider")
	}
	if _, err := os.Stat(C.Path.Resolve("A.yaml")); !os.IsNotExist(err) {
		t.Fatal("retired provider file was changed")
	}
	handleUpdateExternalProvider("nodes", func(s string) { result <- s })
	if err := <-result; err != "" {
		t.Fatal(err)
	}
	if err := applyConfig(parseConfig(t, "rules: ['MATCH,DIRECT']")); err != nil {
		t.Fatal(err)
	}
	handleSideLoadExternalProvider("nodes", []byte("proxies: []"), func(s string) { result <- s })
	if err := <-result; err == "" {
		t.Fatal("deleted provider accepted upload")
	}
}

func TestProviderNetworkUpdateDoesNotBlockCoreAndCannotReportRetiredSuccess(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	configParams = ConfigExtendedParams{}
	entered, release := make(chan struct{}), make(chan struct{}, 1)
	var count atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if count.Add(1) > 1 {
			close(entered)
			<-release
		}
		fmt.Fprint(w, "proxies: [{name: N, type: trojan, server: example.invalid, port: 443, password: secret}]")
	}))
	defer server.Close()
	defer close(release)
	raw := parseConfig(t, fmt.Sprintf("proxy-providers:\n  nodes:\n    type: http\n    url: %s\n    path: nodes.yaml\nproxy-groups: [{name: PROXY, type: select, use: [nodes]}]\nrules: ['MATCH,PROXY']", server.URL))
	if err := applyConfig(raw); err != nil {
		t.Fatal(err)
	}
	result := make(chan string, 1)
	handleUpdateExternalProvider("nodes", func(s string) { result <- s })
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("update did not start")
	}
	available := make(chan struct{})
	go func() { runLock.Lock(); runLock.Unlock(); close(available) }()
	select {
	case <-available:
	case <-time.After(time.Second):
		t.Fatal("network download blocked core operations")
	}
	runLock.Lock()
	err := applyConfig(parseConfig(t, "rules: ['MATCH,DIRECT']"))
	runLock.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	// Release before waiting for completion; server cleanup also runs on failures.
	release <- struct{}{}
	select {
	case err := <-result:
		if err == "" {
			t.Fatal("retired provider reported success")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("update did not complete")
	}
}

func TestSnapshotPreservesAutomaticGroupSelection(t *testing.T) {
	for _, kind := range []string{"url-test", "fallback"} {
		t.Run(kind, func(t *testing.T) {
			dir := t.TempDir()
			C.SetHomeDir(dir)
			source := filepath.Join(dir, "source.yaml")
			if err := os.WriteFile(source, []byte(fmt.Sprintf("proxy-groups: [{name: AUTO, type: %s, proxies: [DIRECT, REJECT]}]\nrules: ['MATCH,AUTO']\n", kind)), 0600); err != nil {
				t.Fatal(err)
			}
			request := func(params ConfigExtendedParams) []byte {
				data, err := json.Marshal(map[string]any{"profile-id": "A/config", "source-path": source, "config": config.DefaultRawConfig(), "params": params})
				if err != nil {
					t.Fatal(err)
				}
				return data
			}
			if e := handleUpdateConfig(request(ConfigExtendedParams{})); e != "" {
				t.Fatal(e)
			}
			group := func() map[string]any {
				b, _ := json.Marshal(tunnel.Proxies()["AUTO"])
				var g map[string]any
				if e := json.Unmarshal(b, &g); e != nil {
					t.Fatal(e)
				}
				return g
			}
			before := group()
			if before["fixed"] != "" {
				t.Fatalf("unexpected initial fixed: %+v", before)
			}
			output := filepath.Join(dir, "snapshot.json")
			if ok, e := handleGetConfigSnapshot(output); e != nil || !ok {
				t.Fatal(ok, e)
			}
			data, _ := os.ReadFile(output)
			var snapshot appliedSnapshot
			if err := json.Unmarshal(data, &snapshot); err != nil {
				t.Fatal(err)
			}
			// This is the exact selected map used when the attached UI rolls back a failed activation.
			if e := handleUpdateConfig(request(snapshot.Params)); e != "" {
				t.Fatal(e)
			}
			after := group()
			if after["fixed"] != "" {
				t.Fatal("snapshot pinned an automatic group")
			}
			t.Logf("AUTO before fixed=%q; snapshot selected=%q; restored fixed=%q", before["fixed"], snapshot.Params.SelectedMap["AUTO"], after["fixed"])
			if e := handleUpdateConfig(request(ConfigExtendedParams{SelectedMap: map[string]string{"AUTO": "DIRECT"}})); e != "" {
				t.Fatal(e)
			}
			if ok, e := handleGetConfigSnapshot(output); e != nil || !ok {
				t.Fatal(ok, e)
			}
			data, _ = os.ReadFile(output)
			if err := json.Unmarshal(data, &snapshot); err != nil {
				t.Fatal(err)
			}
			if snapshot.Params.SelectedMap["AUTO"] != "DIRECT" {
				t.Fatal("manual selection lost")
			}
			if e := handleUpdateConfig(request(snapshot.Params)); e != "" {
				t.Fatal(e)
			}
			if group()["fixed"] != "DIRECT" {
				t.Fatal("manual selection not restored")
			}
		})
	}
}

func TestRuleRefreshWhileParsing(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	configParams = ConfigExtendedParams{}
	var serial atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "payload:\n  - %d.example.invalid\n", serial.Add(1))
	}))
	defer server.Close()
	raw := parseConfig(t, fmt.Sprintf(`rule-providers:
  active:
    type: http
    url: %s
    behavior: domain
    path: rules.yaml
    interval: 0
    payload: [example.invalid]
rules: ['RULE-SET,active,DIRECT','MATCH,DIRECT']
`, server.URL))
	if err := applyConfig(raw); err != nil {
		t.Fatal(err)
	}
	active := tunnel.RuleProviders()["active"]
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 200; i++ {
			// Update runs outside runLock for HTTP refresh and periodic provider tasks.
			if err := active.Update(); err != nil {
				t.Error(err)
			}
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 200; i++ {
			// The normal configuration activation/patch parser, while the live provider refreshes.
			runLock.Lock()
			if parsed, err := config.ParseRawConfig(raw); err != nil {
				t.Error(err)
			} else {
				config.CloseParsedConfig(parsed)
			}
			runLock.Unlock()
		}
	}()
	wg.Wait()
}

func TestProviderIdentityIncludesType(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	configParams = ConfigExtendedParams{}
	raw := parseConfig(t, `proxy-providers:
  shared:
    type: file
    path: nodes.yaml
    payload: [{name: node, type: trojan, server: example.invalid, port: 443, password: secret}]
rule-providers:
  shared:
    type: file
    behavior: domain
    path: rules.yaml
    payload: [example.invalid]
proxy-groups: [{name: PROXY, type: select, use: [shared]}]
rules: ['RULE-SET,shared,PROXY','MATCH,DIRECT']
`)
	if err := applyConfig(raw); err != nil {
		t.Fatal(err)
	}
	var shown []ExternalProvider
	if err := json.Unmarshal([]byte(handleGetExternalProviders()), &shown); err != nil {
		t.Fatal(err)
	}
	t.Logf("active proxy providers=%d, rule providers=%d; UI list=%+v", len(tunnel.Providers()), len(tunnel.RuleProviders()), shown)
	if len(shown) != 2 {
		t.Fatalf("same-name providers lost: %+v", shown)
	}
	result := make(chan string, 1)
	handleSideLoadExternalProvider("shared", []byte("payload:\n  - changed.invalid\n"), func(s string) { result <- s })
	if e := <-result; e == "" {
		t.Fatal("ambiguous legacy request accepted")
	}
	for _, kind := range []string{"Proxy", "Rule"} {
		body := "payload:\n  - changed.invalid\n"
		path := "rules.yaml"
		if kind == "Proxy" {
			path = "nodes.yaml"
			body = "proxies: [{name: uploaded, type: trojan, server: example.invalid, port: 443, password: secret}]"
		}
		handleSideLoadExternalProvider("shared", []byte(body), func(s string) { result <- s }, C.Path.Resolve(path), kind)
		if e := <-result; e != "" {
			t.Fatal(e)
		}
		handleUpdateExternalProvider("shared", func(s string) { result <- s }, C.Path.Resolve(path), kind)
		if e := <-result; e != "" {
			t.Fatal(e)
		}
		if handleGetExternalProvider("shared", kind) == "" {
			t.Fatal("typed lookup failed")
		}
	}
	if tunnel.Providers()["shared"].Proxies()[0].Name() != "uploaded" {
		t.Fatal("wrong proxy provider uploaded")
	}
	if !tunnel.RuleProviders()["shared"].Match(&C.Metadata{Host: "changed.invalid"}, C.RuleMatchHelper{}) {
		t.Fatal("wrong rule provider uploaded")
	}
}

func TestGeoSiteUpdateInvalidatesCachedMatcher(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	geodata.SetLoader("standard")
	geodata.ClearGeoSiteCache()
	defer geodata.ClearGeoSiteCache()
	bytesFor := func(domain string) []byte {
		data, e := proto.Marshal(&router.GeoSiteList{Entry: []*router.GeoSite{{CountryCode: "CN", Domain: []*router.Domain{{Type: router.Domain_Full, Value: domain}}}}})
		if e != nil {
			t.Fatal(e)
		}
		return data
	}
	if e := os.WriteFile(C.Path.GeoSite(), bytesFor("old.invalid"), 0600); e != nil {
		t.Fatal(e)
	}
	before, e := geodata.LoadGeoSiteMatcher("cn")
	if e != nil || !before.ApplyDomain("old.invalid") {
		t.Fatal(e)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(bytesFor("new.invalid")) }))
	defer server.Close()
	geodata.SetGeoSiteUrl(server.URL)
	result := make(chan string, 1)
	handleUpdateGeoData("GeoSite", filepath.Base(C.Path.GeoSite()), func(s string) { result <- s })
	if e := <-result; e != "" {
		t.Fatal(e)
	}
	after, e := geodata.LoadGeoSiteMatcher("cn")
	if e != nil {
		t.Fatal(e)
	}
	if after.ApplyDomain("old.invalid") || !after.ApplyDomain("new.invalid") {
		t.Fatal("successful update retained stale cache")
	}
}

func TestGeoIPUpdateInvalidatesCachedMatcherAndRejectsInvalidDownload(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	geodata.SetLoader("standard")
	geodata.ClearGeoIPCache()
	defer geodata.ClearGeoIPCache()
	bytesFor := func(ip []byte) []byte {
		data, err := proto.Marshal(&router.GeoIPList{Entry: []*router.GeoIP{{CountryCode: "CN", Cidr: []*router.CIDR{{Ip: ip, Prefix: 32}}}}})
		if err != nil {
			t.Fatal(err)
		}
		return data
	}
	original := bytesFor([]byte{192, 0, 2, 1})
	replacement := bytesFor([]byte{192, 0, 2, 2})
	if err := os.WriteFile(C.Path.GeoIP(), original, 0600); err != nil {
		t.Fatal(err)
	}
	before, err := geodata.LoadGeoIPMatcher("cn")
	if err != nil {
		t.Fatal(err)
	}
	if !before.Match(netip.MustParseAddr("192.0.2.1")) {
		t.Fatal("original matcher missing")
	}
	var invalid atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if invalid.Load() {
			w.Write([]byte("invalid"))
		} else {
			w.Write(replacement)
		}
	}))
	defer server.Close()
	geodata.SetGeoIpUrl(server.URL)
	result := make(chan string, 1)
	update := func() string {
		handleUpdateGeoData("GeoIp", filepath.Base(C.Path.GeoIP()), func(s string) { result <- s })
		return <-result
	}
	if err := update(); err != "" {
		t.Fatal(err)
	}
	after, err := geodata.LoadGeoIPMatcher("cn")
	if err != nil {
		t.Fatal(err)
	}
	if after.Match(netip.MustParseAddr("192.0.2.1")) || !after.Match(netip.MustParseAddr("192.0.2.2")) {
		t.Fatal("stale IP matcher")
	}
	invalid.Store(true)
	if err := update(); err == "" {
		t.Fatal("invalid resource accepted")
	}
	after, err = geodata.LoadGeoIPMatcher("cn")
	if err != nil || !after.Match(netip.MustParseAddr("192.0.2.2")) {
		t.Fatal("failed update discarded working matcher", err)
	}
	saved, err := os.ReadFile(C.Path.GeoIP())
	if err != nil || string(saved) != string(replacement) {
		t.Fatal("failed update changed file", err)
	}
}
