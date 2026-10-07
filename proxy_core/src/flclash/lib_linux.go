//go:build ohos && cgo

package main

import "C"
import (
	"core/platform"
	"core/state"
	t "core/tun"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"net"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/iface"
	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type ProcessMap struct {
	m sync.Map
}

type Fd struct {
	Id    int64 `json:"id"`
	Value int64 `json:"value"`
}

var (
	tunListener   *sing_tun.Listener
	fdWaiters     sync.Map
	fdCounter     int64 = 0
	counter       int64 = 0
	processMap    ProcessMap
	tunLock       sync.Mutex
	runTime       *time.Time
	errBlocked    = errors.New("blocked")
	keepaliveStop chan struct{}
)

func (cm *ProcessMap) Store(key int64, value string) {
	cm.m.Store(key, value)
}

func (cm *ProcessMap) Load(key int64) (string, bool) {
	value, ok := cm.m.Load(key)
	if !ok || value == nil {
		return "", false
	}
	return value.(string), true
}

func StartTUN(fd int, markSocket func(Fd)) error {
	tunLock.Lock()
	defer tunLock.Unlock()
	if fd < 0 || currentConfig == nil {
		return errors.New("TUN configuration is not ready")
	}
	if tunListener != nil {
		return errors.New("TUN is already running")
	}
	initSocketHook(markSocket)
	listener, err := t.Start(fd, currentConfig.General.Tun.Device, currentConfig.General.Tun.Stack, currentConfig.General.Tun.DNSHijack)
	if err != nil {
		removeSocketHook()
		return err
	}
	tunListener = listener
	now := time.Now()
	runTime = &now
	startKeepalive()
	return nil
}

type idleActivity struct {
	up, down int64
	at       time.Time
}

func startKeepalive() {
	// 先停止已有保活
	stopKeepalive()
	keepaliveStop = make(chan struct{})
	stop := keepaliveStop
	go func() {
		activity := make(map[string]idleActivity)
		ticker := time.NewTicker(60 * time.Second)
		defer ticker.Stop()
		log.Infoln("[Keepalive] TUN 保活 goroutine 已启动")
		for {
			select {
			case <-ticker.C:
				// 直连模式下不需要健康检查和空闲连接清理
				if currentConfig != nil && string(currentConfig.General.Mode) == "direct" {
					continue
				}
				snapshot := statistic.DefaultManager.Snapshot()
				if snapshot != nil && len(snapshot.Connections) > 0 {
					go handleHealthCheckAll()
				}
				// Upstream trackers expose counters, not LastActivity(). Derive
				// idle time from unchanged counters instead of connection age.
				now := time.Now()
				live := make(map[string]bool)
				statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
					id, info := c.ID(), c.Info()
					live[id] = true
					up, down := info.UploadTotal.Load(), info.DownloadTotal.Load()
					previous, exists := activity[id]
					if !exists || previous.up != up || previous.down != down {
						activity[id] = idleActivity{up: up, down: down, at: now}
					} else if now.Sub(previous.at) > 120*time.Second {
						_ = c.Close()
						delete(activity, id)
					}
					return true
				})
				for id := range activity {
					if !live[id] {
						delete(activity, id)
					}
				}

			case <-stop:
				log.Infoln("[Keepalive] TUN 保活 goroutine 已停止")
				return
			}
		}
	}()
}

func stopKeepalive() {
	if keepaliveStop != nil {
		close(keepaliveStop)
		keepaliveStop = nil
	}
}

func GetRunTime() string {
	tunLock.Lock()
	defer tunLock.Unlock()
	if runTime == nil {
		return "0"
	}
	return strconv.FormatInt(runTime.UnixMilli(), 10)
}
func ConfigInited() string {
	if currentConfig != nil {
		return "true"
	}
	return "false"
}

// Synchronous completion; NAPI calls this on a worker and resolves its Promise
// only after listeners, protect waiters and DNS state have been released.
func StopTun() error {
	tunLock.Lock()
	defer tunLock.Unlock()
	stopKeepalive()
	runTime = nil
	removeSocketHook()
	fdWaiters.Range(func(key, value any) bool {
		acknowledgeFd(key.(int64), false)
		return true
	})
	var err error
	if tunListener != nil {
		err = tunListener.Close()
		tunListener = nil
	}
	dns.FlushCacheWithDefaultResolver()
	return err
}

func acknowledgeFd(id int64, success bool) {
	if value, ok := fdWaiters.LoadAndDelete(id); ok {
		value.(chan bool) <- success
	}
}
func SetFdMap(fd C.long) { acknowledgeFd(int64(fd), true) }

func initSocketHook(markSocket func(Fd)) {
	dialer.DefaultSocketHook = func(network, address string, conn syscall.RawConn) error {
		if platform.ShouldBlockConnection() {
			return errBlocked
		}
		var protectErr error
		err := conn.Control(func(fd uintptr) {
			id := atomic.AddInt64(&fdCounter, 1)
			result := make(chan bool, 1)
			fdWaiters.Store(id, result)
			defer fdWaiters.Delete(id)
			markSocket(Fd{Id: id, Value: int64(fd)})
			timer := time.NewTimer(5 * time.Second)
			defer timer.Stop()
			select {
			case ok := <-result:
				if !ok {
					protectErr = errors.New("VPN socket protection failed")
				}
			case <-timer.C:
				protectErr = errors.New("VPN socket protection timed out")
			}
		})
		if err != nil {
			return err
		}
		return protectErr
	}
}

func removeSocketHook() {
	dialer.DefaultSocketHook = nil
}

func init() {
	process.DefaultPackageNameResolver = func(metadata *constant.Metadata) (string, error) {
		if metadata == nil {
			return "", process.ErrInvalidNetwork
		}
		id := atomic.AddInt64(&counter, 1)

		timeout := time.After(200 * time.Millisecond)

		// SendMessage(Message{
		// 	Type: ProcessMessage,
		// 	Data: Process{
		// 		Id:       id,
		// 		Metadata: metadata,
		// 	},
		// })

		for {
			select {
			case <-timeout:
				return "", errors.New("package resolver timeout")
			default:
				value, exists := processMap.Load(id)
				if exists {
					return value, nil
				}
				time.Sleep(20 * time.Millisecond)
			}
		}
	}
}

func SetProcessMap(s string) string {
	paramsString := s
	go func() {
		var processMapItem = &ProcessMapItem{}
		err := json.Unmarshal([]byte(paramsString), processMapItem)
		if err == nil {
			processMap.Store(processMapItem.Id, processMapItem.Value)
		}
	}()
	return ""
}

func GetCurrentProfileName() string {
	if state.CurrentState == nil {
		return ""
	}
	return state.CurrentState.CurrentProfileName
}

func GetVpnOptions() string {
	tunLock.Lock()
	defer tunLock.Unlock()
	port := 7980
	if currentConfig != nil {
		port = currentConfig.General.MixedPort
	}
	options := state.AndroidVpnOptions{
		Enable:           state.CurrentState.Enable,
		Port:             port,
		Ipv4Address:      state.CurrentState.TunIp,
		Ipv6Address:      state.GetIpv6Address(),
		AccessControl:    state.CurrentState.AccessControl,
		SystemProxy:      state.CurrentState.SystemProxy,
		AllowBypass:      state.CurrentState.AllowBypass,
		RouteAddress:     state.CurrentState.RouteAddress,
		BypassDomain:     state.CurrentState.BypassDomain,
		DnsServerAddress: state.GetDnsServerAddress(),
		Mtu:              state.CurrentState.Mtu,
	}
	data, err := json.Marshal(options)
	if err != nil {
		fmt.Println("Error:", err)
		return ""
	}
	return string(data)
}

func SetState(s *C.char) {
	paramsString := C.GoString(s)
	err := json.Unmarshal([]byte(paramsString), state.CurrentState)
	if err != nil {
		return
	}
}

func UpdateDns(s *C.char) {
	dnsList := C.GoString(s)
	go func() {
		log.Infoln("[DNS] updateDns %s", dnsList)
		dns.UpdateSystemDNS(strings.Split(dnsList, ","))
		dns.FlushCacheWithDefaultResolver()
	}()
}

func UpdateSystemDns(dnsList string) error {
	log.Infoln("[DNS] updateDns %s", dnsList)
	go func() {
		log.Infoln("[DNS] updateDns %s", dnsList)
		dns.UpdateSystemDNS(strings.Split(dnsList, ","))
		dns.FlushCacheWithDefaultResolver()
	}()
	return nil
}

type NetIpMacInfo struct {
	IpAddress  NetAddress `json:"ipAddress"`
	Iface      string     `json:"iface"`
	MacAddress string     `json:"macAddress"`
}
type NetAddress struct {
	Address string `json:"address"` // IP地址
	Family  int    `json:"family"`  // 地址族：4(IPv4)或6(IPv6)
	Port    int    `json:"port"`    // 端口号（如果有）
}

func (info *NetIpMacInfo) ToNetInterface() (*net.Interface, error) {
	// 解析 MAC 地址
	var mac net.HardwareAddr
	if info.MacAddress != "" {
		var err error
		mac, err = net.ParseMAC(info.MacAddress)
		if err != nil {
			return nil, fmt.Errorf("parse MAC address failed: %w", err)
		}
	}

	// 获取接口索引（通过接口名）
	var index int
	if info.Iface != "" {
		iface, err := net.InterfaceByName(info.Iface)
		if err == nil && iface != nil {
			index = iface.Index
		}
	}

	return &net.Interface{
		Index:        index,
		MTU:          1500, // 默认值，你可能需要从其他地方获取
		Name:         info.Iface,
		HardwareAddr: mac,
		Flags:        getInterfaceFlags(info), // 需要实现这个函数
	}, nil
}
func getInterfaceFlags(info *NetIpMacInfo) net.Flags {
	var flags net.Flags

	// 如果 MAC 地址存在，通常接口是启用的
	if info.MacAddress != "" {
		flags |= net.FlagUp
		flags |= net.FlagBroadcast
		flags |= net.FlagMulticast
	}

	// 检查是否为回环接口
	if info.Iface == "lo" || info.Iface == "lo0" {
		flags |= net.FlagLoopback
	}
	return flags
}

func SetInterfaces(paramsString string) error {
	var interfaces []net.Interface
	var infos []NetIpMacInfo
	err := json.Unmarshal([]byte(paramsString), &infos)
	if err != nil {
		return err
	}
	seen := make(map[string]bool) // 去重
	for _, info := range infos {
		if seen[info.Iface] {
			continue
		}
		ifa, err := info.ToNetInterface()
		if err != nil {
			continue // 或者返回错误
		}

		if ifa != nil {
			interfaces = append(interfaces, *ifa)
			seen[info.Iface] = true
		}
	}
	iface.SetNetInterfaces(interfaces)
	return nil
}
