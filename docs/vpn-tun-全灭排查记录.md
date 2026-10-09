# ClashBox VPN/TUN 全灭问题排查记录

> 记录于 2026-10-06 ~ 2026-10-09。本文档沉淀一次"开启 VPN 后国内外网站全部打不开"问题的完整排查过程、已排除的假设、已修复的问题和当前最强嫌疑点，供后续开发者继续。

> 源码复核（基于 `bca0e528`）：本次保留新增的现场日志和计数，修正其解释。Mixed 的 TCP 走 System、UDP 走 gVisor channel；`[TCP] ... using GLOBAL` 出现在出站拨号成功返回之后。现有证据尚不能将全灭归因为 gVisor FD 读取循环退出，详见 §8。

> 2026-10-09 下午真机复测：确认一种可重复的断网原因——手机使用“前台模式(mihomo)”，核心随 UI 进程在后台被冻结；改用 VPN 扩展进程运行的普通 mihomo 后，同一安装包的后台 DIRECT 请求及浏览器 HTTPS 恢复。系统 freezer 状态、成对请求及适用范围见 §10；不据此追认之前全部故障窗口属于同一原因。

> 2026-10-09 晚间复测：用户报告出境易 Chrome 无法访问外网，现场随后在该 Chrome 与原生浏览器均成功加载 Google。另复现批量测速 IPC 提前关闭报错和未测节点误标 timeout；修复及待测范围见 §11，尚不能将它归因为浏览器断网原因。

> 2026-10-09 22:31–22:37 受控复现：Chrome 在 VPN 关闭时取得 `m.youtube.com` 的错误 DNS 结果，VPN 恢复后仍命中该缓存并连接错误 IP，TLS 报 `ERR_CONNECTION_CLOSED`。保持同一节点和 VPN 会话，仅清除 Chrome DNS 缓存后获得 Fake-IP、TLS 1.3 握手成功、首页返回 HTTP 200。Chrome NetLog 与核心日志闭合了这一次失败/恢复的证据链，详见 §13；最初用户故障的触发操作仍不确定。

## 0. 故障时的 TUN 协议栈：Mixed（默认）

**运行栈 = 覆写配置里的 `TunStack` 值，默认 `Mixed`**（`proxy_core/src/main/ets/models/ClashConfig.ts:191`，UI 选项在 `Constants.ets:545-547`），wrapper 经 `common.go:246`（`targetConfig.Tun.Stack = patchConfig.Tun.Stack`）透传给内核。排查期间该设置未改动，故故障时栈为 Mixed：

- **TCP → System 的地址/端口改写与本地 TCP listener**。
- **UDP → gVisor 用户态栈，使用 channel endpoint**。
- TUN 读取由 `Mixed.tunLoop` 执行；上述两条路径均不使用 §5.1 的 gVisor `fdbased.dispatchLoop`。依据是当前实际依赖 [sing-tun v0.4.24 的 stack_mixed.go](https://github.com/MetaCubeX/sing-tun/blob/v0.4.24/stack_mixed.go)：`NewMixed` 嵌入 System，`Start` 创建 channel 并注册 UDP forwarder，TCP 分支调用 `processIPv4TCP`/`processIPv6TCP`。
- 订阅 YAML 无 `tun:` 段时的内核兜底默认是 `TunGvisor`（`core/config/config.go:546`），但被 UI 的 Mixed 覆盖。

故障窗口同时存在 `[TCP] 172.19.0.1:x --> www.youtube.com:443 using GLOBAL` 和 `[UDP] 172.19.0.1:60265 --> www.youtube.com:443 using GLOBAL`。这些是 mihomo 公共连接处理层的日志，本身不区分 System/gVisor/Mixed；UDP 443 也不能单凭端口确认具体应用协议。Mixed 的判定依据是上述配置及验证者报告的设置未改动。

## 0.1 故障窗口的计数器与内核错误日志（同一会话采集）

/proc/net/dev 列含义：`iface: rx_bytes rx_pkts rx_errs rx_drop ... tx_bytes tx_pkts tx_errs tx_drop ...`

| 时间 | 状态 | vpn-tun 计数 | 解读 |
|---|---|---|---|
| 00:55（香港03，记录为工作正常） | 代理出站到 HK，IP 卡显示出口；未附浏览器请求结果 | RX 2876951B/5007p/0err；TX 2878955B/5009p/**603 drop** | 累计 **TX dropped=603**，不是此前记录的 RX errors。只能证明该计数曾增长，不能确定丢包发生时刻、原因或读取循环已退出 |
| 01:19（全灭） | 浏览器全灭 | — | 内核错误日志 3 连：`dial GLOBAL 172.19.0.1:x --> www.peopleapp.com:443 error: 38.135.55.228:44949 connect error: dial tcp: i/o timeout`（protect ok=true 前提下的节点 connect 超时） |
| 01:32（全灭，全局模式） | 浏览器全灭 | — | `[TCP] 172.19.0.1:46718 --> www.youtube.com:443 using GLOBAL`；代码在出站 DialContext 成功返回后打印此行，不能解释为拨号挂起；其后传输结果未知 |
| 01:35~01:39 | 埋点观测 | 重启后 RX 648B/10p（新 TUN） | protect `hook fire/ack ok=true` 全绿（fd 119~178）；wlan0 TX 90s +181 包；只能证明接口总流量增长，未按目标连接归属，不能证明该节点或网页收到数据 |
| 01:41（仍全灭） | 浏览器全灭 | — | 再次出现 youtube 的 TCP+UDP using GLOBAL 记录；TCP 拨号已返回成功，UDP 出站 PacketConn 已创建，均不代表网页响应已收到 |

关键区分：**01:19 是到节点的 TCP connect 超时；01:32/01:41 的 TCP 记录已越过拨号阶段，后续转发结果未知。** 当前记录跨越重启和多个时间段，缺少单次请求的计数增量，不能合并推导为同一故障机制。

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

`proxy_core/src/flclash/tun/tun.go` 创建 sing_tun 监听器时 `MTU: 9000`，而系统 vpn-tun 网卡 MTU=1400（ArkTS `FlClashVpnService.ets:229`）。这是已确认的配置不一致，可能影响大包传输，但尚不能证明它是 TCP 全灭的唯一根因。已改为 `state.CurrentState.Mtu`（默认 1400，越界兜底 1400）。

**但注意：修复后真机矩阵仍未通过（见 §5 当前嫌疑点）。**

## 4. 已有验证及证据边界

1. **已观察到 protect 成功确认**：在 `lib_linux.go initSocketHook` 加埋点后，记录中的出站 fd 都 `hook fire → ack ok=true`（ArkTS `FlClashVpnService.startClash` 的 NAPI `startTun(tunFd, callback)` 回调 → `connection.protect(fd)` → `setFdMap`）。它证明该次保护调用完成，不证明其后目标响应一定可达。
2. **未观察到节点地址的 using GLOBAL 日志**：实际没有 `[TCP] 172.19.0.1:xxx --> <节点IP>:<port> using GLOBAL` 一类记录。但这条日志需要出站拨号成功才打印，因此它的缺失不能彻底排除 SYN 回环。
3. **GEOSITE/GEOIP 数据加载正常**：内核日志 `Finished initial GeoSite rule cn => DIRECT, records: 120120`，geo 文件在 `filesDir/ClashBox/`（mihomo HomeDir）。
4. **节点可达**：VPN 关闭时手机浏览器直连节点 IP:44949 返回 `ERR_EMPTY_RESPONSE`（TCP 已连通，SSR 端口对 HTTP 垃圾数据关连接）；Mac 同网络 `nc -vz` 也通。
5. **订阅转换产物正确**：模拟器上经内核 mixed 口实测（见 §6.3），国内外分流全对。

## 5. 当前最强嫌疑点（未闭环）

### 5.1 gVisor dispatchLoop 单点退出（不在此次 Mixed 的执行路径中）

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

**当前内核 pin 的是 MetaCubeX/gvisor@79317d80**。但故障期间报告使用 **Mixed**（§0），不经过该 FD 读取循环，因此不能以此解释当前现场，也不能据 `tx_drop=603` 推断该循环退出。

`RecvMsgX` 的关联推断也不成立：wrapper 的 `tun/tun.go` 重新构造 `LC.Tun`，没有透传该字段；sing-tun 的 `EXP_RecvMsgX` 对应 Mixed 的 Darwin 批量读取分支，不是 gVisor `PacketDispatchMode`。后者在 `fdbased/endpoint.go:createInboundDispatcher` 中默认 Readv，另行根据 fd 类型和分派模式选择；不能从原始 YAML 默认值推出 OHOS Mixed 在使用 recvmsg/readv。

下一步按 §8 定位拨号后的数据收发。若另行测试纯 gVisor 并捕获到对应读循环退出，再处理该路径的容错问题。

### 5.2 protect() 绑定物理网络的选择

日志里节点拨号"protect ack ok=true 但仍 i/o timeout"存在时段性（01:19 全灭、01:38 正常）。怀疑 protect 绑定到的物理网络与实际有网网络不一致（WiFi/蜂窝切换时）。未取证，仅记录。

### 5.3 干扰项（测试纪律）

- **节点可用性**：104.243.39.45（德国06）曾出现 ICMP 100% 丢包；ICMP 不响应本身不能证明 SSR TCP 端口不可用。测试前需用实际代理请求确认节点，并记录所选节点，避免把节点失败混入 TUN 结论。
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

## 8. 基于新增现场记录的源码复核

复核基线：父仓 `bca0e528`、core `2ee8e103`、gvisor `79317d80`、sing-tun `v0.4.24`。本节是源码与已有现场记录的交叉核对，未新增真机联网测试。

### 8.1 using GLOBAL 是拨号成功之后的日志

`proxy_core/src/flclash/core/tunnel/tunnel.go` 的 TCP 顺序：

1. 第 591–624 行：调用出站 `proxy.DialContext`，执行必要的 early handshake；错误走 `logMetadataErr`。
2. 第 625–628 行：错误直接返回；成功才调用 `logMetadata`，打印 `using GLOBAL`。
3. 第 630–639 行：建立连接统计，结束可能还未完成的 peek，进入 `handleSocket` 双向转发。

因此 01:32 和 01:41 对应的 TCP 连接已经越过出站拨号阶段。若连接来自浏览器 TUN 入站，Mixed 的本地 TCP listener 也已经接收了它；不能把这两条解释成“从启动起 TUN 一直无人读取”。这不排除稍后读循环停止或后续数据包转发失败。

SSR 的 `adapter/outbound/shadowsocksr.go:68` 先连接节点，再执行协议包装及目标地址写入，最后返回出站连接；并不等待目标网站的 TLS/HTTP 响应。因此这条成功日志也不是网页已联网的证据。01:19 的 `connect error: dial tcp: i/o timeout` 则明确发生在到节点的 TCP 建连阶段，应与上述两次分开分析。

UDP 的 `using GLOBAL` 在 `ListenPacketContext` 成功后打印，只证明出站 PacketConn 创建成功，不证明 UDP 目标有响应。

### 8.2 “没有后续日志”不能判断阻塞位置

- `core/tunnel/connection.go:handleSocket` 直接调用 `N.Relay`。
- `core/common/net/sing.go:Relay` 的两个复制方向在出错时关闭连接，但不输出错误或常规完成日志。正常结束、读写失败和仍在等待，都可能没有后续 Info 日志。
- `sing-tun/stack_mixed.go:87` 的 TCP 写回错误只走 Trace，mihomo 将其映射为 Debug，默认 Info 看不到。
- 同文件 `packetLoop:272` 调用 UDP 返回方向的 `m.tun.WritePacket(pkt)` 时直接忽略返回值；即使打开 Debug，这里的写入错误也不会被这段代码记录。

这些是当前明确的诊断缺口，尚不能据此认定具体错误已经在真机发生。下一步开发优先补充可关联连接的双向字节计数、首次收发时间和退出错误，以及限频的 TUN 写入失败/读取循环退出日志。

### 8.3 603 的含义与限制

本次现场记录将之前的“RX errors 603”更正为“TX dropped 603、RX errors 0”。按 [Linux v6.6 TUN 驱动的 tun_net_xmit](https://github.com/torvalds/linux/blob/v6.6/drivers/net/tun.c#L1010)，发送队列满、接口未附着和过滤等路径都可能增加 TX drop；它不是用户态 gVisor 主动丢弃包的专用计数，更不是某个 read/readv errno。

这个数来自 00:55，被记录为工作正常的时段；01:19、01:32、01:41 尚无各次请求前后的完整计数。仅凭累计值无法建立它与断网的因果关系；涉及具体丢包机制还须确认设备内核实现。01:35 重启后的新接口计数也不能直接与旧接口累计值相减。

### 8.4 下一轮只需补齐能区分路径的证据

新增记录解决了“设置使用 Mixed”和“603 属于哪一列”的问题，但仍没有同一故障时刻、同一目标的 TUN/7890 对照结果，或 DIRECT 故障连接的具体日志。现在的明确失败样本主要是 GLOBAL/SSR，尚不能把它直接作为 DIRECT 全灭的实现证据。

先固定 DIRECT 和一个无需 DNS、已确认可访问的 IPv4 HTTP 目标，同时从真机浏览器经 TUN、以及经 hdc 转发该真机的 7890 端口发起请求。两种入口测试时均保持同一真机 VPN 开启、同一网络、同一目标。随后只切换 Mixed/gVisor 重复测试。记录请求时间、有效配置、安装包/内核版本和新建连接，避免复用缓存或旧连接。

现有 `getConnections()`（`proxy_core/src/flclash/hub.go:463`）已提供连接快照，可先采集目标连接的 `id`、`metadata.type`、源端口、目标、`chains`、`upload`、`download` 的连续样本，不必只看全局总速率：

| 拨号成功后，同一连接的变化 | 优先核对 |
|---|---|
| upload/download 都不增长 | 浏览器是否发出 payload、peek/relay 是否开始或提前退出、对应 TUN 数据是否仍被读取 |
| upload 增长、download 不增长 | 出站后续读写错误、节点协议/目标响应或物理网络；结合 7890 同目标结果区分 |
| download 增长、浏览器仍无响应 | 返回浏览器方向的写入、TUN 回包和系统 TCP 接收；这只能作为方向线索，仍需读写错误或抓包确认 |
| 连接很快从快照消失 | 捕获 relay 的 EOF/错误和关闭原因，避免误判成一直挂起 |

这些是应用层统计，不能代替链路抓包；SSR/early handshake 可能已有初始上传量，应看同一连接的增量，而不是只看数值非零。`metadata.type` 也能核对该条到底是 TUN 还是 HTTP/SOCKS 入站。

此前复核确认的 IPv6 参数遗漏、MTU 兜底范围不一致和看门狗只检查启动时间的问题仍应修复，但本次新增日志没有证明它们就是这些 IPv4/GLOBAL 请求失败的根因。

## 9. 待测清单与结果回填

以下项目均为**待执行**，不是已通过结果。先执行 T00–T04，按结果决定后续分支；T05–T09 用于基础通路恢复后的回归。每项完成后填写 §9.4，并将状态改为“通过 / 失败 / 无法执行”，附原始证据位置。

### 9.1 每轮固定条件与必采证据

- [ ] **E01 版本绑定**：记录手机型号、系统版本/API、网络类型、父仓及两个子模块提交、构建模式、所安装 HAP 的 SHA-256、包内 `libflclash.so` 的 SHA-256 和 provenance 检查结果。不能只记录本机源码版本。
- [ ] **E02 有效配置**：记录实际生效的 mode、stack、MTU、IPv4/IPv6 地址与路由、DNS、应用访问控制，以及 GLOBAL 实际选择的节点。stack 以运行日志/有效配置为准；无法读取时明确写“仅根据设置推断”。
- [ ] **E03 请求关联**：每轮生成唯一测试编号，记录带时区的开始/结束时间、目标 IP/端口、完整测试路径、入口（浏览器 TUN 或 HTTP 混合端口）。浏览器使用新请求参数避免缓存，并确认没有自动跳到另一个 HTTPS 目标。
- [ ] **E04 同窗口采样**：保存请求前、请求中（例如 +1、+5、+15 秒）、请求结束后的完整 `/proc/net/dev` 输出，以及可读取的 TUN 错误子项。记录接口重建时间，只计算同一接口实例内的差值；权限拒绝也写入结果。
- [ ] **E05 单连接采样**：连续采集 `getConnections()` 中目标连接的 `id`、`metadata.type`、源端口、目标、`chains`、`upload`、`download`；短连接未被采样到时标记“未捕获”，不能填写零流量。
- [ ] **E06 日志与响应**：保留覆盖整个请求窗口的 Debug 日志，包含 dial、protect、TUN 读写错误。记录 HTTP 状态、响应内容是否符合预期、耗时或明确错误；仅出现 VPN 图标、IP 卡更新或 `using GLOBAL` 不算通过。

T00–T04 固定同一手机、安装包、物理网络、MTU 和 IPv6 设置，关闭其他 VPN/同包实例。准备一个**无需 DNS、已确认可访问的 IPv4 HTTP 服务**，返回可辨认的小响应；若使用局域网服务，先确认目标被系统 VPN 路由接管，不能使用排除路由或应用绕过来代替 TUN 测试。

### 9.2 按顺序执行的真机项目

| 编号 | 状态 | 操作与唯一变化 | 必须记录 / 判定依据 |
|---|---|---|---|
| T00 | 待测 | VPN 关闭，手机浏览器访问测试 HTTP 服务 | 应获得预期响应，建立物理网络基线；失败先处理目标服务/网络，不解释为 TUN 问题 |
| T01 | 待测 | 开启 VPN，DIRECT + Mixed，浏览器访问同一目标 | 采集 E01–E06，确认连接类型为 TUN；记录从建连到首个响应的结果，作为当前问题的最小复现 |
| T02 | 待测 | 保持 T01 的 VPN 和配置不变，经 hdc 转发 7890 后请求同一目标 | 与 T01 配对执行。记录 HTTP 入站及 DIRECT 出站；若仅 TUN 失败，优先查 TUN/本地 TCP 转发；若两者都失败，查共同出站路径 |
| T03 | 待测 | 仅将 stack 改为 gVisor，完整停止/启动 VPN，再重复 T01、T02 | 保存新接口基线与实际 stack。Mixed 失败而 gVisor 成功时优先定位 System TCP 路径；两者失败不能自动归因为同一组件 |
| T04 | 待测 | 在失败的一组配置下重复单个请求，连续记录上下行及退出事件 | 按 §8.4 区分未产生 payload、只上传、已有下载但客户端无响应、提前关闭。若现有日志无法区分，记录“缺少 D01/D02 证据”，不将沉默解释为卡死 |
| T05 | 待测 | 基础 IPv4 DIRECT 通路成功后，先保持同一目标改用其域名，再独立测试 HTTPS | 将 DNS 和 TLS 分成两步；记录解析结果、fake-IP 映射、TLS/HTTP 结果。HTTPS 使用正确域名和证书，避免裸 IP 证书错误干扰 |
| T06 | 待测 | 单独切换 IPv6 开关，每次重启 VPN，分别验证 IPv4 和可用的 IPv6 目标 | 对照系统地址/路由与原生前缀，重点复现关闭 IPv6 仍接管 IPv6 的问题；无 IPv6 基线时标记环境不支持。修复后须验证两端一致及 IPv4 无回退 |
| T07 | 待测 | 保持已通过配置，对同一 HTTP 服务分别请求小响应和较大响应，再单独调整 MTU | 建议小响应约 1 KiB、大响应约 1 MiB，核对完整内容/长度及计数增量。默认 1400 两端必须一致；MTU=1000 的兜底差异先用配置测试验证，不依赖 UI 强行输入非法值 |
| T08 | 待测 | DIRECT 基础测试通过后，仅切为 GLOBAL，选择已用实际代理请求验证可用的节点 | 重复浏览器 TUN / 7890 成对请求并记录真实 `chains`；以网站响应确认节点可用，不用 ICMP 或端口能连接代替 SSR 可用性；单独记录 connect 超时和拨号后的错误 |
| T09 | 待测 | 基础通路通过后，分别做停止再启动、快速启停、后台/锁屏、网络切换 | 各场景分轮执行：建议停止/启动 3 轮、快速启停 5 轮、锁屏 5 分钟，Wi-Fi/蜂窝切换以设备条件为准；每轮操作后发起新请求，核对 TUN/状态/转发一致且停止后恢复普通网络 |

T02 的 Mac 侧示例（替换设备标识和服务地址；代理端口以实际配置为准）：

```bash
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
VPN_TEST_DEVICE='<设备标识>'
VPN_TEST_URL='http://<已验证的IPv4地址>:<端口>/<测试路径>?case=T02-01'
"$HDC" -t "$VPN_TEST_DEVICE" fport tcp:17890 tcp:7890
curl --noproxy '' --proxy http://127.0.0.1:17890 \
  --connect-timeout 10 --max-time 30 --verbose \
  --dump-header T02-01.headers --output T02-01.body \
  --write-out 'status=%{http_code} bytes=%{size_download} total=%{time_total}\n' \
  "$VPN_TEST_URL" 2>T02-01.curl.log
```

TUN 采样示例，每个采样时点分别保存输出（文件名包含测试编号和采样时间）：

```bash
"$HDC" -t "$VPN_TEST_DEVICE" shell cat /proc/net/dev
"$HDC" -t "$VPN_TEST_DEVICE" shell 'for item in rx_bytes rx_packets rx_errors rx_frame_errors rx_length_errors rx_dropped tx_bytes tx_packets tx_errors tx_dropped; do printf "%s=" "$item"; cat "/sys/class/net/vpn-tun/statistics/$item"; done'
```

### 9.3 需要新增诊断代码或修复后执行的项目

下列能力**当前尚未实现**；不能要求现有安装包输出这些日志，也不能仅调高日志等级就认为已覆盖。

- [ ] **D01 双向转发诊断**：关联测试连接，记录 relay 开始、两个方向的字节数/首次收发时间、EOF/错误/关闭原因；用受控断开、读写失败验证事件能被捕获，且记录没有改变正常转发行为。闭合 T04 中“正常等待还是提前退出”的证据缺口。
- [ ] **D02 TUN 收发诊断**：补限频的读写 errno、包长、收发计数和读取循环退出事件；覆盖 Mixed 的 TCP `Write`、UDP `WritePacket` 返回错误以及纯 gVisor 路径，确认无逐包日志洪泛。故障注入后核对事件与计数一致。
- [ ] **D03 数据通路失效与自愈**：受控触发读取循环退出、保持 IPC 可访问，检查运行状态是否仍误报正常；修复后验证能识别失效并按既定策略恢复/报告失败。空闲无流量不应误触发恢复，用户停止后不得被迟到回调重启。
- [ ] **D04 配置一致性回归**：修复 IPv6 参数遗漏与路由过滤后，验证关闭 IPv6 时系统和原生均不配置 IPv6 接管；统一 MTU 归一化规则，并以默认、最小合法、最大合法及越界输入核对两端结果，然后重跑 T01–T03、T06、T07。

### 9.4 每项结果回填模板

复制此模板为每个测试编号建立记录；“未采集”和“无错误”必须区分。

```text
测试编号 / 状态（通过、失败、无法执行）：
执行者 / 时间与时区：
设备 / 系统 / 网络：
父仓 / core / gvisor 提交，HAP 与 libflclash.so 摘要：
有效 mode / stack / MTU / IPv6 / 节点 chains：
目标 / 入口 / 请求开始与结束时间：
HTTP 状态、响应内容/长度、耗时或具体错误：
连接 id / metadata.type / 源端口：
连接 upload、download 连续样本：
同一 TUN 实例的计数前值、后值、差值：
dial / protect / relay / TUN 错误与事件（未采集项注明）：
配对测试编号及结果（例如 T01 与 T02）：
原始日志、响应、配置、快照的文件路径：
本次证据支持的结论 / 仍不能排除的情况：
```

只有基础 DIRECT 的 TUN/7890 对照、协议栈对照及相应错误证据齐备后，才将候选机制提升为根因；真实网页恢复与修复后的回归结果另行记录，不以构建成功或 mock 测试通过替代。

## 10. 2026-10-09 真机复测：前台核心被后台冻结

### 10.1 本次安装包与测试条件

- 时间：2026-10-09 17:38–18:01，Asia/Shanghai；设备 HOP-AL10，HarmonyOS `7.0.0.109(SP6C00E105R6P4)`，API 26，Wi-Fi。
- 测试现有已签名 debug 应用 `org.xbgroup.clashboxLTS`，版本 `1.7.4` / `1007047`；本次未重编、签名或安装新 HAP。
- 从应用沙箱读取实际安装的 HAP，SHA-256：`0822dfe2e33ff97ab1b1aa2acb37e5094551f958acefea17a8532f1c02221856`。
- 安装包内和设备解压目录的 `libflclash.so` 摘要一致：`24eb2cb2491f7b37f3b07406d0f8f4a5ad8f71836c9907a67e160f16067ef643`。它与本地库 `aeb9f41bf7fd3395113c71e5f6aeec02f336f85cf391ddf629812aa7c1b8e44e` 不同。二者 Go build info 均记载 `2e18ae5d...`、`vcs.modified=true`；不能据此认定设备运行的未提交源码与当前仓库完全一致。
- 初始持久化配置：`clashCore=1`，即“前台模式(mihomo)”；RULE、Mixed、MTU 1400、IPv6 关闭、应用访问控制关闭。测试切换到 DIRECT，日志确认 `using DIRECT`；系统网卡实测 MTU 1400。Mixed 根据设置与代码映射判定，未取得原生运行时 stack 快照。
- 核心运行位置 A/B 测试保持同一 HAP、Wi-Fi、DIRECT、协议栈设置及目标不变，仅通过设置切换核心运行模式并按要求重启应用。

### 10.2 证据链

先使用电脑上的受控 HTTP 服务建立网络基线。VPN 关闭时，手机浏览器显示约 1 KiB 测试正文；VPN 开启后局域网页面仍可访问，但没有该浏览器连接进入 TUN 的证据，**这项结果不计为 TUN 通过**。

随后改用无需 DNS 的公网目标 `http://119.29.29.29/`，每次附加不同查询参数。该地址正常返回 HTTP 404 和 174 字节 HTML；本测试检查能否完整取得这个预期响应，404 不代表网络连接失败。

| 核心运行方式 / 阶段 | 系统状态及请求结果 | 结论 |
|---|---|---|
| 前台模式，刚进入浏览器 | 核心 PID 64474；日志出现 `[TCP] 172.19.0.1:33846 --> 119.29.29.29:80 using DIRECT`，浏览器显示预期 404 正文；同时经 hdc 转发 7890 请求收到 174 字节，约 0.085 秒 | 该时刻 TUN 与普通代理入站均能完成 HTTP 传输 |
| 前台模式，退后台后 | 首次采样 `freezer:/Thawed`，7890 请求约 0.143 秒完成；约 10 秒时采样已为 `freezer:/Frozen`，随后多次请求均达到 4 秒超时且接收 0 字节；独立请求也复现 12 秒超时 | 核心所在 UI 进程被冻结，普通代理入口也停止响应；不是只有 TUN 入口失效 |
| 将 ClashBox 带回前台 | 相同公网 IP 经 7890 恢复，174 字节、约 0.150 秒 | 恢复与核心宿主进程回前台相关 |
| 切普通 mihomo，退后台 | UI PID 8304 在约 10 秒时进入 `freezer:/Frozen`；核心移至 VPN 扩展 PID 8531，`freezer:/`。后台 0 / 10 / 25 / 约 42 秒的四次请求均返回预期 174 字节，耗时约 0.108–0.192 秒 | UI 冻结不再阻断扩展进程内的核心 |
| 普通 mihomo，实际网页 | UI 仍被冻结时，浏览器正常显示百度 HTTPS 页面；核心日志记录源地址 `172.19.0.1` 到 `www.baidu.com:443` 的 DIRECT 连接。经 7890 的 HTTPS 对照为 HTTP 200、2443 字节、约 0.269 秒 | 后台运行、浏览器 TUN、域名和 HTTPS 的组合恢复；未独立隔离 DNS 与 TLS 各步骤 |
| 普通 mihomo，手机自动锁屏后 | 经 7890 请求 `https://example.com/` 返回 HTTP 200、577 字节、约 1.033 秒；UI 保持 Frozen、VPN 扩展未被冻结 | 补充短时锁屏下的普通代理入口证据；系统拒绝锁屏启动浏览器，故不计作该网站的浏览器 TUN 验证 |

公网 IPv4 浏览器测试的同一 TUN 实例计数为 RX 520 B / 5 包 → 30545 B / 145 包，TX 520 B / 5 包 → 30497 B / 145 包，errors/drops 均为 0。窗口内有其他系统流量，这些总量仅作辅助证据；目标归属以连接日志和浏览器正文为准。未将跨重启的网卡计数相减。

### 10.3 源码对应与结论范围

- `entry/src/main/ets/entryability/AppState.ets` 中 `ClashCore.ClashMeta=1`，注释明确其用于在 UI 进程运行核心进行开发调试；**复测时 `AppConfig.clashCore` 默认值也是这一模式**，后续修复见 §10.5。
- `ClashViewModel.ets` 的 `startCore()` 在非 `mihomo` 模式调用 `startLocalCore()`，由 UI 上下文创建服务；`ClashVpnAbility.ets` 则只在 `mihomo` 模式中创建 `SocketStubService`。
- 系统 freezer 状态、失败/恢复请求、同包切换核心宿主进程的对照一致，足以确认**本次后台断网复现**由前台核心进程被冻结造成。无需以“Mixed/gVisor 读循环退出”解释本次现象。
- 本次没有验证 GLOBAL 节点出站、gVisor A/B、IPv6、大包、5 分钟锁屏、Wi-Fi/蜂窝切换或完整启停矩阵；之前节点 connect 超时及其他故障窗口仍需独立确认。
- 启动前还遇到过一次代理列表 RPC 在收到完整响应前关闭，界面因此误判节点未加载；重启应用后恢复。现有证据不足以确认它与冻结共因，应作为独立的 IPC/启动稳定性问题跟进。

默认值修复见 §10.5；后续仍应明确前台调试模式的入口及升级迁移策略，并补 UI 冻结后的真实转发回归。单纯延长 IPC 超时或依赖 UI 内的定时器不能使被冻结的进程继续处理网络。

### 10.4 结果与证据位置

本次完成 T00 的局域网基线、T01/T02 的公网小响应对照，以及 T09 中“退后台”的失败复现和切模式恢复对照；T05 取得实际 HTTPS 网页恢复证据。上述均为限定场景结果，不将 §9 中的完整测试项统一标为通过。

本次真机诊断结束时已恢复 RULE 并关闭测试 VPN，确认 `vpn-tun` 消失；保留已验证的普通 mihomo 模式，持久化值为 `clashCore=0`。诊断阶段未修改程序代码。

原始证据保存在本机 `.research/device-20261009/`（Git 忽略，不提交原始订阅、完整沙箱数据或系统日志）：

- `background-timeline.jsonl`、`regular-background-timeline.jsonl`：前台模式与普通模式的 freezer / HTTP 连续样本。
- `T01-public-browser.jpeg`、`T05-baidu-browser.jpeg`、`T05-regular-baidu.jpeg`：初始 IPv4 成功、后台失败和切普通模式后的 HTTPS 恢复。
- `T01-public-before.txt`、`T01-public-after.txt`：同一测试窗口网卡计数。
- `native-live.log`、`target-connection-evidence.log`：核心日志和目标连接摘录。
- `entry-installed.hap`、`libflclash-device.so`、`native-buildinfo-device.txt`：实际安装制品与构建元信息。

### 10.5 默认模式修复与用户补测

用户于 2026-10-09 补充自测结果：切换普通 mihomo 模式、开启 VPN 并选择正确节点后，可以访问国外网站。这是用户对现有安装包的实际使用验证；未提供具体分流模式、节点、目标或连接日志，不将它等同于 T08 的完整 GLOBAL 对照测试。

已将 `AppConfig.clashCore` 默认值改为 `ClashCore.mihomo`，新配置默认由 VPN 扩展进程运行核心。启动参数和核心启动入口缺失配置时原本已回退到 mihomo，本次统一了配置对象的默认值。

默认值修复当时保留了已持久化或从备份恢复的核心选择；旧配置仍为前台模式的用户需要手动选择普通 mihomo。后续将前台模式限制为 Debug 调试功能，并调整了 Release 旧配置处理，见 §10.6。

修复后 `npm run check` 通过：80 项逻辑回归、Go 帧协议/契约竞态测试、RPC 生成检查和原生库 provenance 检查均通过。`devecocli build --modules entry --build-mode debug` 构建未签名 HAP 成功；该新包尚未安装到真机，以上真机证据来自现有签名包切换普通模式后的验证。

### 10.6 前台模式收敛为 Debug 开发者功能

“设置 → 内核”只保留普通 mihomo。Debug 构建另有“开发者选项”页面，可显式选择前台模式，并提示切换应用或锁屏后的冻结风险；Release 的菜单和路由均不开放此入口。

Release 同时在持久化设置加载、备份恢复、卡片配置读取/保存、核心启动及 VPN 扩展启动参数处归一核心模式，防止旧配置或启动参数继续选择前台核心。Debug 保留显式的前台模式选择，普通模式仍为默认值。核心枚举数值保持 0 / 1 / 2，不改变已存储数据的编号。

切换模式先等待 VPN 确认停止，再保存选择并退出应用；停止失败时保留原选择。设置页按条目名称处理“清空数据”，避免插入 Debug 菜单后发生点击错位。简体中文、繁体中文（香港/台湾）及英文提示均不再建议使用已删除的模拟保活功能；旧版本更新日志作为历史记录保留。

新增回归覆盖 Release 的旧配置/启动参数处理、两种备份恢复入口、卡片配置、Debug 页面访问、核心切换等待/失败，以及菜单与清空数据的路由对应。`npm run check` 的 88 项逻辑回归、Go 竞态测试及协议/原生库检查通过；Debug、Release 两种未签名 HAP 均构建成功。真机仍运行此前的签名包，新页面和 Release 迁移尚需安装同次签名构建后验证。

## 11. 2026-10-09 晚间：出境易 Chrome 与测速 IPC 复测

### 11.1 现场结果与边界

用户反馈规则模式下国内网站可访问、国外网站失败，并确认失败应用是出境易里的 Chrome。以下操作使用手机现有签名 Debug 包（`org.xbgroup.clashboxLTS`，1.7.4 / 1007047），不是本节新修复的安装包。现场为普通 mihomo、RULE、Mixed TUN、MTU 1400；本轮未切换核心、规则模式或节点。

| 操作 | 观察 | 能证明的范围 |
|---|---|---|
| 经 HDC 转发访问手机 mixed HTTP 代理端口 | Google、Baidu、example.com 返回成功 | 手机核心代理端口和出站可用，此路径绕过 TUN |
| 原生浏览器访问 Google 首页并搜索 | 页面加载，核心日志记录 TUN 源地址 `172.19.0.1` 的 Google 请求走 PROXY | 原生浏览器的 TUN HTTPS 转发在该窗口可用 |
| 约 21:19，在出境易 Chrome 地址栏重新输入 Google 地址并访问 | Google 首页加载，Google 相关 TUN 请求走 PROXY | 出境易 Chrome 在该窗口也可用，不能断定是应用兼容性问题 |
| 约 21:21，配置页点击右上角刷新 | 核心重载成功，随后代理端口 HTTP 200、原生浏览器新的搜索结果加载 | 此次刷新没有造成持续断网，不代表所有刷新场景均通过 |
| 约 21:23，代理页批量测速 | 前两批已有结果，后续批次报“连接已关闭，未收到完整响应”；余下 22 个节点均被标成 -1 | 复现测速通信错误及未测结果误标；同一窗口代理端口 Google 仍返回 HTTP 200 |
| 21:31，测速报错后原生浏览器搜索 OpenHarmony | 新搜索结果加载，日志确认 Google 流量经 TUN 走 PROXY | 此次测速错误后 TUN 转发仍可用 |

主页保存的当前节点名与 RULE 实际使用的节点不同，检查发现分别属于 GLOBAL 和 PROXY 组；不能单凭这两个名称不同判定节点切换失败。本轮没有捕获最初 Chrome 失败请求的成对连接证据，断网根因仍未确认。

### 11.2 已修复的通信和显示缺陷

原实现 `rpcframe.Session.Send(..., true)` 写完帧即通知完成，Go handler 随即关闭连接；ArkTS 收到 close 会立即清理消息监听并报错。[OpenHarmony LocalSocket 实现](https://github.com/openharmony/communication_netstack/blob/c8586cd76da91b90b34b1d700fd000c44ec24e14/frameworks/js/napi/socket/socket_exec/src/local_socket_exec.cpp) 将消息、关闭分别异步派发，[底层事件调度](https://github.com/openharmony/communication_netstack/blob/c8586cd76da91b90b34b1d700fd000c44ec24e14/utils/napi_utils/src/napi_utils.cpp) 使用独立 libuv 工作项。由此推断关闭回调可能先于已排队的消息回调，能够解释“响应已写出、客户端仍报未收到完整响应”；尚未在该手机系统内部插桩证明回调顺序。

修复后由客户端解析完整响应后主动关闭连接，Go 等待该关闭再释放 Session；最终响应后最多等 5 秒，未响应请求保留原 55 秒上限。写失败、断开连接和超时仍可回收，拒绝重复最终响应，协议校验错误响应同样遵循该关闭顺序。

通信失败或响应缺少结果时，未取得结果的节点改用 -2 表示，代理页、主页与桌面卡片显示 `—`；节点实际返回 -1 才显示 `timeout`。列表复用时重新读取对应节点的延迟，避免沿用旧行结果。保持节点失败不弹汇总提示、服务通信失败只提示一次并停止后续批次的行为。

### 11.3 验证与后续待测

本地逻辑回归、Go 竞态测试、RPC 生成检查、原生库来源与产物一致性检查，以及 Debug / Release 未签名 HAP 构建通过。原生库已从本次源码重新编译。真机尚未安装本节修复包，以上联网证据不能替代新包验证。

- 安装同次签名构建后，重复查询代理组、刷新配置及多批测速，确认不再出现由服务端正常完成引起的提前关闭错误。
- 混合可用/超时节点、主动停止核心、连续点击测速：实际失败显示 timeout，未完成显示 `—`，既有成功结果保留，页面与桌面卡片一致。
- Chrome 与原生浏览器分别在刷新前后、测速前后、后台和锁屏后访问新页面；如再失败，同一窗口收集目标、模式、实际命中组、核心错误与页面结果，不以测速 timeout 直接推断断网。

脱敏后的结论记录于此；原始布局、系统日志及配置快照仅保存在 Git 忽略的 `.research/regression-*`，不提交订阅凭据或完整浏览数据。

## 12. 2026-10-09 21:53–22:05：Chrome 的 m.youtube.com 间歇性失败

用户再次反馈出境易 Chrome 无法打开 `m.youtube.com`。本轮真机仍为 §11 的现有签名包，版本 1.7.4 / 1007047，安装更新时间未变；刚推送的 `ab6c8de6` IPC 修复尚未安装。因此，本轮故障与恢复都不能用于判断该新修复的效果。

### 12.1 对照结果

- 21:53，Chrome 原页面明确显示 `ERR_CONNECTION_CLOSED`，刷新仍失败；后续也观察到 `ERR_CONNECTION_ABORTED`。
- 当前规则模式实际使用 PROXY 的“香港04”节点，与 §11 的“香港03”不同；本轮排查未切换节点或 VPN 设置。
- 21:54，同一核心的 mixed HTTP 代理端口访问 `m.youtube.com` 返回 302（跳转桌面版），`www.youtube.com` 返回 HTTP 200 / 948173 字节，Google 返回 HTTP 200。此对照绕过 TUN，只证明核心出站当时可用。
- 同一时间手机原生浏览器打开 `m.youtube.com`，出现 YouTube 首页、搜索及 Shorts 导航；日志记录 `172.19.0.1` 到 `m.youtube.com:443` 经 PROXY 转发，证明原生浏览器的 TUN HTTPS 路径可用。
- 22:01，在 Chrome 新建标签页、输入完整 `https://m.youtube.com/` 并打开，成功加载首页。对应日志在 22:01:31 记录 `m.youtube.com:443`，随后出现图片和 Google Video 域名的代理连接。
- 返回原来失败的标签页后也恢复加载。结束时保留原标签页的正常 YouTube 首页，关闭本轮创建的额外标签页；VPN 保持开启。未改程序、节点、分流规则、DNS、QUIC 设置，也未清除浏览缓存或登录数据。

### 12.2 结论与证据限制

本次确实复现了 Chrome 失败，但在无需修改 VPN 配置的情况下恢复。原生浏览器与代理端口成功的对照，不支持“当时节点完全不可用”或“TUN 全面断网”的解释。**截至本轮结束，尚未确定 Chrome 最初失败的根因，不据此修改 TUN 或禁用 QUIC。** 后续受控复现已确认一种导致同样错误的 DNS 缓存机制，见 §13。本轮只确认页面加载，未以人工播放验证完整视频流。

失败窗口附近核心日志出现纯 IP 目标（例如 `157.240.7.20`），成功窗口出现 `m.youtube.com` 域名。旧 DNS 缓存或旧连接状态是待查方向；缺少 Chrome 请求与这些 IP 的对应证据，不能直接认定 YouTube 被解析到该 IP，也不能断言新标签页本身解决了问题，期间还可能有缓存自然过期。

Chrome 的 `chrome://net-export` 已开启一次默认“Strip private information”采集并停止，记录保存在手机 Chrome 自有目录；该次采集期间新请求已经恢复，当时尚未取回日志，不称其为已捕获故障请求的 Chrome 证据。后续已通过本地导出取回，确认其记录了恢复阶段的 Fake-IP 请求，见 §13。HDC 到 Chrome 调试 socket 的连接被重置，未建立 DevTools 会话。临时端口转发和主机 hilog 抓取均已停止。

现场证据仅保存在忽略目录 `.research/youtube-*`：initial / after-reload / chrome-current 布局记录错误，native / recorded-result / oldtab-result / final 布局记录恢复，live-core.log 记录对应时间线。再次复现时，应在失败仍持续的窗口取得 Chrome NetLog，将目标域名、解析地址、连接错误与核心日志对应，再分别对照重新导航、临时 DNS/连接缓存清理的影响；避免在取得证据前同时切节点、重启 VPN、清缓存。

## 13. 2026-10-09 22:31–22:37：确认错误 DNS 缓存在 VPN 恢复后继续被使用

### 13.1 条件和采集方法

真机仍运行 §11–§12 的现有签名 Debug 包，未安装 `ab6c8de6` 的 IPC 修复。受控实验开始时现场已为普通 mihomo、GLOBAL、“香港02-会员专享”、Mixed、MTU 1400，应用访问控制关闭；这是本轮固定条件，不能与 §12 的 RULE / 香港04 混为一组对照。Chrome 版本为 150.0.7871.186，运行于出境易容器内。

通过 Chrome `chrome://net-export` 采集默认脱敏 NetLog，停止后使用系统“另存为”导出至手机本地 Download 目录，再经 HDC 取回；没有发送邮件或上传日志。同步采集 `flclashGo` 和应用日志，以 NetLog 的时间偏移换算为 Asia/Shanghai，与核心日志对齐。默认脱敏文件仍可能含 URL、请求头等浏览信息，原始文件只保存在 Git 忽略的 `.research/`，本文仅保留必要的事件和地址。

前两轮用于确认现象和调整采集：VPN 关闭时 DNS 诊断页曾得到 `31.13.92.37`，但诊断页的缓存不能代替页面实际使用的缓存；第一次仅凭诊断页复现不构成闭环。第三轮在 VPN 关闭时清理 Chrome DNS 缓存并实际访问目标页面，取得以下完整证据。

### 13.2 失败与恢复的成对时间线

以下时间均为 2026-10-09，Asia/Shanghai。最后一次 VPN 启动为 22:32:20，之后直至 DNS 清理和页面恢复没有再重启 VPN、换节点或改配置。

| 时间 | Chrome NetLog / 页面 | 同窗口核心证据与解释 |
|---|---|---|
| 22:31:57 | 实验主动关闭 VPN | 为生成 VPN 未接管时的 DNS 缓存建立受控条件，不代表用户最初也做过该操作 |
| 22:32:02.663 | `m.youtube.com` 的 DNS 任务提取到 `104.244.42.197` | 本轮错误目标的来源是浏览器解析结果，不再仅根据核心纯 IP 日志猜测域名 |
| 22:32:20 | VPN 恢复，保持 GLOBAL / 香港02 | 随后的页面失败发生在 VPN 已恢复的窗口 |
| 22:32:38.205–22:32:47.032 | TCP 连接目标 `104.244.42.197:443`，TLS 握手报 `-100 / ERR_CONNECTION_CLOSED` | 22:32:39.335 核心记录 `172.19.0.1:60298 --> 104.244.42.197:443 using GLOBAL`，浏览器请求进入 TUN 并被转发到旧 IP |
| 22:32:47.038–22:33:13.786 | 多次 `HOST_RESOLVER_MANAGER_CACHE_HIT` 命中同一 IP，重复 TLS `ERR_CONNECTION_CLOSED`；22:32:57 的新页面请求仍如此 | 核心对应记录同一目标的多次 GLOBAL TCP 连接；刷新页面和恢复 VPN 没有使该缓存失效 |
| 22:35:45.862 | 恢复实验的新 NetLog 仍记录缓存命中 `104.244.42.197`，页面保持失败 | 22:35:45.932 核心仍向该 IP 转发，故恢复对照确实从失败状态开始 |
| 22:36:13.135 | 只点击 `chrome://net-internals/#dns` 的 **Clear host cache** 并重新访问后，DNS 返回 `198.18.0.88` | 获得当前核心的 Fake-IP，22:36:13.232 核心目标恢复为 `m.youtube.com:443 using GLOBAL` |
| 22:36:13.575–22:36:13.974 | TLS 1.3 握手成功；首页请求（source 13154）收到 **HTTP 200**，手机显示 YouTube 首页 | 同一 VPN 会话、同一节点恢复；本轮未清登录数据、网页缓存或 socket pool，也未禁用 QUIC |

失败 NetLog 中该域名的缓存项 TTL 为 `599999 ms`（约 10 分钟），缓存分区为 `https://youtube.com same_site`。这解释了 VPN 恢复后持续使用旧结果的机制，但不表示每次故障必然持续 10 分钟。日志中的 DNS 配置为局域网解析器 `192.168.31.1:53`，DoH 服务器列表为空、DoT 未启用；未抓取解析器上游报文，不能进一步断言错误答案由路由器、运营商或其他具体设备产生。

结论是：**本次复现由 VPN 未接管时取得的错误 DNS 答案被 Chrome 缓存，VPN 恢复后浏览器继续按错误 IP 发起 TLS；仅清除该 DNS 缓存即可恢复。** 已有实际请求、缓存命中、TUN 目标、TLS 错误以及 DNS 单变量恢复证据，不再只是“旧 DNS 可能有影响”的假设。错误在 TCP/TLS 路径复现，没有据此禁用 QUIC 的理由。

### 13.3 代码为什么没有纠正旧目标

修复前（`ab6c8de6`）的默认嗅探配置见 `proxy_core/src/main/ets/models/ClashConfig.ts` 的 `SnifferDefault`：

- `enable`、`force-dns-mapping`、`parse-pure-ip` 为 true，但全局 `override-destination` 为 **false**。
- HTTP 单独设置 `override-destination: true`；TLS / QUIC 仅设置端口 443、8443，因此继承全局 false。
- `core/config/config.go` 的 `parseSniffer()` 先取全局值，仅在协议显式设置时覆盖。
- `core/component/sniffer/dispatcher.go` 的 `replaceDomain()` 无论是否覆盖都会设置 `metadata.SniffHost`，但只有 `overrideDest=true` 才设置 `metadata.Host` 并清空 `metadata.DstIP`。

因此，即使 TLS 嗅探成功，默认行为也不会将已缓存的错误 IP 改回域名进行出站连接。GLOBAL 只改变代理选择，不能自行修正目标地址。现场纯 IP 日志不能证明嗅探未启用；本轮没有嗅探内部事件，也没有取得安装包全部源码的精确对应，以上是当前源码的明确行为及修复方向，不冒充已完成的嗅探插桩或新包验证。

本轮诊断提出的修复方向是 TLS 嗅探后覆盖目标，并处理已有持久化配置、用户显式配置与需要跳过的域名；后续实现和本地验证见 §14。仍应使用同样的“VPN 关闭时形成错误缓存 → 开启 VPN 后访问”的真机对照验证效果，另测正常域名、DIRECT、规则模式、无可用 SNI 或不可嗅探流量，避免把配置改动视为无条件有效。

### 13.4 结论边界、现场恢复与证据位置

用户对最初失败前是否提前打开 Chrome 或切过节点回答“没有上述操作／不确定”。所以本次受控复现确认了具体故障机制，**不能反推用户最初的操作顺序，也不将 21:53 未捕获的原始请求或之前所有断网都追认为这一原因**。视频完整播放仍未独立验证。

本轮只进行了真机诊断和文档更新，没有修改程序代码或安装新包。结束时保留开启的 VPN、GLOBAL / 香港02；Chrome 原标签页已恢复 YouTube 首页，关闭额外测试标签页，停止 NetLog 和主机日志采集，移除调试端口转发及本次创建的公共导出/临时文件。

原始证据仅保存在本机 Git 忽略目录：

- `.research/rootcause-chrome-netlog-round3.json`：失败轮次，含解析、缓存命中、TCP 和 TLS 错误；对应 `.sanitized.json` 仅保留诊断字段。
- `.research/rootcause-chrome-netlog-recovery.json`：清理 DNS 前仍失败、清理后取得 Fake-IP 和 HTTP 200；对应 `.sanitized.json` 记录同一时间线。
- `.research/rootcause-live-core.log`、`rootcause-live-app.log`：VPN 启停、目标 IP 和恢复后的域名转发。
- `.research/rootcause-on3-error-final.jpeg`、`rootcause-after-clear.jpeg`：VPN 开启时 Chrome 报错及仅清理 DNS 后恢复的页面。
- `.research/rootcause-chrome-netlog-old.json`：§12 采集的旧日志，仅覆盖此前已恢复的请求，不作为本轮失败证据。

## 14. TLS 目标纠正与旧默认配置迁移

### 14.1 实现

`SnifferDefault.sniff.TLS` 显式设置 `override-destination: true`，适用端口仍为 443 / 8443。嗅探到可用 SNI 后，现有核心会恢复目标域名并清空旧 IP，解决 §13 中浏览器沿用错误 DNS 缓存的路径。全局覆盖值、HTTP、QUIC、源/目标地址及域名排除项均保留原行为，没有修改 Go 核心、IPC 或 TUN 实现。

新增 `models/SnifferMigration.ts`，用固定的旧版默认配置指纹识别可迁移设置；比较不依赖 JSON 对象属性顺序。仅与旧默认值完全一致的嗅探配置自动升级，禁用嗅探、显式 TLS 覆盖、不同端口/排除项或额外字段均保留。没有嗅探配置时补齐默认值，保留自定义的 `snifferDefault` 回退；同步更新旧的默认模板，防止兼容模式页面重新使用旧值。

`snifferDefaultsVersion=1` 标记完成迁移，新建配置直接带版本号，迁移后用户关闭 TLS 覆盖不会在下一次加载时被重新打开。入口覆盖 AppState 持久化加载、文件/对象两种备份恢复、卡片配置读写和激活快照准备。路由模式、节点选择、DNS、hosts 和原始订阅 YAML 不由此迁移改写。

旧版没有保存编辑历史，无法区分“未修改默认值”和“用户显式保存了一份完全相同的默认配置”，两者都会迁移。自定义配置保持原样时，如需启用纠正，可在“覆写 → 网络 → 兼容模式 → Sniff”的 TLS 项显式设置 `override-destination: true`；需要关闭则设为 false，并应用覆写配置。协议项优先于全局 `Override Destination`。

### 14.2 本地验证结果

- `npm run check` 通过：106 项逻辑回归、Go 帧/契约竞态测试、RPC 生成一致性和原生库 provenance 检查。逻辑回归覆盖新默认值、属性顺序变化、迁移幂等、自定义/禁用/显式覆盖保护、未来版本保留、模板回退、持久化加载、两种备份恢复、卡片读写和配置激活载荷。
- `npm run test:sniffer` 通过，带 Go `-race`：实际 ArkTS 默认值及迁移结果经固定版本 mihomo 的配置解析器和 TCP 嗅探器运行；真实 TLS ClientHello 在旧配置下保留 `104.244.42.197`，在新配置/迁移配置下恢复 `m.youtube.com` 并清空旧 IP。10 个场景还覆盖 8443、显式关闭、跳过域名/源地址/目标地址、未配置端口和无 SNI；逐项确认请求字节未被嗅探消费或改写。测试只使用进程内连接，不访问 YouTube，也不等同于完整 TLS 握手或真实出站成功。
- Debug / Release 未签名 HAP 均构建成功；最终 Release HAP 的原生库及包内来源一致性检查通过。原生源码未变，本次无需重建 `.so`。

原生集成入口为 `scripts/test-sniffer.cjs` 和 `tests/sniffer_destination_test.go`，需要已初始化的核心子模块及 Go 依赖，可使用 `GO_BIN` 指定宿主 Go；无需子模块的轻量 CI 仍执行 `npm run check`。本地日志保存在忽略目录 `.research/tls-*.log`。

### 14.3 真机待测

开始验证修复时 HDC 已无连接设备，用户确认暂时无法连接、先完成本地验证。本次未安装新包、未声称真机修复已通过；§13 的恢复证据来自旧包清除 DNS 缓存，不能替代以下新包验证。

- [ ] 同次签名构建覆盖安装，保留旧默认配置，确认 TLS 项迁移成功且重复启动不会覆盖后续的显式关闭。
- [ ] 固定 GLOBAL / 可用节点，在 VPN 关闭时形成错误域名缓存，开启 VPN 后**不清除 Chrome DNS 缓存**重新访问；关联 NetLog、核心嗅探/目标日志、HTTP 状态与页面，确认目标被纠正且页面成功。
- [ ] 相同条件显式关闭 TLS 覆盖，确认旧错误缓存仍能复现失败；重新开启后用新连接验证恢复，避免将缓存自然过期误当成修复效果。
- [ ] RULE / DIRECT、正常 HTTPS、原生浏览器、排除域名/地址、QUIC 与视频实际播放分别回归；无 SNI / 嗅探失败不能被视为已修复目标纠正。
- [ ] 冷启动、桌面卡片启动、旧备份恢复和覆写配置应用后均核对有效 TLS 策略，自定义配置保持原值。
