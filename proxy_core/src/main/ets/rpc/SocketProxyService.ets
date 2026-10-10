import { encodeRpcFrame, RpcFrameBuffer } from './RpcFrame';
import { closeRpcSocket, releaseRpcSocket } from './RpcSocketLifecycle';
import { generateUUID, writeProfileText } from '../profile/ProfileStorage';
import { socket, vpnExtension } from '@kit.NetworkKit';
import { createRpcRequest, decodeRpcResponse, rpcMethod, assertRpcCompatibility, RpcError } from './RpcContract';
import { RpcCapabilities, RpcErrorCode, VpnSnapshot } from './RpcContract.generated';
import { JSON, util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { ClashRpcType, IClashManager, VpnRawOptions, HealthCheckBatchParams } from './IClashManager';
import { ConnectionInfo, IpInfo, LogInfo, Provider, ProxyGroup, ProxyMode,
  Traffic } from '../models/Common';
import  fs from  "@ohos.file.fs"
import { fileIo, fileUri } from "@kit.CoreFileKit";
import { UpdateConfigParams, ClashConfig, ConfigExtendedParams } from '../models/ClashConfig';
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

interface ConfigLoadRequest {
  'profile-id': string;
  'source-path'?: string;
  config: ClashConfig;
  params: ConfigExtendedParams;
}



@ObservedV2
export class SocketProxyService implements IClashManager {
  private compatibility: Promise<RpcCapabilities> | undefined
  context?: common.Context
  active: boolean = false
  @Trace offlineTime: number[] = []
  /**
   * Go IPC socket 连接被拒(Connection refused)时的全局回调,
   * 由 ClashViewModel 注册为自动重建 VPN 进程。任意 RPC(含测速)失败都会触发,
   * 解决"运行中 VPN 进程崩溃/被回收后所有操作 connection refused 无法恢复"的问题。
   */
  onConnectionRefused?: () => void

  init(context: common.Context) {
    this.context = context
    this.resetCompatibility()
  }

  resetCompatibility(): void { this.compatibility = undefined; }

  async ensureCompatibility(): Promise<RpcCapabilities> {
    if (!this.compatibility) {
      const pending = this.sendMessageRequest(ClashRpcType.GetCapabilities, []).then((value) => {
        return assertRpcCompatibility(value as string);
      }).catch((e: Error) => {
        if (this.compatibility === pending) {
          this.compatibility = undefined;
          this.notifyConnectionRefused(e);
        }
        if (e instanceof RpcError) {
          throw new RpcError(RpcErrorCode.INCOMPATIBLE_VERSION, '内核协议不兼容，请安装同一次构建的完整应用包');
        }
        throw e;
      });
      this.compatibility = pending;
    }
    return this.compatibility;
  }

  /** 检测 connection refused 类错误并触发全局自愈回调 */
  private notifyConnectionRefused(e: Error): void {
    if (e instanceof RpcError) return
    this.resetCompatibility()
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
    // Keep large YAML outside the bounded RPC frame. The private file contains the
    // exact in-memory snapshot; rollback never rereads a changed subscription.
    const path = config.source !== undefined ? `${this.context?.tempDir}/activation-${generateUUID()}.yaml` : undefined;
    const request: ConfigLoadRequest = { 'profile-id': config['profile-id'] + '/config',
      'source-path': path, config: config.config, params: config.params };
    try {
      if (path !== undefined) {
        if (!this.context) throw new Error('配置存储尚未初始化');
        await writeProfileText(path, config.source!);
      }
      return await this.sendMessageRequest(ClashRpcType.load, [JSON.stringify(request)]) as string;
    } finally {
      if (path !== undefined) { try { await fileIo.unlink(path); } catch (_) {} }
    }
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
   * 用完整 RPC 探测监听器，避免 connect 后立刻 close 遗留接收线程。
   * 兼容性由 ensureCompatibility 握手单独确认。
   * @returns true=可连接; 文件不存在/连接失败均返回 false
   */
  async isSocketReady(): Promise<boolean> {
    if (!this.context) return false;
    try {
      await this.sendMessageRequest(ClashRpcType.GetCapabilities, []);
      return true;
    } catch (e) {
      // A protocol error still proves that a server replied. Let the explicit
      // compatibility check report it instead of repeatedly restarting a core.
      return e instanceof RpcError;
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
    await this.sendMessageRequest(ClashRpcType.clearConnections)
    return [];
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

  async queryVpnState(): Promise<VpnSnapshot> {
    return JSON.parse(await this.sendMessageRequest(ClashRpcType.queryTunnelState) as string) as VpnSnapshot;
  }

  async startClash():Promise<boolean>{
    let json = await this.sendMessageRequest(ClashRpcType.startClash, [])
    return json as boolean
  }
  // TODO 返回运行时间,卡片和ui统一使用 需要测试,
  async getRuntime(): Promise<number> {
    let result = await this.sendMessageRequest(ClashRpcType.GetVpnRunTime)
    return Number(result)
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
    await this.sendMessageRequest(ClashRpcType.reset, [])
    return true
  }
  async sendMessageRequest(
    method: number,
    params: (string| number | boolean) [] = []
  ): Promise<string| number | boolean | undefined>{
    const request = createRpcRequest(method, params);
    const spec = rpcMethod(method);
    if (spec.stream) throw new RpcError(RpcErrorCode.INVALID_REQUEST, '订阅方法必须使用 callbackRequest', method);
    if (spec.endpoint === 'go' && method !== ClashRpcType.GetCapabilities) await this.ensureCompatibility();
    return new Promise((resolve, reject) => {
      const client = socket.constructLocalSocketInstance();
      const frames = new RpcFrameBuffer();
      let settled = false;
      let connected = false;
      let timeoutId = -1;
      const cleanup = () => {
        clearTimeout(timeoutId);
        if (connected) releaseRpcSocket(client);
        else closeRpcSocket(client);
      };
      const fail = (error: Error | string) => {
        if (settled) return;
        settled = true;
        cleanup();
        const err = typeof error === 'string' ? new Error(error) : error;
        if (method !== ClashRpcType.queryTunnelState && method !== ClashRpcType.GetCapabilities) this.notifyConnectionRefused(err);
        reject(err);
      };
      const succeed = (value: string | number | boolean | undefined) => {
        if (settled) return;
        settled = true;
        cleanup(); resolve(value);
      };
      client.on('message', (value: socket.LocalSocketMessageInfo) => {
        try {
          for (const frame of frames.push(new Uint8Array(value.message))) {
            succeed(decodeRpcResponse(frame, method).result);
            break;
          }
        } catch (e) { fail(e as Error); }
      });
      client.on('close', () => { connected = false; fail('连接已关闭，未收到完整响应'); });
      client.on('error', (e: Error) => { connected = false; fail(e); });
      timeoutId = setTimeout(() => { fail(`RPC 请求超时（方法 ${method}）`); }, (method === ClashRpcType.GetCapabilities || method === ClashRpcType.queryTunnelState) ? 3000 : 60000);
      const connect = async (): Promise<void> => {
        let path = this.context?.filesDir + '/clash_go.sock';
        if (spec.endpoint === 'vpn') {
          path = this.context?.filesDir + '/ClashBox.sock';
        }
        if (!await fileIo.access(path)) throw new Error('VPN服务未启动');
        if (settled) return;
        await tryConnect(client, path, 3, 500);
        if (settled) { client.close().catch(() => {}); return; }
        connected = true;
        this.active = true;
        await client.send({ data: encodeRpcFrame(JSON.stringify(request)) });
      };
      connect().catch((e: Error) => { this.active = false; fail(e); });
    });
  }

  async callbackRequest(
    method: number,
    params: (string | number | boolean)[] = [],
    callBack: (message: string) => void
  ): Promise<() => void> {
    const request = createRpcRequest(method, params, 'go');
    if (!rpcMethod(method).stream) throw new RpcError(RpcErrorCode.INVALID_REQUEST, '此方法不是订阅接口', method);
    await this.ensureCompatibility();
    return new Promise<() => void>((resolve, reject) => {
      const client = socket.constructLocalSocketInstance();
      const frames = new RpcFrameBuffer();
      let closed = false;
      let ready = false;
      let connected = false;
      let timer = -1;
      const cleanup = (): void => {
        if (closed) return;
        closed = true;
        clearTimeout(timer);
        if (connected) releaseRpcSocket(client);
        else closeRpcSocket(client);
      };
      const fail = (error: Error): void => {
        if (closed) return;
        cleanup();
        this.notifyConnectionRefused(error);
        if (!ready) reject(error);
        else console.warn(`RPC 订阅 ${method} 已终止: ${error.message}`);
      };
      client.on('message', (value: socket.LocalSocketMessageInfo) => {
        try {
          for (const frame of frames.push(new Uint8Array(value.message))) {
            if (closed) break;
            const response = decodeRpcResponse(frame, method);
            if (!ready) {
              if (!response.streamReady) throw new RpcError(RpcErrorCode.INVALID_RESPONSE, '缺少订阅确认', method);
              ready = true;
              clearTimeout(timer);
              resolve(cleanup);
            } else {
              if (response.streamReady) throw new RpcError(RpcErrorCode.INVALID_RESPONSE, '重复订阅确认', method);
              callBack(response.result as string);
            }
          }
        } catch (e) { fail(e as Error); }
      });
      client.on('close', () => { connected = false; fail(new Error('RPC 订阅连接已关闭')); });
      client.on('error', (e: Error) => { connected = false; fail(e); });
      timer = setTimeout(() => fail(new Error('RPC 订阅确认超时')), 5000);
      const connect = async (): Promise<void> => {
        const path = this.context?.filesDir + '/clash_go.sock';
        if (!await fileIo.access(path)) throw new Error('VPN服务未启动');
        if (closed) return;
        await tryConnect(client, path, 3, 500);
        if (closed) { client.close().catch(() => {}); return; }
        connected = true;
        await client.send({ data: encodeRpcFrame(JSON.stringify(request)) });
      };
      connect().catch(fail);
    });
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
        throw e as Error as Error; // 最后一次或非 Connection refused 错误，直接抛出
      }
    }
  }
}

export default new SocketProxyService()
