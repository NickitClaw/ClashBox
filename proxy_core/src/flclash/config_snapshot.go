package main

import (
	"encoding/json"
	"os"
	"strings"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/tunnel"
)

// Owned by runLock. Keep the exact source and app settings, not a reparsed YAML
// or a subscription file that a background download may already have replaced.
type appliedSnapshot struct {
	ProfileID string               `json:"profile-id"`
	Source    string               `json:"source"`
	Config    json.RawMessage      `json:"config"`
	Params    ConfigExtendedParams `json:"params"`
}

var liveSnapshot *appliedSnapshot

func prepareConfigSnapshot(data []byte, params *GenerateConfigParams) (*appliedSnapshot, error) {
	var snapshot appliedSnapshot
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return nil, err
	}
	path := getProfilePath(params.ProfileId)
	if params.SourcePath != nil {
		path = *params.SourcePath
	}
	source, err := readFile(path)
	if err != nil {
		return nil, err
	}
	snapshot.Source = string(source)
	snapshot.ProfileID = strings.TrimSuffix(params.ProfileId, "/config")
	return &snapshot, nil
}

func handleGetConfigSnapshot(path string) (bool, error) {
	runLock.Lock()
	defer runLock.Unlock()
	if liveSnapshot == nil {
		return false, nil
	}
	snapshot := *liveSnapshot
	snapshot.Params.SelectedMap = make(map[string]string)
	for name, proxy := range tunnel.ProxiesWithProviders() {
		if p, ok := proxy.(*adapter.Proxy); ok {
			if selector, ok := p.ProxyAdapter.(interface{ Now() string }); ok {
				snapshot.Params.SelectedMap[name] = selector.Now()
			}
		}
	}
	snapshot.Params.IsPatch = false
	data, err := json.Marshal(snapshot)
	if err != nil {
		return false, err
	}
	// The app supplies a unique private temporary file; the reply stays bounded.
	err = os.WriteFile(path, data, 0600)
	return err == nil, err
}
