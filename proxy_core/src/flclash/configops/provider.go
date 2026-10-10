package configops

import (
	"errors"
	"github.com/metacubex/mihomo/adapter/provider"
	cp "github.com/metacubex/mihomo/constant/provider"
	rp "github.com/metacubex/mihomo/rules/provider"
)

func SideUpdate(p cp.Provider, data []byte) error {
	switch value := p.(type) {
	case *provider.ProxySetProvider:
		_, _, err := value.SideUpdate(data)
		return err
	case *rp.RuleSetProvider:
		_, _, err := value.SideUpdate(data)
		return err
	default:
		return errors.New("not external provider")
	}
}
