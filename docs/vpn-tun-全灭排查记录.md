# ClashBox VPN/TUN 全灭问题排查记录

> 记录于 2026-10-06 ~ 2026-10-09。本文档沉淀一次"开启 VPN 后国内外网站全部打不开"问题的完整排查过程、已排除的假设、已修复的问题和当前最强嫌疑点，供后续开发者继续。

## 0. 故障时的 TUN 协议栈：Mixed（默认）

**运行栈 = 覆写配置里的 `TunStack` 值，默认 `Mixed`**（`proxy_core/src/main/ets/models/ClashConfig.ts:191`，UI 选项在 `Constants.ets:545-547`），wrapper 经 `common.go:246`（`targetConfig.Tun.Stack = patchConfig.Tun.Stack`）透传给内核。排查期间该设置未改动，故故障时栈为 Mixed：

- **TCP → gVisor 用户态栈**（即 §5.1 dispatchLoop 所在栈，嫌疑区域）
- **UDP → system（宿主机网络栈转发）**
- 订阅 YAML 无 `tun:` 段时的内核兜底默认是 `TunGvisor`（`core/config/config.go:546`），但被 UI 的 Mixed 覆盖。

佐证日志：故障窗口同时存在 `[TCP] 172.19.0.1:x --> www.youtube.com:443 using GLOBAL`（走 gVisor）和 `[UDP] 172.19.0.1:60265 --> www.youtube.com:443 using GLOBAL`（QUIC/HTTP3，走 system 转发）两类记录，与 Mixed 语义一致。

## 0.1 故障窗口的计数器与内核错误日志（同一会话采集）

/proc/net/dev 列含义：`iface: rx_bytes rx_pkts rx_errs rx_drop ... tx_bytes tx_pkts tx_errs tx_drop ...`

| 时间 | 状态 | vpn-tun 计数 | 解读 |
|---|---|---|---|
| 00:55（香港03，**工作正常**） | 代理出站到 HK，IP 卡显示出口 | RX 2876951B/5007p/0err；TX 2878955B/5009p/**603 drop** | **tx_drop=603**：协议栈发包进 TUN 驱动但读端（gVisor dispatchLoop）丢弃/消费不掉——读端异常的直接信号，与 §5.1 吻合 |
| 01:19（全灭） | 浏览器全灭 | — | 内核错误日志 3 连：`dial GLOBAL 172.19.0.1:x --> www.peopleapp.com:443 error: 38.135.55.228:44949 connect error: dial tcp: i/o timeout`（protect ok=true 前提下的节点 connect 超时） |
| 01:32（全灭，全局模式） | 浏览器全灭 | — | `[TCP] 172.19.0.1:46718 --> www.youtube.com:443 using GLOBAL`（连接进入并被路由），其后**无 dial 错误也无完成记录**——拨号静默挂起 |
| 01:35~01:39 | 埋点观测 | 重启后 RX 648B/10p（新 TUN） | protect `hook fire/ack ok=true` 全绿（fd 119~178）；wlan0 TX 90s +181 包（物理发包正常）；无节点拨号错误 |
| 01:41（仍全灭） | 浏览器全灭 | — | 再次出现 youtube 的 TCP+UDP using GLOBAL 记录，依旧无后续完成 |

关键区分：**01:19 的错误是"内核→节点"的 connect 超时，01:32/01:41 是"进入内核后无声息"**——前者指向节点/网络时段性问题，后者指向 TUN 数据面静默。

## 1. 现象与时间线

- 订阅导入（SSR 分享链接）→ 启动 VPN（授权通过、TUN 建立、状态栏 VPN 图标正常）→ **浏览器打开任何网站（国内 qq/taobao、国外 youtube/google）都卡在加载页，直连模式下同样失败**。
- 但 ICMP ping 通、应用内"公网 IP"卡片能显示节点出口（Hong Kong / Germany）、节点延迟测速有真实值——表象上"一切正常"。

## 2. 环境

| 项 | 值 |
|---|---|
| 真机 | HOP-AL10，HarmonyOS 7（API 26） |
| 模拟器 | Pura X Max 镜像，HarmonyOS 7.0.0.107（**无法建 TUN**，见 §6 限制） |
| 内核 | 源码构建：core=xfz347/Clash.Meta@2ee8e103（debug 分支）+ gvisor=MetaCubeX/gvisor@79317d80 + OpenHarmony-SIG Go 1.24.5（ohos_golang_go@302a5306） |
| 内核构建 | `OHOS_GO=<toolchain>/bin/go bash proxy_core/src/flclash/build.sh arm64`（`GOOS=openharmony GOARCH=arm64 -tags 'ohos with_gvisor'`，`-ldflags -s -w`） |

## 3. 已修复并推送的问题（按发现顺序）

### 3.1 SSR 订阅无法导入（commit 6294df7e）

报错 `yaml: unmarshal errors: cannot unmarshal !!str 'c3NyOi8...' into config.RawConfig`（`c3NyOi8v` = base64 的 `ssr://`）。
根因：`YamlUtils.convertUniversalToClashYaml` 的协议白名单只有 vmess/ss/trojan，ssr:// 解码校验失败 → 原始 base64 直接进内核校验。
修复：`proxy_core/src/main/ets/utils/YamlUtils.ts` 新增 `decodeBase64UrlSafe()`（URL-safe 字母表归一化+补填充）与完整 ssr:// 解析分支（从右往左切 5 段兼容 IPv6、remarks/protoparam/obfsparam 逐个 base64url 解码、重名去重）。

### 3.2 国内网站全灭（分流规则缺失，commit 6294df7e）

转换器生成的配置只有 `MATCH,PROXY`，国内流量全走境外节点，机场 SSR 服务端拦截国内站点导致全灭。
修复：生成 `IP-CIDR 私网直连 + GEOSITE,cn,DIRECT + GEOIP,CN,DIRECT,no-resolve + MATCH,PROXY`。注意：首条规则不能是 2 字段的 `MATCH,xxx`，否则内核 `overrideRules`（common.go）会注入空格分隔的 IP 检测域名规则把配置搞坏（现有 4 字段 IP-CIDR 在首位可自然跳过该逻辑）。

### 3.3 直连出站 DNS 解析环路（commit 6294df7e）

TUN 模式下系统 DNS 指向内核自己（172.19.0.2），无 `dns:` 段时 DIRECT 出站的本地解析会环路/污染。修复：转换器生成 `dns:` 段（fake-ip + 国内 DoH 223.5.5.5/1.12.12.12 + `nameserver-policy geosite:cn`）。

### 3.4 TUN 协议栈 MTU 硬编码 9000（commit 01763b53）

`proxy_core/src/flclash/tun/tun.go` 创建 gVisor sing_tun 监听器时 `MTU: 9000`，而系统 vpn-tun 网卡 MTU=1400（ArkTS `FlClashVpnService.ets:229`）。下行大包被系统网卡丢弃 → **ICMP 小包正常、TCP 全部卡死**，是本问题的典型表象。已改为 `state.CurrentState.Mtu`（默认 1400，越界兜底 1400）。

**但注意：修复后真机矩阵仍未通过（见 §5 当前嫌疑点）。**

## 4. 已排除的假设（有证据，别再重复查）

1. **protect 链路正常**：在 `lib_linux.go initSocketHook` 加埋点后，内核每个出站 fd 都 `hook fire → ack ok=true`（ArkTS `FlClashVpnService.startClash` 的 NAPI `startTun(tunFd, callback)` 回调 → `connection.protect(fd)` → `setFdMap`）。
2. **无回环**：若 protect 失效，节点 SYN 会回环进 TUN，日志会出现 `[TCP] 172.19.0.1:xxx --> <节点IP>:<port> using GLOBAL`——实际**没有**此类记录。
3. **GEOSITE/GEOIP 数据加载正常**：内核日志 `Finished initial GeoSite rule cn => DIRECT, records: 120120`，geo 文件在 `filesDir/ClashBox/`（mihomo HomeDir）。
4. **节点可达**：VPN 关闭时手机浏览器直连节点 IP:44949 返回 `ERR_EMPTY_RESPONSE`（TCP 已连通，SSR 端口对 HTTP 垃圾数据关连接）；Mac 同网络 `nc -vz` 也通。
5. **订阅转换产物正确**：模拟器上经内核 mixed 口实测（见 §6.3），国内外分流全对。

## 5. 当前最强嫌疑点（未闭环）

### 5.1 gVisor dispatchLoop 单点退出（最可疑）

`gvisor-ohos/pkg/tcpip/link/fdbased/endpoint.go:888`：

```go
func (e *endpoint) dispatchLoop(inboundDispatcher linkDispatcher) tcpip.Error {
	for {
		cont, err := inboundDispatcher.dispatch()
		if err != nil || !cont {
			if e.closed != nil { e.closed(err) }
			inboundDispatcher.release()
			return err   // 单个读包失败即永久退出 TUN 读取循环
		}
	}
}
```

**任何一次读包错误或 cont=false 都会永久退出 TUN 读取循环**——之后 App 包进 TUN 但无人处理，表现为"显示运行但全灭"。上游 issue #158 的候选修复正是针对它："为 TUN 读取增加 100 毫秒轮询，并避免单个异常包使整个读取循环退出"（基于 likuai2010/gvisor-ohos 的 ohos 分支，候选提交 2d619610）。

**当前内核 pin 的是 MetaCubeX/gvisor@79317d80，不含此修复**。故障期间实际栈为 **Mixed**（§0）：TCP 走 gVisor 恰落在此循环上；且 §0.1 的 `tx_drop=603` 说明读端丢包真实发生。

关联可疑点：内核默认 `RecvMsgX: true / SendMsgX: false`（`core/config/config.go:551-552`），fdbased 端点按此对 tun fd 用 recvmsg/readv 变体——鸿蒙 netmanager 下发的 tun fd 未必完整支持这些变体，一旦 `dispatch()` 返回错误即触发上述退出。这是把"OHOS 特有性"引进 dispatchLoop 的具体机制候选。

下一步建议：把 likuai2010/gvisor-ohos 的 ohos 分支读取容错逻辑 cherry-pick 进当前 gvisor pin（或把 pin 换回含修复的分支），重编内核验证。

### 5.2 protect() 绑定物理网络的选择

日志里节点拨号"protect ack ok=true 但仍 i/o timeout"存在时段性（01:19 全灭、01:38 正常）。怀疑 protect 绑定到的物理网络与实际有网网络不一致（WiFi/蜂窝切换时）。未取证，仅记录。

### 5.3 干扰项（测试纪律）

- **死节点**：104.243.39.45（德国06）ICMP 100% 丢包。机场订阅里 timeout 节点很多，**测试前必须先测速选活节点**，否则结论无效。
- 节点列表里混有"到期时间：2027-02-21"这类订阅信息伪节点，select 组默认第一个就是它——默认选中=全灭。建议转换器过滤无 server 的条目或选择器默认跳过。

## 6. 排查工具箱（都是实测可用的）

### 6.1 真机（hdc，无需 root）

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC -t <device> shell snapshot_display -f /data/local/tmp/s.jpeg   # 截屏
$HDC -t <device> file recv /data/local/tmp/s.jpeg /tmp/s.jpeg
$HDC -t <device> shell uitest uiInput click <x> <y>                  # 点击（注意锁屏/前台错位风险）
$HDC -t <device> shell uitest uiInput keyEvent Power                 # 电源键（锁屏/亮屏切换，慎用）
$HDC -t <device> shell "grep vpn-tun /proc/net/dev"                  # TUN 计数器（含错误计数）
$HDC -t <device> shell "hilog -x | grep flclashGo | tail -30"        # 内核日志（mihomo info 级含每条 TCP 的路由结果）
$HDC -t <device> shell "aa start -b com.huawei.hmos.browser -a MainAbility -U https://www.qq.com"  # 起浏览器打开URL
```

### 6.2 沙箱文件直读（debug 构建）

DEBUG 构建集成 @cxy/sandboxfinder，监听**局域网 IP:1145**（注意不是 127.0.0.1，Mac 与手机同网段可直接 curl）：

```bash
curl "http://<手机IP>:1145/api/ls?path=/data/storage/el2/base/haps/entry/files/ClashBox/profiles"
curl "http://<手机IP>:1145/api/read?path=.../config.yaml"
```

### 6.3 绕过 TUN 验证内核逻辑（混合口矩阵）

内核 mixed 端口 7890 监听 127.0.0.1（allow-lan=false 后），经 hdc 转发到 Mac：

```bash
$HDC -t <device> fport tcp:17890 tcp:7890
curl -x http://127.0.0.1:17890 https://www.qq.com       # 应走 DIRECT
curl -x http://127.0.0.1:17890 https://www.youtube.com  # 应走 PROXY
```

**这验证了规则/DNS/内核拨号全部逻辑，但不经过 TUN 数据面**——TUN 面的问题（MTU、dispatchLoop）它测不出来。

### 6.4 模拟器的限制与绕过（Pura X Max 镜像）

- `createVpnConnection` 被拒：`Non-system applications use system APIs`——**永远建不了 TUN**，端到端只能真机。
- 首次启动 `startVpnExtensionAbility` 的 want 不送达 onRequest（扩展进程空跑、内核不起）。绕过：应用启动后手动 `aa start -b org.xbgroup.clashboxLTS -a ClashVpnAbility` 一次，之后 IPC 正常。
- 模拟器无 VPN 授权弹窗，真机首次启动需在弹窗点"允许"。

### 6.5 内核日志级别与埋点

- 内核日志走 hilog tag `flclashGo`，mihomo info 级会打每条连接的 `[TCP] src --> dst using <策略组>` 和拨号错误。
- `lib_linux.go` 的 protect 埋点已提交（仅失败/超时打 error 级）。排查时如需全量 fire/ack，临时加 info 行重编即可（增量构建 <10s）。

## 7. 重建与验证流水线

```bash
# 子模块（GitHub 慢的话用 SSH+SOCKS 代理）
git config url."git@github.com:".insteadOf "https://github.com/"
GIT_SSH_COMMAND="ssh -o ProxyCommand='nc -X 5 -x 127.0.0.1:1086 %h %p'" git submodule update --init --recursive
# gvisor 大仓可定点浅抓：git -C proxy_core/src/flclash/gvisor-ohos fetch --depth 1 origin <sha>

# 工具链（一次）→ 内核 → HAP → 溯源 → 测试
cd <ohos_golang_go>/src && GOROOT_BOOTSTRAP=<官方go1.24目录> GOTOOLCHAIN=local ./make.bash
OHOS_GO=<toolchain>/bin/go bash proxy_core/src/flclash/build.sh arm64
hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
python3 scripts/verify-hap.py entry/build/default/outputs/default/entry-default-signed.hap
npm ci && npm test   # 80 个回归用例（鸿蒙 API mock）
```
