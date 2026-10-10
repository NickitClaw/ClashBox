package integration_test

import (
	"core/configops"
	"encoding/json"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/config"
	T "github.com/metacubex/mihomo/tunnel"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
)

func TestValidationRejectsUnusableConfigurations(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	for _, input := range []string{
		"proxies: [{name: bad, type: not-a-protocol, server: example.invalid, port: 443}]",
		"rules: ['NOT_A_RULE,example.invalid,DIRECT']",
		"proxy-groups: [{name: PROXY, type: select, proxies: [nonexistent]}]",
		"dns: {enable: true, nameserver: []}",
		"rules: [",
	} {
		if err := configops.Validate([]byte(input)); err == nil {
			t.Fatalf("accepted invalid configuration: %s", input)
		}
	}
}

func TestValidationDoesNotStartProvidersOrReplaceRuntime(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { requests.Add(1) }))
	defer server.Close()
	before := executor.GetGeneral()
	input := "mode: global\nipv6: false\nrule-providers:\n  sample:\n    type: http\n    behavior: domain\n    url: " + server.URL + "\n    path: rules/sample.yaml\nrules: ['RULE-SET,sample,DIRECT', 'MATCH,DIRECT']"
	for i := 0; i < 10; i++ {
		if err := configops.Validate([]byte(input)); err != nil {
			t.Fatal(err)
		}
	}
	after := executor.GetGeneral()
	if requests.Load() != 0 {
		t.Fatal("validation fetched a provider")
	}
	if before.Mode != after.Mode || before.IPv6 != after.IPv6 || before.Interface != after.Interface {
		t.Fatal("validation did not restore running general options")
	}
}

func TestSnifferOverrideDistinguishesMissingFromFalse(t *testing.T) {
	for _, tc := range []struct {
		json string
		want bool
	}{
		{`{}`, true}, {`{"sniffer":null}`, true},
		{`{"sniffer":{"enable":false}}`, false}, {`{"sniffer":{"enable":true}}`, true},
	} {
		target := config.DefaultRawConfig()
		target.Sniffer.Enable = true
		var overrides struct {
			Sniffer *config.RawSniffer `json:"sniffer"`
		}
		if err := json.Unmarshal([]byte(tc.json), &overrides); err != nil {
			t.Fatal(err)
		}
		configops.OverrideSniffer(target, overrides.Sniffer)
		if target.Sniffer.Enable != tc.want {
			t.Fatalf("%s: enable=%v", tc.json, target.Sniffer.Enable)
		}
	}
}

func TestValidationNeverTemporarilyChangesLiveMode(t *testing.T) {
	C.SetHomeDir(t.TempDir())
	previousMode, previousURL := T.Mode(), geodata.GeoSiteUrl()
	defer func() { T.SetMode(previousMode); geodata.SetGeoSiteUrl(previousURL) }()
	T.SetMode(T.Global)
	var requests atomic.Int32
	var changed atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if T.Mode() != T.Global {
			changed.Store(true)
		}
		w.Write([]byte("not a geosite database"))
	}))
	defer server.Close()
	geodata.SetGeoSiteUrl(server.URL)
	// Parsing this rule blocks on data loading. Observe the live mode during parsing,
	// not just after ParseRawConfig has restored its temporary options.
	input := "mode: direct\ngeox-url: {geosite: '" + server.URL + "'}\nrules: ['GEOSITE,cn,DIRECT']"
	if err := configops.Validate([]byte(input)); err == nil {
		t.Fatal("invalid geodata was accepted")
	}
	if requests.Load() == 0 {
		t.Fatal("test did not observe the parser while loading data")
	}
	if changed.Load() || T.Mode() != T.Global {
		t.Fatal("validation changed live routing mode")
	}
}
