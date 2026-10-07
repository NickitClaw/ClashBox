import { vpnExtension, socket } from '@kit.NetworkKit';
import {
  startTun, stopTun, setFdMap, getVpnOptions, startLog, getProxies, getTraffic,
  getTotalTraffic,
  getExternalProviders,
  asyncTestDelay,
  updateConfig,
  initClash,
  changeProxy,
  forceGc,
  updateExternalProvider,
  getCountryCode,
  updateGeoData,
  sideLoadExternalProvider,
  getConnections,
  closeConnections,
  closeConnection,
  validateConfig,
  registerMessage,
  getRequestList,
  clearRequestList,
  startListener,
  stopListener,
  startIpc
} from 'libflclash.so';
import { Address, AddressWithPrefix, CommonVpnService, cidrToRoute, VpnConfig } from './CommonVpnService';
import { JSON, util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { RpcRequest } from './RpcRequest';
import { ClashRpcType } from './IClashManager';
import { ConnectionInfo, LogInfo, Proxy, Provider, ProxyGroup, ProxyMode, ProxyType, Traffic } from '../models/Common';
import { getHome, getProfilePath } from '../appPath';
import { ClashConfig, Tun, UpdateConfigParams } from '../models/ClashConfig';
import { readFile, readFileUri, readText } from '../fileUtils';
import { publishReconnectNotice, VpnNoticeController } from './VpnNoticeController';

export interface AccessControl {
  mode: string
  acceptList: string[]
  rejectList: string[]
  isFilterSystemApp: boolean
}

/** VPN 串行队列的操作类型 */
type VpnOpType = 'start' | 'stop' | 'heal'

interface VpnOpItem {
  op: VpnOpType
  resolves: Array<(v: boolean) => void>
}
export interface VpnOptions {
  enable: boolean,
  port: number,
  ipv4Address: string,
  ipv6Address: string,
  ipv6?: boolean,
  accessControl: AccessControl,
  systemProxy: boolean,
  allowBypass: boolean,
  routeAddress: string[],
  bypassDomain: string[],
  dnsServerAddress: string,
  /** 最大传输单元: 缺省 1400 */
  mtu?: number,
}


export class FlClashVpnService extends CommonVpnService {
  vpnConnection: vpnExtension.VpnConnection | undefined
  public configPath: string = ""
  protectSocketPath: string = ""
  private textDecoder: util.TextDecoder = new util.TextDecoder()

  override async onRemoteMessageRequest(client: socket.LocalSocketConnection, message: socket.LocalSocketMessageInfo): Promise<void> {
    let request = JSON.parse(this.textDecoder.decodeToString(new Uint8Array(message.message))) as RpcRequest
    let code = request.method
    let params = request.params
    try {
      let result = await this.onRemoteMessage(code, params)
      this.sendClient(client, JSON.stringify({ result: result, error: undefined }))
    } catch (e) {
      console.error(`socket stub ${code} result: `, e.message ?? e, e.stack)
      this.sendClient(client, JSON.stringify({ error: e.message ?? e }))
    }
  }
  /** 防止多次调用 stopVpn 导致 stopTun 重复执行 */
  private isStopped: boolean = false
  /** 常驻通知控制器（惰性创建：字段初始化时 context 尚未由父类构造函数赋值） */
  private _noticeController: VpnNoticeController | undefined
  private get noticeController(): VpnNoticeController {
    if (!this._noticeController) {
      this._noticeController = new VpnNoticeController(this.context)
    }
    return this._noticeController
  }
  /** 内核 IPC 看门狗定时器 */
  private watchdogTimer: number = -1
  /** 连续自愈失败次数 */
  private healFailures: number = 0
  /** VPN 是否处于"应当运行"状态：自愈探活只在其为 true 时进行；stopVpn 与自愈最终失败时置 false */
  private vpnActive: boolean = false
  /** 内核失联自愈最大重启次数，超过后发"点击重连"通知并停止重试 */
  private static readonly MAX_HEAL_FAILURES: number = 3
  /** 看门狗探活间隔 */
  private static readonly WATCHDOG_INTERVAL_MS: number = 5000
  /** VPN 启停/自愈操作串行队列：互斥执行 + 排队合并，杜绝并发交叉产生的中间态 */
  private vpnOpRunning: boolean = false
  private vpnOpQueue: VpnOpItem[] = []

  onRemoteMessage(code: number, data: (string | number | boolean)[]): Promise<string | number | boolean> {
    // 根据code处理客户端的请求
    return new Promise(async (resolve, reject) => {
      switch (code) {
        case ClashRpcType.startClash: {
          // startListener/stopListener 已移入串行 op 内部，保证与 TUN 启停的顺序
          this.enqueueVpnOp('start').then((r) => {
            resolve(r)
          }).catch((e: Error) => {
            reject(e)
          })
          break;
        }
        case ClashRpcType.stopClash: {
          this.enqueueVpnOp('stop').then((r) => {
            resolve(r)
          }).catch((e: Error) => {
            reject(e)
          })
          break;
        }
        default: {
          resolve("不支持当前操作")
        }
      }
    })
  }

  ParseConfig(): VpnConfig {
    let vpnConfig = new VpnConfig();
    let option = JSON.parse(getVpnOptions()) as VpnOptions
    // 根据 ipv6 开关决定是否启用 IPv6 地址和路由
    const vpnIpv6Enabled = option.ipv6 !== false
    if (option.ipv6Address == undefined || option.ipv6Address == "") {
      option.ipv6Address = "fdfe:dcba:9876::1/126"
    }
    if (option.routeAddress == undefined) {
      option.routeAddress = []
    }
    if (option.ipv4Address != "") {
      const ips = option.ipv4Address.split("/")
      console.debug("tunIp ", ips)
      const prefixLength = ips.length > 1 ? parseInt(ips[1]) : 30
      vpnConfig.addresses[0] = new AddressWithPrefix(new Address(ips[0], 1), prefixLength)
      vpnConfig.isIPv4Accepted = true
    }
    if (vpnIpv6Enabled && option.ipv6Address != "") {
      const ips = option.ipv6Address.split("/")
      const prefixLength = ips.length > 1 ? parseInt(ips[1]) : 126
      vpnConfig.addresses.push(new AddressWithPrefix(new Address(ips[0], 2), prefixLength))
      vpnConfig.isIPv6Accepted = true
    }
    const routeAddresses: string[] = []
    const addRouteAddress = (cidr: string) => {
      if (cidr != "" && !routeAddresses.includes(cidr)) {
        routeAddresses.push(cidr)
      }
    }
    // Explicit defaults avoid OHOS auto-generating only fe80::/derived IPv6 coverage.
    option.routeAddress?.forEach(addRouteAddress)
    if (option.ipv4Address != "") {
      addRouteAddress("0.0.0.0/0")
    }
    if (vpnIpv6Enabled && option.ipv6Address != "") {
      addRouteAddress("::/0")
    }
    routeAddresses.forEach((cidr) => {
      const route = cidrToRoute(cidr)
      if (route != null) {
        vpnConfig.routes.push(route)
      }
    })
    if (option.accessControl?.mode) {
      if (option.accessControl?.mode == "AcceptSelected") {
        vpnConfig.trustedApplications = option.accessControl?.acceptList
      } else {
        vpnConfig.blockedApplications = option.accessControl?.rejectList
      }
    }
    if (option.dnsServerAddress && option.dnsServerAddress != "") {
      vpnConfig.dnsAddresses = [option.dnsServerAddress]
    } else {
      vpnConfig.dnsAddresses = ["172.19.0.2"]
    }
    // ★ MTU: 优先使用用户配置(1280-65535), 缺省 1400
    vpnConfig.mtu = (option.mtu && option.mtu >= 1280 && option.mtu <= 65535) ? option.mtu : 1400
    if (option.systemProxy || option.allowBypass) {
      // TODO ohos 不支持
      // not use option.bypassDomain option.port
    }
    console.debug("vpnConfig", JSON.stringify(vpnConfig))
    return vpnConfig;
  }
  /**
   * VPN 启停/自愈统一入口：互斥执行 + 排队合并。
   * - 相邻同类型 op 合并（搭车同一结果），快速连点 start/stop 不会叠加执行；
   * - 后到的 stop 会取消仍在排队（未开始执行）的 start 并直接回 true——
   *   状态随后被 stop 收敛，且避免 UI 侧 startClash 收到 false 后的重试把 VPN 又拉起来。
   */
  private enqueueVpnOp(op: VpnOpType): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      if (op == 'stop') {
        for (const pending of this.vpnOpQueue) {
          if (pending.op == 'start') {
            pending.resolves.forEach((r) => {
              r(true)
            })
          }
        }
        this.vpnOpQueue = this.vpnOpQueue.filter((p) => p.op != 'start')
      }
      const tail = this.vpnOpQueue[this.vpnOpQueue.length - 1]
      if (tail && tail.op == op) {
        tail.resolves.push(resolve)
      } else {
        this.vpnOpQueue.push({ op: op, resolves: [resolve] })
      }
      this.drainVpnOps()
    })
  }

  private async drainVpnOps(): Promise<void> {
    if (this.vpnOpRunning) {
      return
    }
    this.vpnOpRunning = true
    try {
      while (this.vpnOpQueue.length > 0) {
        const head = this.vpnOpQueue.shift()!
        let result = false
        try {
          if (head.op == 'start') {
            result = await this.startVpnInternal()
          } else if (head.op == 'stop') {
            result = await this.stopVpnInternal()
          } else {
            result = await this.healKernelInternal()
          }
        } catch (e) {
          console.error(`ClashVPN op ${head.op} 执行异常: ${(e as Error).message}`)
        }
        head.resolves.forEach((r) => {
          r(result)
        })
      }
    } finally {
      this.vpnOpRunning = false
    }
  }

  override async startVpn(): Promise<boolean> {
    return this.enqueueVpnOp('start')
  }

  override stopVpn(): void {
    this.enqueueVpnOp('stop')
  }

  async startVpnInternal(): Promise<boolean> {
    // ★ 重置停止标记，允许下次 stopVpn 正常关闭资源
    this.isStopped = false
    // startListener 在串行 op 内执行，保证与 stop op 内的 stopListener 严格有序
    startListener()
    if (this.vpnConnection) {
      this.vpnConnection.destroy()
      this.vpnConnection = undefined
      // 系统级 VPN 连接销毁后需要时间回收 TUN 路由/protect 通道，
      // 立即重建（卡片冷启动→关闭→UI 再启动场景）会叠加残留状态，
      // 后台大流量时 protect 超时 → 流量回环 → 代理与直连全断
      await new Promise<void>((resolve) => {
        setTimeout(resolve, 500)
      })
    }
    let config = this.ParseConfig();
    let tunFd = -1
    try {
      tunFd = await super.getTunFd(config)
      if (tunFd > -1) {
        this.startClash(tunFd)
        // VPN 激活：发布常驻通知（扩展进程存活期间持续刷新），并启动内核 IPC 看门狗
        this.vpnActive = true
        this.noticeController.start()
        this.startKernelWatchdog()
      }
      return tunFd > -1;
    } catch (error) {
      console.error("ClashVPN  error ", error)
      return false
    }
  }

  /**
   * 启动内核 TUN 并建立 protect 通道。
   * protect 走 NAPI 线程安全回调（startTun 第二参数）：Go 端 StartTUN 的 markSocket 钩子
   * 每创建一个出站 socket 即回调一次 (id, fd)，本进程 protect 后 setFdMap 确认。
   * 注：原实现经 clash_go.sock 转发 protect 请求，但 Go 端 handleConnection 单读单写后即
   * defer close，StartTUN 之后的 fd 推送实际无法到达（连接已关闭），NAPI 直连彻底规避该问题。
   */
  startClash(tunFd: number) {
    console.error("ClashVPN startTun", tunFd)
    startTun(tunFd, (id: number, fd: number) => {
      // 每个 fd 独立异步处理：Go 侧每个出站 socket 都等待 protect 完成（最长 5s），
      // 串行 await 会让前一个 protect 阻塞后续 fd，后台 JS 线程受限时更易超时
      // → socket 未保护 → 流量回环进 TUN → DNS 全断。
      this.protectWithRetry(fd, 3).then(() => {
        setFdMap(id)
      }).catch((protectErr: Error) => {
        // 重试仍失败：打 hilog 点便于确认后台 protect 是否被系统中断（hilog | grep ClashVPN protect）
        console.error("ClashVPN protect failed after retry, skipping setFdMap for fd.id=" + id, protectErr.message)
      })
    })
  }

  stopVpnInternal(): boolean {
    if (this.isStopped) return true
    this.isStopped = true
    // 正常停止路径：先摘看门狗与常驻通知，保证不会误触发内核自愈
    this.vpnActive = false
    this.healFailures = 0
    this.stopKernelWatchdog()
    this.noticeController.stop()
    stopTun()
    super.stopVpn()
    // ★ 先停止 tun 再停止 listener，防止 Go 内部清理和 stopTun() 竞争导致 NULL 指针崩溃
    stopListener()
    return true
  }

  // ==================== 内核 IPC 看门狗（VPN 激活期间在本进程内自愈） ====================

  private startKernelWatchdog(): void {
    this.stopKernelWatchdog()
    this.watchdogTimer = setInterval(() => {
      this.probeKernel()
    }, FlClashVpnService.WATCHDOG_INTERVAL_MS)
  }

  private stopKernelWatchdog(): void {
    if (this.watchdogTimer != -1) {
      clearInterval(this.watchdogTimer)
      this.watchdogTimer = -1
    }
  }

  /**
   * 周期性探活：向内核 IPC（clash_go.sock）发一次轻量 GetVersion RPC，任何合法响应即视为存活。
   * 启停/自愈 op 执行期间跳过探活，避免把中间态误判为失联。
   */
  private async probeKernel(): Promise<void> {
    if (this.isStopped || !this.vpnActive || this.vpnOpRunning || this.vpnOpQueue.length > 0) {
      return
    }
    const alive = await this.probeKernelRpc()
    if (alive) {
      if (this.healFailures > 0) {
        console.info(`ClashVPN 看门狗探活恢复，清零自愈失败计数(${this.healFailures})`)
      }
      this.healFailures = 0
      return
    }
    console.error("ClashVPN 看门狗探活失败，内核 IPC 失联，排队自愈")
    // 自愈进统一串行队列：与 UI 触发的 start/stop 互斥排队；已在排队的自愈不重复排
    if (!this.vpnOpQueue.some((o) => o.op == 'heal')) {
      this.enqueueVpnOp('heal')
    }
  }

  private probeKernelRpc(): Promise<boolean> {
    const socketPath = this.context?.filesDir + '/clash_go.sock'
    if (!socketPath) {
      return Promise.resolve(false)
    }
    return new Promise<boolean>((resolve) => {
      let finished = false
      const client: socket.LocalSocket = socket.constructLocalSocketInstance()
      let timeoutId = -1
      const done = (ok: boolean): void => {
        if (finished) {
          return
        }
        finished = true
        clearTimeout(timeoutId)
        try {
          client.off('message')
          client.off('error')
          client.off('close')
          client.close()
        } catch (_) {
        }
        resolve(ok)
      }
      timeoutId = setTimeout(() => {
        done(false)
      }, 3000)
      client.on('message', () => {
        done(true)
      })
      client.on('error', () => {
        done(false)
      })
      client.on('close', () => {
        done(false)
      })
      client.connect({ address: { address: socketPath }, timeout: 1000 })
        .then(() => {
          client.send({ data: JSON.stringify({ method: ClashRpcType.GetVersion, params: [] }) })
        })
        .catch(() => {
          done(false)
        })
    })
  }

  /**
   * 内核失联自愈（在统一串行队列内执行，与 UI 的 start/stop 互斥，无重入空间）。
   * 序列参考正常启动路径：stopTun → 重建 clash_go.sock IPC 监听 → startVpnInternal 重建 TUN
   *（startVpnInternal 内含 startListener）。排队期间用户发起的 stop 会先执行，
   * 轮到本 op 时 isStopped/vpnActive 检查会直接跳过，正常停止路径不会被自愈"复活"。
   * 连续失败超过 MAX_HEAL_FAILURES 次后拆除 VPN 并发布"点击重连"通知，停止重试。
   */
  private async healKernelInternal(): Promise<boolean> {
    if (this.isStopped || !this.vpnActive) {
      return false
    }
    this.healFailures++
    console.error(`ClashVPN 内核自愈第 ${this.healFailures} 次`)
    if (this.healFailures > FlClashVpnService.MAX_HEAL_FAILURES) {
      // 超过阈值：拆除 VPN 防止流量黑洞，停止重试，引导用户点击重连
      console.error(`ClashVPN 内核自愈连续失败超过 ${FlClashVpnService.MAX_HEAL_FAILURES} 次，停止重试`)
      this.stopVpnInternal()
      await publishReconnectNotice(this.context)
      return false
    }
    // 1. 停 TUN（Go 侧幂等：stopKeepalive + tunListener.Close + removeSocketHook）
    try {
      stopTun()
    } catch (e) {
      console.error(`ClashVPN 自愈 stopTun 异常: ${(e as Error).message}`)
    }
    // 2. 重建内核 IPC 监听（socket 文件被清理或 listener 协程死亡的场景）
    const goPath = this.context?.filesDir + '/clash_go.sock'
    try {
      if (await fileIo.access(goPath)) {
        await fileIo.unlink(goPath)
      }
      startIpc(goPath)
    } catch (e) {
      console.error(`ClashVPN 自愈重建 IPC 监听异常: ${(e as Error).message}`)
    }
    // 3. 等待 IPC 就绪（最长 3s）
    let ipcReady = false
    for (let i = 0; i < 10 && !ipcReady; i++) {
      await new Promise<void>((resolve) => {
        setTimeout(resolve, 300)
      })
      ipcReady = await this.probeKernelRpc()
    }
    if (!ipcReady) {
      console.error("ClashVPN 自愈：IPC 监听重建后仍不可达，等待下一次探活重试")
      return false
    }
    // 4. 重建 TUN 与内核（内含 startListener；protect 通道由 startClash 的 NAPI 回调重建）
    const ok = await this.startVpnInternal()
    if (ok) {
      console.info(`ClashVPN 内核自愈第 ${this.healFailures} 次重启成功`)
    } else {
      console.error(`ClashVPN 内核自愈第 ${this.healFailures} 次重启失败`)
    }
    return ok
  }

  /**
   * protect 带重试：后台 Extension 进程受限时 vpnConnection.protect 可能偶发失败，
   * 失败重试可避免出站 fd 未保护导致流量回环（直连断网）
   */
  private async protectWithRetry(fd: number, retries: number): Promise<void> {
    let lastErr: Error | undefined = undefined
    for (let i = 0; i < retries; i++) {
      try {
        await this.protect(fd)
        return
      } catch (e) {
        lastErr = e as Error
        await new Promise<void>((resolve) => {
          setTimeout(resolve, 100)
        })
      }
    }
    throw lastErr ?? new Error('protect failed')
  }
  override async init() {
    initClash(await getHome(this.context), "1.0.0")
  }
}

export interface Fd {
  id: number
  value: number
}

export function ParseProxyGroup(mode: ProxyMode, result: string): ProxyGroup[] {
  if (result == null || result.length === 0)
    return []
  const map = JSON.parse(result) as Record<string, Record<string, string | string[] | boolean | number | undefined>>
  const global = map[ProxyMode.Global]
  let groupNames: string[] = (global?.["all"] as string[] | undefined) ?? []
  if (mode == ProxyMode.Global) {
    groupNames = ["GLOBAL", ...groupNames]
  } else if (mode == ProxyMode.Rule) {
    // keep groupNames as is
  } else {
    groupNames = []
  }
  groupNames = groupNames.filter(e => {
    const proxy = map[e]
    if (!proxy)
      return false
    return ["Selector", "URLTest", "Fallback", "LoadBalance", "Relay"].indexOf(proxy["type"] as string) > -1
  })
  const groupsRaw: (ProxyGroup | null)[] = groupNames.map((groupName) => {
    const group = map[groupName];
    if (!group) {
      return null;
    }
    const rawAll = group["all"]
    const allNames: string[] = Array.isArray(rawAll) ? rawAll as string[] : []
    const proxies: Proxy[] = []
    for (const n of allNames) {
      const rawProxy = map[n];
      if (!rawProxy) {
        continue;
      }
      const proxyName = (rawProxy["name"] as string | undefined) ?? n;
      const proxyType = (rawProxy["type"] as string | undefined) ?? "Reject";
      proxies.push({
        name: proxyName,
        type: proxyType as ProxyType,
        display: (rawProxy["display"] as string | undefined) ?? "",
        id: rawProxy["id"] as string | undefined,
        g: rawProxy["g"] as string | undefined,
        icon: rawProxy["icon"] as string | undefined,
        latency: rawProxy["latency"] as number | undefined,
      })
    }
    return {
      name: (group["name"] as string) ?? "",
      now: (group["now"] as string) ?? "",
      type: (group["type"] as ProxyType) ?? ProxyType.Reject,
      display: (group["display"] as string) ?? "",
      hidden: group["hidden"] == true,
      icon: group["icon"] as string | undefined,
      proxies: proxies
    } as ProxyGroup
  })
  return groupsRaw.filter(g => g != null) as ProxyGroup[];
}