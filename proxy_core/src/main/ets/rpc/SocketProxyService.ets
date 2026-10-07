import { socket, vpnExtension } from '@kit.NetworkKit';
import {  RpcResult } from './RpcRequest';
import { JSON, util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { ClashRpcType, IClashManager, VpnRawOptions, HealthCheckBatchParams } from './IClashManager';
import { ConnectionInfo, IpInfo, LogInfo, Provider, ProxyGroup, ProxyMode,
  Traffic } from '../models/Common';
import  fs from  "@ohos.file.fs"
import { fileIo, fileUri } from "@kit.CoreFileKit";
import { UpdateConfigParams } from '../models/ClashConfig';
import { checkIp, queryCurrentIpInfo, flushHttpConnections } from '../Request';
import { Fd, ParseProxyGroup, VpnOptions } from './FlClashVpnService';
import { Address, isIpv4, isIpv6, VpnConfig } from './CommonVpnService';
import { connection } from '@kit.NetworkKit';

interface DelayInfo{
  name: string
  value: number
}
interface Snapshot{
  connections: ConnectionInfo[]
}
interface TrafficInfo{
  up: number
  down: number
}



/**
 * EOF 帧重组器：Go 端 IPC 以 "EOF" 作为帧后缀（单响应连接写一帧后关闭；
 * 日志等流式连接在同一条连接上连续写多帧）。
 * 原实现按 chunk 直接 split("EOF")，chunk 边界切断帧或内容内嵌 "EOF" 都会截断消息；
 * 这里改为跨 chunk 累积缓冲，按帧边界重组完整消息：
 * 候选帧必须通过 JSON.parse 完整性校验，内容内嵌 "EOF" 时自动顺延到下一个边界重试。
 */
class EofFrameBuffer {
  private buffer: string = ''
  /** 缓冲上限防御：对端异常/帧永远无法解析时防止内存无限增长（getProxies 大响应在百 KB 级） */
  private static readonly MAX_BUFFER_BYTES: number = 4 * 1024 * 1024

  /** 压入一个 chunk，返回本轮重组出的全部完整帧 */
  push(chunk: string): string[] {
    this.buffer += chunk
    const frames: string[] = []
    let searchFrom = 0
    while (true) {
      const idx = this.buffer.indexOf('EOF', searchFrom)
      if (idx < 0) {
        break
      }
      const candidate = this.buffer.substring(0, idx)
      try {
        JSON.parse(candidate)
        frames.push(candidate)
        this.buffer = this.buffer.substring(idx + 3)
        searchFrom = 0
      } catch (_) {
        // 内容内嵌 "EOF"（如节点名/URL/日志载荷）：不是帧边界，顺延重试
        searchFrom = idx + 3
      }
    }
    if (this.buffer.length > EofFrameBuffer.MAX_BUFFER_BYTES) {
      console.error(`EofFrameBuffer 缓冲超限(${this.buffer.length})，丢弃重同步`)
      this.buffer = ''
    }
    return frames
  }

  /** 连接关闭时的兜底：剩余缓冲去掉尾部 EOF 后若构成完整 JSON 则返回，否则返回 null */
  flushOnClose(): string | null {
    let rest = this.buffer
    this.buffer = ''
    if (rest.endsWith('EOF')) {
      rest = rest.substring(0, rest.length - 3)
    }
    if (rest.length == 0) {
      return null
    }
    try {
      JSON.parse(rest)
      return rest
    } catch (_) {
      return null
    }
  }
}

@ObservedV2
export class SocketProxyService implements IClashManager {
  context?: common.Context
  active: boolean = false
  @Trace offlineTime: number[] = []
  private textDecoder: util.TextDecoder = new util.TextDecoder()
  /**
   * Go IPC socket 连接被拒(Connection refused)时的全局回调,
   * 由 ClashViewModel 注册为自动重建 VPN 进程。任意 RPC(含测速)失败都会触发,
   * 解决"运行中 VPN 进程崩溃/被回收后所有操作 connection refused 无法恢复"的问题。
   */
  onConnectionRefused?: () => void

  init(context: common.Context) {
    this.context = context
  }

  /** 检测 connection refused 类错误并触发全局自愈回调 */
  private notifyConnectionRefused(e: Error): void {
    const msg = e?.message ?? String(e)
    if (msg.includes('Connection refused') || msg.includes('VPN服务未启动')) {
      this.onConnectionRefused?.()
    }
  }

  async setLogObserver(observer: (message: LogInfo) => void): Promise<()=>void> {
    return this.callbackRequest(ClashRpcType.setLogObserver, [], (message)=>{
      if(message != ""){
        observer(JSON.parse(message) as LogInfo)
      }
    })
  }
  async registerMessage(observer: (message: string) => void): Promise<()=>void> {
    return this.callbackRequest(ClashRpcType.registerOnMessage, [], observer)
  }
  async loadConfig(config: UpdateConfigParams): Promise<string> {
    config['profile-id'] = config['profile-id'] + "/config"
    let result = await this.sendMessageRequest(ClashRpcType.load, [JSON.stringify(config)])
    return result as string
  }
  async vailConfig(filepath: string){
    let result = await this.sendMessageRequest(ClashRpcType.validConfig, [filepath])
    return result as string;
  }
  async downloadConfig(url: string, agent: string, filePath: string){
    let result = await this.sendMessageRequest(ClashRpcType.downloadConfig, [url, agent, filePath])
    return result as string;
  }
  async setNetIpMacInfo(){
    try {
      const table = await connection.getIpNeighTable()
      const jsonParams = JSON.stringify(table);
      let result = await this.sendMessageRequest(ClashRpcType.SetNetInterfaces, [jsonParams])
      return result as string;
    }catch (e) {
      console.warn("setNetIpMacInfo 不支持注入网卡信息")
    }
    return "";
  }
  async setSystemDns(dns: string){
    try {
      await this.sendMessageRequest(ClashRpcType.SetSystemDns, [dns])
    }catch (e) {
      console.warn("setSystemDns 不支持注入DNS")
    }
  }
  async queryTrafficTotal(onlyProxy: boolean): Promise<Traffic> {
    let result = await this.sendMessageRequest(ClashRpcType.queryTrafficTotal, [onlyProxy])
    const json = JSON.parse(result as string) as TrafficInfo
    return new Traffic(json.up, json.down);
  }
  async queryTrafficNow(onlyProxy: boolean): Promise<Traffic> {
    let result = await this.sendMessageRequest(ClashRpcType.queryTrafficNow,  [onlyProxy])
    const json = JSON.parse(result as string) as TrafficInfo
    return new Traffic(json.up, json.down);
  }
  async getVersion(): Promise<string> {
    let result = await this.sendMessageRequest(ClashRpcType.GetVersion, [])
    return result as string
  }

  /**
   * 轻量探测 Go IPC socket 是否可连接(只 connect, 不发任何 RPC)。
   * 用于冷启动等待核心就绪: 部分核心不支持 GetVersion RPC,
   * 用 getVersion() 探测会在 socket 就绪后仍持续失败, 导致等待超时。
   * @returns true=可连接; 文件不存在/连接失败均返回 false
   */
  async isSocketReady(): Promise<boolean> {
    const socketPath = this.context?.filesDir + '/clash_go.sock';
    if (!socketPath) return false;
    try {
      if (!await fileIo.access(socketPath)) return false;
      const client = socket.constructLocalSocketInstance();
      return await new Promise<boolean>((resolve) => {
        client.connect({ address: { address: socketPath }, timeout: 1000 }).then(() => {
          try { client.close(); } catch (_) {}
          resolve(true);
        }).catch(() => {
          try { client.close(); } catch (_) {}
          resolve(false);
        });
      });
    } catch (e) {
      return false;
    }
  }

  async checkIpInfo(enableIpv6: boolean = true): Promise<IpInfo> {

    this.setNetIpMacInfo();

    await flushHttpConnections();

    // 首次尝试：通过 HTTP API 查询 IP
    // enableIpv6=false 时禁止通过内置 IPv6 专用地址(api6.ipify.org/v6.ident.me)查询 IPv6
    let ipInfo = await queryCurrentIpInfo(enableIpv6)

    if (ipInfo) {
      console.log(`IPtest SocketProxyService#checkIpInfo IP: ${ipInfo.ip}, Country: ${ipInfo.country}`)
      return {
        ip: ipInfo.ip,
        country: ipInfo.country
      } as IpInfo
    }

    // API 全部失败时重试最多 2 次（间隔 1 秒），
    // 解决 VPN 刚启动时网络/代理尚未就绪导致 HTTP 请求超时的问题
    console.warn(`IPtest SocketProxyService#checkIpInfo 首次 API 请求失败，准备重试`)
    for (let i = 0; i < 2; i++) {
      await new Promise<void>((r: Function) => { setTimeout(r, 1000); });
      ipInfo = await queryCurrentIpInfo(enableIpv6)
      if (ipInfo) {
        console.log(`IPtest SocketProxyService#checkIpInfo 第 ${i + 2} 次重试成功 IP: ${ipInfo.ip}`)
        return {
          ip: ipInfo.ip,
          country: ipInfo.country
        } as IpInfo
      }
      console.warn(`IPtest SocketProxyService#checkIpInfo 第 ${i + 2} 次重试仍失败`)
    }

    // 所有重试都失败，回退到本地 RPC 方式获取
    console.warn(`IPtest SocketProxyService#checkIpInfo 所有 API 请求失败，尝试本地方法`)
    // ★ 回退路径同样遵守 enableIpv6 开关, 直接调用 queryCurrentIpInfo(enableIpv6)
    // (checkIp() 兼容函数内部无参调用默认允许 IPv6, 不适用此处)
    const ipResult = await queryCurrentIpInfo(enableIpv6)
    const result = ipResult ? ipResult.ip : 'Unknown'
    const country = await this.sendMessageRequest(ClashRpcType.getCountryCode, [result]) as string

    return {
      ip: result,
      country: country
    } as IpInfo
  }

  async queryConnections(): Promise<ConnectionInfo[]> {
    let result = await this.sendMessageRequest(ClashRpcType.queryConnections)
    const json = JSON.parse(result as string) as Snapshot
    return json.connections ?? [];
  }
  async getRequestList(): Promise<ConnectionInfo[]>{
    let result = await this.sendMessageRequest(ClashRpcType.getRequestList)
    return JSON.parse(result as string) as ConnectionInfo[]
  }
  async  clearRequestList(): Promise<boolean>{
    await this.sendMessageRequest(ClashRpcType.clearRequestList)
    return true
  }
  async closeConnection(id: string): Promise<string> {
    let result = await this.sendMessageRequest(ClashRpcType.closeConnection, [id])
    return result as string;
  }
  async clearConnections(): Promise<ConnectionInfo[]> {
    let result = await this.sendMessageRequest(ClashRpcType.clearConnections)
    const json = JSON.parse(result as string) as ConnectionInfo[]
    return json;
  }

  async queryProxyGroups(model: ProxyMode): Promise<ProxyGroup[]> {
    let result = await this.sendMessageRequest(ClashRpcType.queryProxyGroup,[model])
    return ParseProxyGroup(model, result as string)
  }
  async queryProviders(): Promise<Provider[]> {
    let result = await this.sendMessageRequest(ClashRpcType.queryProviders)
    return JSON.parse(result as string) as Provider[]
  }
  async getVpnOptions(): Promise<VpnOptions> {
    let result = await this.sendMessageRequest(ClashRpcType.vpnOptions)
    return JSON.parse(result as string) as VpnOptions
  }
  async setOptionStates(options: VpnRawOptions): Promise<string> {
    let result = await this.sendMessageRequest(ClashRpcType.setOptionState, [JSON.stringify(options)])
    return result as string
  }
  async updateProvider(provider: Provider): Promise<string> {
    return  (await this.sendMessageRequest(ClashRpcType.updateProvider,[provider.name])) as string
  }
  async upLoadProvider(provider: Provider, uri: string): Promise<string> {
    const temp = this.context?.filesDir + "/temp_provider"
    fs.copy(uri, fileUri.getUriFromPath(temp))
    return  (await this.sendMessageRequest(ClashRpcType.uploadProvider,[provider.name, temp])) as string
  }
  async updateGeoData(geoName: string, geoType: string): Promise<string>{
    return await (this.sendMessageRequest(ClashRpcType.updateGeoData,[geoName, geoType])) as string
  }
  async changeProxy(group: string, name: string): Promise<string> {
    let result = await this.sendMessageRequest(ClashRpcType.changeProxy,[group, name])
    return result as string
  }
  async healthCheck(proxyName: string): Promise<number> {
    let result = await this.sendMessageRequest(ClashRpcType.healthCheck, [proxyName, 3000])
    let info = JSON.parse(result as string) as DelayInfo
    return info.value
  }

  async healthCheckAll(): Promise<void> {
    await this.sendMessageRequest(ClashRpcType.healthCheckAll, [])
  }

  async healthCheckBatch(names: string[], timeout: number, testUrl?: string): Promise<Map<string, number>> {
    const params: HealthCheckBatchParams = {
      "proxy-names": names,
      timeout: timeout,
      "test-url": testUrl ?? ""
    }
    let result = await this.sendMessageRequest(ClashRpcType.healthCheckBatch, [JSON.stringify(params)])
    const list = JSON.parse(result as string) as DelayInfo[]
    const map = new Map<string, number>()
    for (const item of list) {
      map.set(item.name, item.value)
    }
    return map
  }

  async startClash():Promise<boolean>{
    let json = await this.sendMessageRequest(ClashRpcType.startClash, [])
    return json as boolean
  }
  // TODO 返回运行时间,卡片和ui统一使用 需要测试,
  async getRuntime(): Promise<number> {
    let result = await this.sendMessageRequest(ClashRpcType.GetVpnRunTime)
    return result as number
  }
  // TODO startClash前需要调用判断, clash配置是否加载完成,
  // 没有加载,做友好提示,或则先加载clash配置,在启动
  async vpnConfigIsLoad(): Promise<boolean> {
    try {
      let result = await this.sendMessageRequest(ClashRpcType.VpnConfigInited)
      return result  == "true"
    }catch (e) {
      return false;
    }
  }
  vpnConnection : vpnExtension.VpnConnection | undefined
  async getTunFd(config: VpnConfig): Promise<number> {
    let tunFd = -1
    try {
      this.vpnConnection = vpnExtension.createVpnConnection(this.context as common.VpnExtensionContext);
      tunFd = await this.vpnConnection.create(config)
      console.log("ClashVPN", `获取tunFd: ${tunFd}`)
      return tunFd;
    } catch (error) {
      console.log("ClashVPN", `Clash启动失败 ${error.message} => ${error.stack}` )
      this.vpnConnection?.destroy()
      return -1
    }
  }
  async stopClash():Promise<boolean>{
    let json = await this.sendMessageRequest(ClashRpcType.stopClash, [])
    return json as boolean
  }
  async reset():Promise<boolean>{
    let json = await this.sendMessageRequest(ClashRpcType.reset, [])
    return json as boolean
  }
  async ParseMessage(messageBuffer: string, resolve: (s: string| number | boolean | undefined)=>void, reject:  (err: string)=>void){
    try {
      let json = JSON.parse(messageBuffer) as RpcResult
      if (!json.error || json.error == "")
        resolve(json.result)
      else{
        console.warn(`ParseMessage error: method=${json.result} error=${json.error}`)
        reject(json.error)
      }
    } catch (e) {
      console.error("ParseMessage", e, messageBuffer)
      reject("JSON解码失败: " + JSON.stringify(e))
    }
  }
  async sendMessageRequest(
    method: number,
    params: (string| number | boolean) [] = []
  ): Promise<string| number | boolean | undefined>{
    console.log("sendMessageRequest " + method)

    return new Promise(async (resolve, reject)=>{
      let client: socket.LocalSocket = socket.constructLocalSocketInstance();
      const frameBuffer = new EofFrameBuffer()
      let settled = false
      let timeoutId: number = -1
      const cleanup = () => {
        if (timeoutId != -1) {
          clearTimeout(timeoutId)
          timeoutId = -1
        }
        try {
          client.off('message')
          client.off('error')
          client.off('close')
          client.close()
        } catch (_) {
        }
      }
      const resolveOnce = (value: string | number | boolean | undefined) => {
        if (settled) return
        settled = true
        cleanup()
        resolve(value)
      }
      const rejectOnce = (err: string | Error) => {
        if (settled) return
        settled = true
        cleanup()
        reject(err)
      }
      client.on('message', async (value: socket.LocalSocketMessageInfo) => {
        // 累积缓冲 + 帧边界重组：单响应连接取第一个完整帧即完成
        let chunk = this.textDecoder.decodeToString(new Uint8Array(value.message),  { stream: true })
        for (const frame of frameBuffer.push(chunk)) {
          this.ParseMessage(frame, resolveOnce, rejectOnce)
          return
        }
      })
      client.on('close', () => {
        // Go 端写完响应即 defer close：关闭时兜底重组剩余缓冲，避免大响应因 EOF 帧未齐而超时
        const rest = frameBuffer.flushOnClose()
        if (rest != null) {
          this.ParseMessage(rest, resolveOnce, rejectOnce)
        } else {
          rejectOnce("连接已关闭，未收到完整响应")
        }
      })
      const rpcTimeout = (method === ClashRpcType.downloadConfig) ? 15000 : 10000
      timeoutId = setTimeout(()=>{
        rejectOnce("请求超时")
      }, rpcTimeout)
      client.on("error", ()=>{
        rejectOnce("rpc client error")
      })
      // {"proxy-name":"♻️自动选择","timeout":3000}
      let socketPath = this.context?.filesDir + '/clash_go.sock'
      // || method == ClashRpcType.getRuntime 在clash_go里已实现,
      if (method == ClashRpcType.startClash || method == ClashRpcType.stopClash){
        socketPath = this.context?.filesDir + '/ClashBox.sock'
      }
      if(! await fileIo.access(socketPath)){
        rejectOnce("VPN服务未启动")
        return;
      }
      tryConnect(client, socketPath, 3, 500).then(async ()=>{
        this.active = true
        client.send({ data: JSON.stringify({method, params}) });
      }).catch((e:Error)=>{
        this.active = false
        this.notifyConnectionRefused(e)
        rejectOnce(e)
      });
    })
  }
  async callbackRequest(
    method: number,
    params: (string | number | boolean) [] = [],
    callBack: (message: string) => void
  ): Promise<() => void> {
    return new Promise(async (resolve, reject)=>{
      let tcp: socket.LocalSocket = socket.constructLocalSocketInstance();
      const frameBuffer = new EofFrameBuffer()
      tcp.on('message', (value: socket.LocalSocketMessageInfo) => {
        // 流式连接：跨 chunk 累积，按 EOF 帧边界重组（原实现对每个 chunk 直接 split，
        // chunk 边界切断帧或内容内嵌 EOF 都会丢消息/截断）
        let dd = this.textDecoder.decodeToString(new Uint8Array(value.message))
        for (const frame of frameBuffer.push(dd)) {
          try {
            let json = JSON.parse(frame) as RpcResult
            callBack(json.result as string)
          }catch (e) {
            console.error("log error", e.message, frame)
          }
        }
      })
      tcp.on('close', () => {
        // 对端关闭时兜底重组残余缓冲（如 Go 端单帧后即关闭的场景）
        const rest = frameBuffer.flushOnClose()
        if (rest != null) {
          try {
            let json = JSON.parse(rest) as RpcResult
            callBack(json.result as string)
          }catch (e) {
            console.error("log error", e.message, rest)
          }
        }
      })
      tcp.on('error', (e: Error) => {
        tcp.off('message')
        tcp.off('error')
        tcp.off('close')
        reject("失败")
      });
      const socketPath = this.context?.filesDir + '/clash_go.sock'
      // 与 sendMessageRequest 保持一致：先检查 socket 文件是否存在，再带重试连接，
      // 解决启动时 socket 文件已存在但服务端尚未 listen 的竞态问题，避免日志订阅静默失败
      if (!await fileIo.access(socketPath)) {
        reject("VPN服务未启动")
        return;
      }
      tryConnect(tcp, socketPath, 3, 500).then(()=>{
        tcp.send({ data: JSON.stringify({method, params}) });
        resolve(()=>{
          tcp.off('message')
          tcp.off('error')
          tcp.off('close')
          tcp.close()
        })
      }).catch((e: Error)=>{
        console.log("socketProxy error", e.message)
        this.notifyConnectionRefused(e)
        reject(e)
      });
    })
  }
}

/**
 * 带重试的 socket 连接，解决启动时 socket 文件已存在但服务端尚未 listen 的竞态问题
 * @param client  LocalSocket 实例
 * @param socketPath  Unix socket 路径
 * @param retries  最大重试次数
 * @param delayMs  每次重试间隔（毫秒）
 */
async function tryConnect(
  client: socket.LocalSocket,
  socketPath: string,
  retries: number,
  delayMs: number
): Promise<void> {
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      await new Promise<void>((resolve, reject) => {
        client.connect({ address: { address: socketPath }, timeout: 1000 }).then(() => {
          resolve();
        }).catch((e: Error) => {
          reject(e);
        });
      });
      return; // 连接成功
    } catch (e) {
      const errMsg = (e as Error).message;
      if (attempt < retries && errMsg === "Connection refused") {
        console.warn(`tryConnect 第 ${attempt} 次连接被拒，${delayMs}ms 后重试 (path=${socketPath})`);
        await new Promise<void>((r: Function) => { setTimeout(r, delayMs); });
      } else {
        throw e as Error; // 最后一次或非 Connection refused 错误，直接抛出
      }
    }
  }
}

export default new SocketProxyService()
