package main

import (
	"encoding/json"
	"fmt"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
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
