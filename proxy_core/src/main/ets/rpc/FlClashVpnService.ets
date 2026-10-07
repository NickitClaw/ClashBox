import { encodeRpcFrame, RpcFrameBuffer } from './RpcFrame';
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
  generation: number
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
  private frames: Map<number, RpcFrameBuffer> = new Map()

  override async onRemoteMessageRequest(client: socket.LocalSocketConnection, message: socket.LocalSocketMessageInfo): Promise<void> {
    try {
      let buffer = this.frames.get(client.clientId)
      if (!buffer) {
        buffer = new RpcFrameBuffer()
        this.frames.set(client.clientId, buffer)
      }
      for (const frame of buffer.push(new Uint8Array(message.message))) {
        const request = JSON.parse(frame) as RpcRequest
        try {
          const result = await this.onRemoteMessage(request.method, request.params)
          await this.sendClient(client, JSON.stringify({ result: result }))
        } catch (e) {
          await this.sendClient(client, JSON.stringify({ error: (e as Error).message || 'VPN 操作失败' }))
        }
      }
    } catch (_) {
      this.frames.delete(client.clientId)
      client.close().catch(() => {})
    }
  }
  override onClientClosed(clientId: number): void {
    this.frames.delete(clientId)
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
  private desiredRunning: boolean = false
  private intentGeneration: number = 0
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
          this.startVpn().then((r) => {
            resolve(r)
          }).catch((e: Error) => {
            reject(e)
          })
          break;
        }
        case ClashRpcType.stopClash: {
          this.stopVpn().then((r) => {
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
   * - stop 立即撤销运行意图，取消排队中的 start/heal，并向被取消操作返回 false。
   * - 每个操作等待原生完成确认；过期的异步结果不能恢复 VPN。
   */
  private enqueueVpnOp(op: VpnOpType): Promise<boolean> {
    if (op !== 'heal') {
      this.desiredRunning = op === 'start'
      ++this.intentGeneration
    }
    return new Promise<boolean>((resolve) => {
      if (op == 'stop') {
        for (const pending of this.vpnOpQueue) {
          if (pending.op !== 'stop') {
            pending.resolves.forEach((r) => {
              r(false)
            })
          }
        }
        this.vpnOpQueue = this.vpnOpQueue.filter((p) => p.op === 'stop')
      }
      const tail = this.vpnOpQueue[this.vpnOpQueue.length - 1]
      if (tail && tail.op == op) {
        tail.resolves.push(resolve)
        tail.generation = this.intentGeneration
      } else {
        this.vpnOpQueue.push({ op: op, resolves: [resolve], generation: this.intentGeneration })
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
            result = await this.startVpnInternal(head.generation)
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

  override async stopVpn(): Promise<boolean> {
    return this.enqueueVpnOp('stop')
  }

  async startVpnInternal(generation: number = this.intentGeneration): Promise<boolean> {
    if (!this.desiredRunning || generation !== this.intentGeneration) return false
    this.isStopped = false
    this.vpnActive = false
    try {
      await this.releaseTun()
      if (!this.desiredRunning || generation !== this.intentGeneration) return false
      startListener()
      const fd = await super.getTunFd(this.ParseConfig())
      if (fd < 0) throw new Error('系统未创建 TUN')
      if (!this.desiredRunning || generation !== this.intentGeneration) throw new Error('VPN 启动已取消')
      const started = await this.startClash(fd, generation)
      if (started !== true) throw new Error('内核未确认 TUN 启动，请重新编译 libflclash.so')
      if (!this.desiredRunning || generation !== this.intentGeneration) throw new Error('VPN 启动已取消')
      this.vpnActive = true
      this.healFailures = 0
      await this.noticeController.start()
      this.startKernelWatchdog()
      return true
    } catch (error) {
      this.vpnActive = false
      await this.noticeController.stop()
      try { await this.releaseTun() } finally {
        stopListener()
        if (this.desiredRunning) this.startKernelWatchdog()
      }
      console.error('ClashVPN 启动失败', (error as Error).message)
      return false
    }
  }

  async startClash(tunFd: number, generation: number = this.intentGeneration): Promise<boolean> {
    const connection = this.vpnConnection
    return await startTun(tunFd, (id: number, fd: number) => {
      if (!connection || !this.desiredRunning || generation !== this.intentGeneration) {
        setFdMap(id, false)
        return
      }
      // Bind protection to the connection that owns this TUN, never a replacement.
      connection.protect(fd).then(() => {
        setFdMap(id, this.desiredRunning && generation === this.intentGeneration)
      }).catch(() => { setFdMap(id, false) })
    })
  }

  private async releaseTun(): Promise<void> {
    try { await stopTun() } finally { await super.stopVpn() }
  }

  async stopVpnInternal(): Promise<boolean> {
    this.vpnActive = false
    this.stopKernelWatchdog()
    await this.noticeController.stop()
    try {
      await this.releaseTun()
    } finally {
      stopListener()
      this.isStopped = true
    }
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
   * 周期性探活：同时要求本地已激活以及内核返回有效的 TUN 启动时间。
   * 启停/自愈 op 执行期间跳过探活，避免把中间态误判为失联。
   */
  private async probeKernel(): Promise<void> {
    if (!this.desiredRunning || this.vpnOpRunning || this.vpnOpQueue.length > 0) return
    const generation = this.intentGeneration
    const alive = this.vpnActive && await this.probeKernelRpc(true)
    if (!this.desiredRunning || generation !== this.intentGeneration || alive) return
    if (!this.vpnOpQueue.some((o) => o.op === 'heal')) this.enqueueVpnOp('heal')
  }

  private probeKernelRpc(requireTun: boolean = false): Promise<boolean> {
    const socketPath = this.context?.filesDir + '/clash_go.sock'
    if (!socketPath) {
      return Promise.resolve(false)
    }
    return new Promise<boolean>((resolve) => {
      const frames = new RpcFrameBuffer()
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
      client.on('message', (value: socket.LocalSocketMessageInfo) => {
        try {
          for (const frame of frames.push(new Uint8Array(value.message))) {
            const response = JSON.parse(frame) as Record<string, string>
            done(!response.error && (!requireTun || Number(response.result) > 0))
          }
        } catch (_) { done(false) }
      })
      client.on('error', () => {
        done(false)
      })
      client.on('close', () => {
        done(false)
      })
      client.connect({ address: { address: socketPath }, timeout: 1000 })
        .then(() => {
          return client.send({ data: encodeRpcFrame(JSON.stringify({ method: requireTun ? ClashRpcType.GetVpnRunTime : ClashRpcType.GetVersion, params: [] })) })
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
    if (!this.desiredRunning) return false
    const generation = this.intentGeneration
    if (this.healFailures >= FlClashVpnService.MAX_HEAL_FAILURES) {
      this.desiredRunning = false
      await this.stopVpnInternal()
      if (generation === this.intentGeneration) await publishReconnectNotice(this.context)
      return false
    }
    ++this.healFailures
    this.vpnActive = false
    await this.noticeController.stop()
    await this.releaseTun()
    if (!this.desiredRunning || generation !== this.intentGeneration) return false
    let ready = await this.probeKernelRpc()
    if (!ready) {
      // Go owns listener replacement and socket cleanup.
      startIpc(this.context.filesDir + '/clash_go.sock')
      for (let i = 0; i < 3 && !ready; i++) {
        if (!this.desiredRunning || generation !== this.intentGeneration) return false
        await new Promise<void>((resolve) => { setTimeout(resolve, 300) })
        ready = await this.probeKernelRpc()
      }
    }
    if (!ready) return false
    // Only a confirmed, fully recreated TUN resets the consecutive failure count.
    return await this.startVpnInternal(generation)
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