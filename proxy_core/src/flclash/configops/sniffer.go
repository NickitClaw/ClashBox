package configops

import "github.com/metacubex/mihomo/config"

// A missing override inherits the subscription. An explicit false disables sniffing.
func OverrideSniffer(target *config.RawConfig, override *config.RawSniffer) {
	if override != nil {
		target.Sniffer = *override
	}
}
