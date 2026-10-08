//go:build (ohos || android) && cgo

package tun

import "C"
import (
	"core/state"
	"net"
	"net/netip"

	"github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
)

type Props struct {
	Fd       int    `json:"fd"`
	Gateway  string `json:"gateway"`
	Gateway6 string `json:"gateway6"`
	Portal   string `json:"portal"`
	Portal6  string `json:"portal6"`
	Dns      string `json:"dns"`
	Dns6     string `json:"dns6"`
}

func Start(fd int, device string, stack constant.TUNStack, dnsHijack []string) (*sing_tun.Listener, error) {
	var prefix4 []netip.Prefix
	inet4Prefix4, err := netip.ParsePrefix(state.CurrentState.TunIp)
	if err == nil {
		prefix4 = append(prefix4, inet4Prefix4)
	} else {
		tempPrefix4, err := netip.ParsePrefix(state.DefaultIpv4Address)
		if err != nil {
			log.Errorln("startTUN tempPrefix4 error:", err)
			return nil, err
		}
		prefix4 = append(prefix4, tempPrefix4)
	}
	var prefix6 []netip.Prefix

	if state.CurrentState.Ipv6 {
		tempPrefix6, err := netip.ParsePrefix(state.DefaultIpv6Address)
		if err != nil {
			log.Errorln("startTUN  tempPrefix6 error:", err)
			return nil, err
		}
		prefix6 = append(prefix6, tempPrefix6)
	}

	if len(dnsHijack) == 0 {
		dnsHijack = append(dnsHijack, net.JoinHostPort(state.GetDnsServerAddress(), "53"))
	}

	// 系统 VPN 网卡 MTU 默认为 1400（ArkTS 侧 FlClashVpnService），协议栈 MTU 必须与之一致：
	// 之前硬编码 9000 导致下行大包进不了系统网卡被丢弃（ICMP 小包正常、TCP 卡死的断流根因）
	mtu := state.CurrentState.Mtu
	if mtu < 576 || mtu > 65535 {
		mtu = 1400
	}

	options := LC.Tun{
		Enable:              true,
		Device:              device,
		Stack:               stack,
		DNSHijack:           dnsHijack,
		AutoRoute:           false,
		AutoDetectInterface: false,
		Inet4Address:        prefix4,
		Inet6Address:        prefix6,
		MTU:                 uint32(mtu),
		FileDescriptor:      fd,
	}

	listener, err := sing_tun.New(options, tunnel.Tunnel)

	if err != nil {
		log.Errorln("startTUN error:", err)
		return nil, err
	}

	return listener, nil
}
