import { VpnPhase, VpnSnapshot } from 'proxy_core/src/main/ets/rpc/RpcContract.generated';
import { initialVpnState } from 'proxy_core/src/main/ets/rpc/VpnLifecycleState';
import { ConfigActivationService, ConfigActivationHost, ConfigSnapshot } from '../common/services/ConfigActivationService';
import { ProfileStorage } from 'proxy_core/src/main/ets/profile/ProfileStorage';
import { ProfileBackup, restoreProfileMetadata } from 'proxy_core/src/main/ets/profile/ProfileBackup';
import { restoreProfilesAtomically } from 'proxy_core/src/main/ets/profile/ProfileRestore';
import { assertNativeCompatibility } from 'proxy_core/src/main/ets/rpc/NativeCompatibility';
import { ProfileRepo } from "proxy_core/src/main/ets/ProfileRepo";
import { Context, Want } from "@kit.AbilityKit";
import { SocketProxyService, SocketStubService, Profile, ProfileType, UpdateConfigParams, ClashConfig, migrateSnifferConfig, getHome,
  LogInfo,
  Provider,
  ProxyMode,
  ProxySort} from "proxy_core";
import { socket, vpnExtension } from "@kit.NetworkKit";
import { ConfigData } from "../common/entity/PageArgumentEntity";
import { convertTimeGapToMilliseconds } from "../common/entity/Constants";
import { PromptAction } from "@kit.ArkUI";
import { ProxyGroup } from "proxy_core/src/main/ets/models/Common";
import { ConfigExtendedParams } from "proxy_core/src/main/ets/models/ClashConfig";
import { EventHub, EventKey } from "../common/EventHub";
import { AppConfig, AppState, ClashCore, getPackageInfo } from "./AppState";
import  fs from  "@ohos.file.fs"
import { sleep } from "./EntryAbility";
import { ProxyItem } from "../common/datasources/ProxyData";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { readText } from "proxy_core/src/main/ets/fileUtils";
import { AccessControl, VpnRawOptions } from "proxy_core/src/main/ets/rpc/IClashManager";
import { cardManager } from "../common/utils/CardManageUtil";
import { PROXY_STARTED_DURATION_INIT_VALUE } from "../common/entity/Constants";
import { Timer } from "../common/utils/HHmmssTimer";
import { number2Time } from "../common/utils/TimeConvertUtil";
import { picker } from "@kit.CoreFileKit"
import { Xb_GetResourceString, Xb_ToastUtil } from "xb_components";
import { accessControlRdb } from "../common/datasources/AccessControlRdb";
import { syncVpnNoticePrefs } from "../common/utils/VpnNoticeConfigSync";
import { deviceInfo } from "@kit.BasicServicesKit";
import BuildProfile from 'BuildProfile';
import { resolveCoreMode } from '../common/services/CoreMode';
import { DELAY_NOT_MEASURED } from '../common/entity/DelayResult';

/** VPN 授权结果监听（vpnExtension.createVpnObserver）自 API 26.0.0 起可用 */
const VPN_OBSERVER_MIN_API = 26

export interface DelayInfo{
    name: string
    delay: number
}

export class ClashViewModel {
  vpnRequestId = 0;
  profileRepo = new ProfileRepo()
  socketProxy = new SocketProxyService()
  context: Context | undefined
  private coreOnlyDebug: boolean = false
  private localCore: SocketStubService | undefined
  private coreStartup: Promise<boolean> | undefined
  proxyStartedTimer = new Timer()
  static promptAction: PromptAction
  async init(context: Context, promptAction: PromptAction) {
    AppState.globalUA =  "clash.meta/1.19.5"
    this.context = context
    ClashViewModel.promptAction = promptAction
    await this.profileRepo.init(context)
    this.socketProxy.init(context)
    this.socketProxy.onConnectionRefused = () => {
      if (this.desiredRunning && !this.vpnOperation) {
        this.RecoverVpn().catch((e: Error) => { console.error('VPN 恢复失败', e.message) })
      }
    }
    await this.initGeoIp()
    this.registerVpnAuthObserver()
  }

  /** VPN 授权结果监听器（API 26+） */
  private vpnObserver: vpnExtension.VpnObserver | null = null

  /**
   * 注册 VPN 授权结果监听（API 26 起）：用户首次启动 VPN 的系统授权弹窗结果回调，
   * 拒绝时 Toast 明确提示。多次 on 仅最后 callback 生效，故每进程只注册一次；
   * 低版本系统（compatibleSdkVersion 17）无此 API，直接走原路径不崩溃。
   */
  registerVpnAuthObserver(): void {
    if (this.vpnObserver) {
      return
    }
    if (deviceInfo.sdkApiVersion < VPN_OBSERVER_MIN_API ||
      !canIUse('SystemCapability.Communication.NetManager.Vpn')) {
      hilog.info(0x0000, 'ClashViewModel', `当前系统 API ${deviceInfo.sdkApiVersion} 不支持 VpnObserver，跳过注册`)
      return
    }
    try {
      this.vpnObserver = vpnExtension.createVpnObserver()
      this.vpnObserver.onAuthorizationResult((granted: boolean) => {
        hilog.info(0x0000, 'ClashViewModel', `VPN 授权结果: ${granted}`)
        if (!granted) {
          // 用户拒绝授权：内核不可能启动成功，明确提示
          Xb_ToastUtil.showToast({
            message: Xb_GetResourceString($r('app.string.vpn_auth_denied'), this.context),
            duration: 3000
          })
        }
      })
      hilog.info(0x0000, 'ClashViewModel', 'VPN 授权结果监听已注册')
    } catch (e) {
      hilog.error(0x0000, 'ClashViewModel', `VPN 授权结果监听注册失败: ${(e as Error).message}`)
      this.vpnObserver = null
    }
  }

  /** 取消 VPN 授权结果监听（UIAbility 销毁时调用） */
  releaseVpnAuthObserver(): void {
    if (!this.vpnObserver) {
      return
    }
    try {
      this.vpnObserver.offAuthorizationResult()
    } catch (e) {
      hilog.error(0x0000, 'ClashViewModel', `VPN 授权结果监听取消失败: ${(e as Error).message}`)
    }
    this.vpnObserver = null
  }
  // 添加配置 url
  async addOrUpdateProfileByUrl(data: ConfigData, id: string | null) {
    const ua = AppStorage.get<ClashConfig>("clashConfig")?.["global-ua"]
    let profile = new Profile(ProfileType.Url, data.configUrl)
    if(id) {
      const old = await this.profileRepo.query(id)
      if(old)
        profile = old
    }
    profile.loadContext(this.context, ua)
    profile.url = data.configUrl
    profile.name = data.configName
    profile.isUpdating = data.disableUpdate
    profile.autoUpdate = data.isConfigAutoUpdate
    // 转换为毫秒
    profile.autoUpdateDuration = convertTimeGapToMilliseconds(
      data.configAutoUpdateTimeGapValue ?? 10,
      data.configAutoUpdateTimeGapTextPickerIndex
    )
    await profile.checkAndUpdate( this.socketProxy)
    const isExists = await profile.check();
    let value: number
    if (isExists) { // 本地文件存在
      value = await this.profileRepo.addOrUpdate(profile)
    } else {
      value = -1
      console.error("ClashBox文件保存失败");
      Xb_ToastUtil.showToast({message: "文件保存失败！"})
    }
    EventHub.sendEvent(EventKey.FetchProfile, null)
    console.info("EditConfig&UpdateConfig&ConfigSort configSaveTestTag", `文件名${profile.name} URL: ${profile.url} 保存结果: ${value}`)
  }

  // 批量插入配置
  async addOrUpdateProfiles(data: ProfileBackup[]) {
    await this.queueVpnOperation(async () => {
      await this.activation.exclusive(() => this.restoreProfiles(data));
    });
  }

  private async restoreProfiles(data: ProfileBackup[]): Promise<void> {
    const profiles = data.map((item: ProfileBackup) => restoreProfileMetadata(item));
    const ids = new Set<string>();
    for (const profile of profiles) {
      if (ids.has(profile.id)) throw new Error('备份包含重复的配置 ID');
      ids.add(profile.id);
    }
    await restoreProfilesAtomically(this.context, profiles, async (newProfile: Profile) => {
      const name = newProfile.name;
      newProfile.loadContext(this.context);
      if (newProfile.type === ProfileType.Url) {
        // URL配置
        await newProfile.update(this.socketProxy, newProfile.customRules)
      } else {
        // 本地文件配置
        try {
          let filePicker = new picker.DocumentViewPicker(this.context!)
          let options = new picker.DocumentSelectOptions()
          ClashViewModel.promptAction.showToast({ message: `${Xb_GetResourceString($r('app.string.file_config_restore_toast_1'), this.context)} ${name}` })
          const documentSelectResult = await filePicker.select(options)
          if (!documentSelectResult[0]) throw new Error('已取消配置文件恢复');
          newProfile.url = documentSelectResult[0]
        } catch (err) {
          console.error(`ClashBox Restore 文件选择失败 ${err.name} ${err.message}`)
          throw new Error('配置文件恢复未完成');
        }
        newProfile.loadContext(this.context)
        await newProfile.saveByUri(newProfile.url, (path: string): Promise<string> => this.socketProxy.vailConfig(path), newProfile.customRules)
      }
      newProfile.name = name ?? newProfile.name;
    }, async (restored: Profile[], replaceFiles: () => Promise<void>) => {
      // The successful restore is followed by application restart. Stop before
      // replacing active files so that cold start loads the restored selection.
      this.desiredRunning = false;
      ++this.intentGeneration;
      if (!await this.socketProxy.stopClash()) throw new Error('内核未确认 VPN 停止');
      await this.refreshVpnState();
      this.activation.forget();
      await this.profileRepo.restoreBatch(restored, replaceFiles);
    });
    EventHub.sendEvent(EventKey.FetchProfile, null)
  }

  async addOrUpdateProfileByFile(name: string, path: string, id: string | null) {
    let profile = new Profile(ProfileType.File, path)
    if (id) {
      const old = await this.profileRepo.query(id)
      if (old)
        profile = old
    }
    profile.loadContext(this.context)
    profile.name = name // decodeURIComponent(path.substring(path.lastIndexOf('/') + 1))
    await profile.saveByUri(path, (configPath: string): Promise<string> => this.socketProxy.vailConfig(configPath));
    const isExists = await profile.check();
    if (isExists) {
      try {
        const value = await this.profileRepo.addOrUpdate(profile)
        hilog.info(0xFF00, "EditConfig configSaveTestTag", `文件名${profile.name} URL: ${profile.url} 保存结果${value}`)
        EventHub.sendEvent(EventKey.FetchProfile, null)
      } catch (err) {
        throw new Error(err.message)
      }
    } else {
      ClashViewModel.promptAction.showToast({message: "文件保存失败！"})
    }
  }

  async saveProfileContent(id: string, content: string, expectedContent: string): Promise<void> {
    const profile = await this.getProfile(id);
    if (!profile) throw new Error('配置已被删除，请返回配置列表');
    profile.loadContext(this.context);
    await profile.saveEditedContent(content, (path: string): Promise<string> => this.socketProxy.vailConfig(path), expectedContent);
    EventHub.sendEvent(EventKey.FetchProfile, null);
  }

  async refreshProfileConfig(id: string | null): Promise<void> {
    // Read the persisted selection, never the page's placeholder/cached list item.
    const selectedId = AppStorage.get<AppConfig>('appConfig')?.currentProfileId
    await this.updateProfileConfig(id, false)
    if (selectedId && (id === null || id === selectedId) && await this.getProfile(selectedId)) {
      // The activation queue checks selection again: a refresh must not undo a later switch.
      await this.activation.reload(false, selectedId)
    }
  }

  async updateProfileConfig(id: string | null, notify: boolean = true): Promise<void> {
    const ua = AppStorage.get<ClashConfig>("clashConfig")?.["global-ua"]
    if (id) {
      const profile = await this.getProfile(id)
      if (profile && profile.type == ProfileType.Url && !profile.isUpdating) {
        try {
          profile.loadContext(this.context, ua)
          await profile.update(this.socketProxy)
          await this.profileRepo.updateDownloadMetadata(profile)
          if (notify && this.context) {
            ClashViewModel.promptAction.showToast({ message: `${Xb_GetResourceString($r('app.string.Configuration'), this.context)} ${profile.name} ${Xb_GetResourceString($r('app.string.update_success'), this.context)}`})
          }
        } catch (e) {
          let message = ""
          if (notify && this.context) {
            message = `${Xb_GetResourceString($r('app.string.Configuration'), this.context)} ${profile.name} ${Xb_GetResourceString($r('app.string.update_failed'), this.context)}: ${e.message} ${Xb_GetResourceString($r('app.string.check_configured_URL'), this.context)}`
            Xb_ToastUtil.showToast({message: message})
          }
          throw new Error(message || (e as Error).message || String(e))
        }
      }
    } else {
      const list = (await this.getProfiles()).filter(d => d.type == ProfileType.Url)
      for(let p of list) {
        if (!p.isUpdating) {
          p.loadContext(this.context, ua)
          await p.update(this.socketProxy)
          await this.profileRepo.updateDownloadMetadata(p)
        }
      }
    }
    EventHub.sendEvent(EventKey.FetchProfile, null)
  }
  async VailConfig(config: string): Promise<string>{
    return await this.socketProxy.vailConfig(config)
  }
  async changeProxy(profile: Profile, g:string, p: string){
    try {
      const changed = await this.activation.selectProxy(profile.id, g, p, async () => {
        const error = await this.socketProxy.changeProxy(g, p);
        if (error !== '') throw new Error(error);
      }, async () => {
        profile.proxySelected?.set(g, p);
        await this.profileRepo.updateProxySelection(profile.id, g, p);
      });
      if (!changed) throw new Error('当前配置已切换，请刷新节点列表');
      // 同步新节点名到共享 preferences，供 VPN 扩展进程刷新常驻通知标题
      if (this.context) {
        syncVpnNoticePrefs(this.context, p)
      }
      EventHub.sendEvent(EventKey.checkIpInfo)
    } catch (e) {
      ClashViewModel.promptAction.showToast({message: e.message, duration:3000})
    }
  }
  async setVpnOptions(options: VpnRawOptions){
    try {
      let result = await this.socketProxy.setOptionStates(options)
      console.log("setVpnOptions", result)
    } catch (e) {
      ClashViewModel.promptAction.showToast({message: e.message, duration:3000})
    }
  }


  delayMap: Map<string, DelayInfo> = new Map()
  private delayTestOperation?: Promise<number[]>

  private publishDelay(name: string, delay: number): void {
    const info: DelayInfo = { name: name, delay: delay }
    this.delayMap.set(name, info)
    EventHub.sendEvent(EventKey.TestDelay, info)
  }

  async testDelay(proxyName: string): Promise<number>{
    try {
      this.publishDelay(proxyName, 0)
      let delay = await this.socketProxy.healthCheck(proxyName)

      this.publishDelay(proxyName, delay)
      return delay;
    } catch (e) {
      this.publishDelay(proxyName, DELAY_NOT_MEASURED)
      ClashViewModel.promptAction.showToast({message: e.message, duration: 3000})
    }
    return DELAY_NOT_MEASURED;
  }

  testAllDelay(list: ProxyItem[]): Promise<number[]> {
    if (this.delayTestOperation) return this.delayTestOperation
    const pending = this.runDelayTests(list).finally(() => {
      if (this.delayTestOperation === pending) this.delayTestOperation = undefined
    })
    this.delayTestOperation = pending
    return pending
  }

  private async runDelayTests(list: ProxyItem[]): Promise<number[]> {
    const names = Array.from(new Set(list.map(item => item.name)))
    const results = new Map<string, number>()
    const testUrl = AppStorage.get<AppConfig>('appConfig')?.testUrl
    let connectionFailed = false
    for (const name of names) this.publishDelay(name, 0)
    // One bounded batch per IPC connection. Avoid queueing hundreds of open
    // single-node requests behind the native concurrency limit and RPC deadline.
    for (let offset = 0; offset < names.length; offset += 20) {
      const batch = names.slice(offset, offset + 20)
      try {
        const delays = await this.socketProxy.healthCheckBatch(batch, 3000, testUrl)
        for (const name of batch) {
          const delay = delays.get(name) ?? DELAY_NOT_MEASURED
          results.set(name, delay)
          this.publishDelay(name, delay)
        }
      } catch (error) {
        connectionFailed = true
        console.warn('批量测速服务请求失败', (error as Error).message)
        // Stop on a transport/protocol failure instead of flooding a dead service.
        for (const name of names.slice(offset)) {
          results.set(name, DELAY_NOT_MEASURED)
          this.publishDelay(name, DELAY_NOT_MEASURED)
        }
        break
      }
    }
    if (connectionFailed) {
      ClashViewModel.promptAction.showToast({
        message: $r('app.string.delay_test_connection_failed'), duration: 3000
      })
    }
    let appConfig = AppStorage.get<AppConfig>("appConfig")
    if (appConfig?.proxySort === ProxySort.Delay) {
      EventHub.sendEvent(EventKey.FetchProxyGroup)
    }
    return list.map(item => results.get(item.name) ?? DELAY_NOT_MEASURED);
  }

  async updateGeoData( geoType: string, geoName: string): Promise<string>{
    return this.socketProxy.updateGeoData(geoType, geoName)
  }
  async getTraffic(onlyProxy: boolean){
    return await this.socketProxy.queryTrafficNow(onlyProxy)
  }
  async getTotalTraffic(onlyProxy: boolean){
    return await this.socketProxy.queryTrafficTotal(onlyProxy)
  }
  async getProviders(): Promise<Provider[]>{
    return await this.socketProxy.queryProviders()
  }
  async checkIpInfo(){
    return await this.socketProxy.checkIpInfo()
  }
  async queryProviders(){
    return this.socketProxy.queryProviders()
  }
  async updateProvider(provider: Provider){
    let result = await this.socketProxy.updateProvider(provider)
    if(result && result != ""){
      ClashViewModel.promptAction.showToast({message: provider.name + ":" + result})
    }
  }
  async upLoadProvider(provider: Provider, fileUri: string) {
    if(!fileUri){
      return
    }
    let result = await this.socketProxy.upLoadProvider(provider, fileUri)
    if (result && result != ""){
      ClashViewModel.promptAction.showToast({message: provider.name + ":" + result})
    }
  }

  private logJob?: () => void;
  private logGeneration: number = 0;

  stopLog(): void {
    ++this.logGeneration;
    const cancel = this.logJob;
    this.logJob = undefined;
    cancel?.();
  }

  async startLog(enable: boolean, callback: (d: LogInfo) => void): Promise<void> {
    this.stopLog();
    if (!enable) return;
    const generation = this.logGeneration;
    try {
      const cancel = await this.socketProxy.setLogObserver((message: LogInfo) => {
        if (generation === this.logGeneration) callback(message);
      });
      if (generation !== this.logGeneration) cancel();
      else this.logJob = cancel;
    } catch (e) {
      if (generation === this.logGeneration) console.warn(`日志订阅失败：${(e as Error).message}`);
    }
  }

  async updateProfile(profile: Profile){
    await this.profileRepo.addOrUpdate(profile)
  }
  async updateCurrentGroup(id: string, name: string): Promise<void> {
    await this.activation.exclusive(async () => {
      const selected = AppStorage.get<AppConfig>('appConfig')?.currentProfileId;
      if (selected === id) await this.profileRepo.updateCurrentGroup(id, name);
    });
  }

  async resetProfiles(resetSettings: () => Promise<void>): Promise<void> {
    this.desiredRunning = false;
    ++this.intentGeneration;
    await this.queueVpnOperation(async () => {
      await this.activation.reset(async () => {
        await this.profileRepo.ClearAll(this.context!);
        this.proxyGroups = [];
        await resetSettings();
        cardManager.setAppConfig(AppStorage.get<AppConfig>('appConfig') || new AppConfig());
      });
    });
  }
  async getProfiles(): Promise<Profile[]>{
    return await this.profileRepo.queryAll()
  }
  async getProfile(id: string): Promise<Profile | null>{
    return await this.profileRepo.query(id)
  }
  async deleteProfile(id: string): Promise<void>{
    // Keep lock order identical to StartVpn: VPN operations -> config operations.
    await this.queueVpnOperation(async () => {
      await this.activation.remove(id, async () => {
        const profile = await this.getProfile(id);
        if (profile) {
          profile.loadContext(this.context);
          await profile.delete();
        }
        await this.profileRepo.delete(id);
      }, () => {
        const app = AppStorage.get<AppConfig>('appConfig') || cardManager.getAppConfig() || new AppConfig();
        const next = JSON.parse(JSON.stringify(app)) as AppConfig;
        next.currentProfileId = '';
        next.currentProfileName = undefined;
        next.currentProxyName = undefined;
        cardManager.setAppConfig(next);
        AppStorage.setOrCreate('appConfig', next);
        this.proxyGroups = [];
        if (this.context) syncVpnNoticePrefs(this.context);
        EventHub.sendEvent(EventKey.FetchProxyGroup, null);
      });
      EventHub.sendEvent(EventKey.FetchProfile, null);
    });
  }
  async getConnections(){
     return await this.socketProxy.queryConnections()
  }
  async closeConnection(id:string){
    return await this.socketProxy.closeConnection(id)
  }
  async clearConnections(){
    return await this.socketProxy.clearConnections()
  }
  async getRequestList(){
    return await this.socketProxy.getRequestList()
  }
  async clearRequestList(){
    return await this.socketProxy.clearRequestList()
  }
  async getProxyGroups(model: ProxyMode): Promise<ProxyGroup[]>{
    try {
      let list = await this.socketProxy.queryProxyGroups(model)
      let favoriteProxys = AppStorage.get<Map<string, string>>("favoriteProxys")
      const groups = list.map((g)=>{
        g.proxies = g.proxies.map((p) => {
          // p.isShowFavoriteProxy = favoriteProxys?.get(g.name + "|" + p.name) != null
          p.latency = -1
          p.g = g.name
          return p
        })
        return g
      })
      return groups
    } catch (e) {
      console.error(" 获取代理失败: ", e.stack)
      ClashViewModel.promptAction.showToast({message: "获取代理失败: " + (e.message || e) + e.stack})
    }
    return []
  }
  /** 仅冷启动参数启用，不持久化；Release 构建始终走系统 VPN 授权。 */
  configureCoreOnlyDebug(enabled: boolean): void {
    this.coreOnlyDebug = BuildProfile.DEBUG && enabled
  }

  async destroyLocalCore(): Promise<void> {
    if (this.coreStartup) await this.coreStartup.catch(() => false)
    await this.releaseLocalCore()
  }

  private async releaseLocalCore(): Promise<void> {
    const service = this.localCore
    this.localCore = undefined
    if (service) await service.destroy()
  }

  ChangeCore(coreType: ClashCore | undefined = undefined, restart: boolean = true): Promise<boolean> {
    if (this.coreStartup) return this.coreStartup
    const pending = this.startCore(coreType, restart).finally(() => {
      if (this.coreStartup === pending) this.coreStartup = undefined
    })
    this.coreStartup = pending
    return pending
  }

  private async startCore(coreType: ClashCore | undefined, restart: boolean): Promise<boolean> {
    const context = this.context
    if (!context?.applicationInfo?.name) throw new Error('应用尚未初始化，无法启动内核')
    try { assertNativeCompatibility(); } catch (e) {
      ClashViewModel.promptAction?.showToast({ message: (e as Error)?.message ?? '原生内核不兼容', duration: 5000 });
      throw e as Error;
    }
    this.socketProxy.resetCompatibility();
    let requestId = Date.now();
    this.vpnRequestId = requestId;
    const selectedCore = resolveCoreMode(coreType ?? AppStorage.get<AppConfig>('appConfig')?.clashCore, BuildProfile.DEBUG)
    if (this.coreOnlyDebug) {
      if (!this.localCore && await this.socketProxy.isSocketReady()) {
        throw new Error('已有内核服务运行，请先停止 VPN 再启动内核调试模式')
      }
      await this.startLocalCore(requestId, false)
      for (let i = 0; i < 30 && !await this.socketProxy.isSocketReady(); i++) await sleep(200)
      // 页面可能已向旧 socket 发出握手；监听器就绪后必须重新确认这一代内核。
      this.socketProxy.resetCompatibility()
      await this.socketProxy.ensureCompatibility()
      hilog.info(0x0000, 'ClashViewModel', '内核调试模式已就绪；系统 VPN 未启动')
      return true
    }
    if (!restart && await this.socketProxy.isSocketReady()) {
      // UI 冷启动时可以附着仍在运行的 VPN 扩展，不能重启或要求其重写 readiness lock。
      await this.socketProxy.ensureCompatibility()
      return true
    }
    const vpnWant = {
      deviceId: "",
      bundleName: context.applicationInfo.name,
      abilityName: "ClashVpnAbility",
      parameters: { "ClashCore" : selectedCore, requestId }
    } as Want
    // 若vpn进程没启动直接停止，会导致卡死或闪退， 不同系统不同现象
    if (restart) {
      await this.releaseLocalCore()
      // 停止vpn进程
      try {
        await vpnExtension.stopVpnExtensionAbility(vpnWant)
      } catch (error) {
        console.error(`ClashViewModel.ChangeCore restart过程中VPN进程终止失败: ${JSON.stringify(error)}`)
      }
    }
    try {
      await this.requestVpnExtension(vpnWant)
    } catch (error) {
      throw new Error(`VPN 扩展启动失败: ${(error as Error)?.message ?? '系统未完成授权或缺少 VPN 授权组件'}`)
    }
    // 前台内核模式由 UI 进程持有服务，不能先等待只有本服务才会创建的 socket/lock。
    if (selectedCore !== ClashCore.mihomo) await this.startLocalCore(requestId, true)
    let result = false
    for (let i = 0; i < 30; i++) {
      if (await this.checkVpnVpnAbility(requestId) && await this.socketProxy.isSocketReady()) {
        this.socketProxy.resetCompatibility()
        try { await this.socketProxy.ensureCompatibility(); } catch (e) {
          ClashViewModel.promptAction?.showToast({ message: (e as Error).message, duration: 5000 });
          throw e as Error;
        }
        result = true
        break
      }
      await sleep(200)
    }
    if (!result && restart) {
      ClashViewModel.promptAction.showToast({message:"VpnAbility请求失败! 请重启应用"})
    }
    return result;
  }

  private async startLocalCore(requestId: number, allowVpn: boolean): Promise<void> {
    if (this.localCore) {
      await this.localCore.lockVpn(requestId)
      return
    }
    const service = new SocketStubService(this.context!, (state) => { cardManager.pushCartVpnState(state) }, allowVpn)
    try {
      await service.startService(requestId)
      this.localCore = service
    } catch (error) {
      await service.destroy().catch(() => {})
      throw error as Error
    }
  }

  private requestVpnExtension(want: Want): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('等待系统 VPN 授权超时，请授权后重试')), 15000)
      try {
        vpnExtension.startVpnExtensionAbility(want).then(() => {
          clearTimeout(timer)
          resolve()
        }, (error: Error) => {
          clearTimeout(timer)
          reject(error)
        })
      } catch (error) {
        clearTimeout(timer)
        reject(error)
      }
    })
  }

  private async checkVpnVpnAbility(reqId: number): Promise<boolean>{
    let lockPath = this.context?.filesDir + '/vpn_ipc.lock';
    try {
      if (!await fs.access(lockPath, fs.AccessModeType.EXIST)) {
        return false;
      } else {
        let requestId = await readText(lockPath)
        console.log('ClashViewModel.checkVpnVpnAbility 检查文件vpn_ipc.lock是否存在 readText成功：', requestId == reqId + "")
        return requestId == reqId + "";
      }
    } catch (error) {
      console.error('ClashViewModel.checkVpnVpnAbility 检查文件vpn_ipc.lock是否存在失败：', error)
      return false
    }
  }

  private activation = new ConfigActivationService({
    selectedId: (): string => (AppStorage.get<AppConfig>('appConfig') || cardManager.getAppConfig())?.currentProfileId ?? '',
    prepare: (id: string, update: boolean, patch: boolean, cancelled: () => boolean): Promise<ConfigSnapshot> =>
      this.prepareActivation(id, update, patch, cancelled),
    apply: async (snapshot: ConfigSnapshot): Promise<void> => {
      const error = await this.socketProxy.loadConfig(snapshot.payload);
      if (error !== '') throw new Error(error);
    },
    commit: (snapshot: ConfigSnapshot): void => {
      const app = AppStorage.get<AppConfig>('appConfig') || cardManager.getAppConfig() || new AppConfig();
      const next = JSON.parse(JSON.stringify(app)) as AppConfig;
      next.currentProfileId = snapshot.id;
      next.currentProfileName = snapshot.name;
      try {
        cardManager.setAppConfig(next);
        AppStorage.setOrCreate('appConfig', next);
      } catch (e) {
        AppStorage.setOrCreate('appConfig', app);
        cardManager.setAppConfig(app);
        throw e as Error;
      }
      try { EventHub.sendEvent(EventKey.FetchProxyGroup, null); } catch (_) { console.warn('配置列表刷新失败'); }
    },
    stop: async (): Promise<void> => {
      this.desiredRunning = false;
      ++this.intentGeneration;
      if (!await this.socketProxy.stopClash()) throw new Error('内核未确认 VPN 停止');
      await this.refreshVpnState();
    }
  } as ConfigActivationHost);

  private async prepareActivation(id: string, update: boolean, patch: boolean,
    cancelled: () => boolean): Promise<ConfigSnapshot> {
    const profile = await this.profileRepo.query(id);
    if (!profile) throw new Error('配置不存在或已被删除');
    const config = migrateSnifferConfig(
      AppStorage.get<ClashConfig>('clashConfig') || cardManager.getClashConfig() || new ClashConfig());
    profile.loadContext(this.context, config['global-ua']);
    profile.shouldCancelUpdate = cancelled;
    if (update && profile.type === ProfileType.Url && !profile.isUpdating) {
      await profile.update(this.socketProxy);
      await this.profileRepo.updateDownloadMetadata(profile);
      EventHub.sendEvent(EventKey.FetchProfile, null);
    }
    const source = await new ProfileStorage(this.context, id, cancelled).transaction((files) => files.read());
    if (!source) throw new Error('配置文件不存在或为空');
    const app = AppStorage.get<AppConfig>('appConfig') || cardManager.getAppConfig();
    const payload: UpdateConfigParams = { 'profile-id': id, source: source, config: config,
      params: { 'is-patch': patch, 'is-compatible': true, 'override-dns': config.overrideDns ?? false,
        'selected-map': profile.getSelectedMap(), 'test-url': app?.testUrl || new AppConfig().testUrl } };
    return { id: id, name: profile.name ?? id, payload: JSON.parse(JSON.stringify(payload)) as UpdateConfigParams };
  }

  async activateProfile(id: string, update: boolean = false): Promise<boolean> {
    return this.activation.activate(id, update);
  }

  private desiredRunning: boolean = false
  private vpnOperation: Promise<void> | undefined
  private vpnQueue: Promise<void> = Promise.resolve()
  private intentGeneration: number = 0
  private lastRecoveryAttempt: number = 0
  private vpnState: VpnSnapshot = initialVpnState(VpnPhase.Unknown);
  get vpnStarted(): boolean { return this.vpnState.running; }
  get vpnRequested(): boolean { return this.desiredRunning; }
  private stateTimer: number = -1;
  private stateQueryRunning: boolean = false;

  startStateMonitoring(): void {
    this.stopStateMonitoring();
    this.refreshVpnState();
    this.stateTimer = setInterval(() => { this.refreshVpnState(); }, 2000);
  }

  stopStateMonitoring(): void {
    if (this.stateTimer !== -1) clearInterval(this.stateTimer);
    this.stateTimer = -1;
  }

  private publishVpnState(state: VpnSnapshot): void {
    const previous = this.vpnState;
    this.vpnState = state;
    AppStorage.setOrCreate('vpnState', state);
    EventHub.sendEvent(EventKey.VpnStateChanged, state);
    cardManager.pushCartVpnState(state);
    if (state.phase === VpnPhase.Unknown) return;
    if (state.running && (!previous.running || state.startedAt !== previous.startedAt)) {
      EventHub.sendEvent(EventKey.StartedClash);
      this.proxyStartedTimer.start((time) => {
        EventHub.sendEvent(EventKey.ProxyDuration, time);
        cardManager.pushCartVpnServiceTime(number2Time(time));
      }, state.startedAt);
    } else if (!state.running && (previous.running || previous.phase === VpnPhase.Unknown)) {
      EventHub.sendEvent(EventKey.StopedClash);
      this.proxyStartedTimer.reset();
    }
  }

  private projectVpnPhase(phase: VpnPhase, error: string = ''): void {
    const previous = this.vpnState;
    this.publishVpnState({ phase: phase, running: previous.running, startedAt: previous.startedAt,
      desiredRunning: this.desiredRunning, generation: this.intentGeneration, error: error });
  }

  private async reconcileVpnState(): Promise<void> {
    try {
      const state = await this.socketProxy.queryVpnState();
      this.desiredRunning = state.desiredRunning;
      this.publishVpnState(state);
    } catch (e) {
      this.projectVpnPhase(VpnPhase.Unknown, (e as Error).message);
    }
  }

  async ReStartVpn(): Promise<void> {
    if (!this.vpnStarted) return
    await this.StopVpn()
    await this.StartVpn()
  }

  async refreshVpnState(): Promise<void> {
    if (this.vpnOperation || this.stateQueryRunning) return;
    this.stateQueryRunning = true;
    const generation = this.intentGeneration;
    try {
      const state = await this.socketProxy.queryVpnState();
      if (this.vpnOperation || generation !== this.intentGeneration) return;
      this.desiredRunning = state.desiredRunning;
      this.publishVpnState(state);
    } catch (e) {
      if (!this.vpnOperation && generation === this.intentGeneration) {
        this.projectVpnPhase(VpnPhase.Unknown, (e as Error).message);
      }
    } finally { this.stateQueryRunning = false; }
  }

  async RecoverVpn(): Promise<void> {
    if (this.vpnOperation) return this.vpnOperation
    if (Date.now() - this.lastRecoveryAttempt < 10000) return
    this.lastRecoveryAttempt = Date.now()
    return this.StartVpn()
  }

  private queueVpnOperation(work: () => Promise<void>): Promise<void> {
    const pending = this.vpnQueue.then(work)
    const tracked = pending.finally(() => {
      if (this.vpnOperation === tracked) this.vpnOperation = undefined
    })
    this.vpnQueue = tracked.catch(() => {})
    this.vpnOperation = tracked
    return tracked
  }

  async StartVpn(): Promise<void> {
    if (this.coreOnlyDebug) throw new Error('当前为内核调试模式，不能启动系统 VPN')
    this.desiredRunning = true
    const generation = ++this.intentGeneration
    return this.queueVpnOperation(() => this.startVpnConfirmed(generation))
  }

  private async startVpnConfirmed(generation: number): Promise<void> {
    if (!this.desiredRunning || generation !== this.intentGeneration) return;
    this.projectVpnPhase(VpnPhase.Starting);
    try {
      let ready = await this.socketProxy.isSocketReady();
      if (!ready) ready = await this.ChangeCore(undefined, true);
      if (!ready) throw new Error('VPN 扩展未就绪');
      await this.socketProxy.ensureCompatibility();
      if (!this.desiredRunning || generation !== this.intentGeneration) return;
      const current = await this.socketProxy.queryVpnState();
      if (!this.desiredRunning || generation !== this.intentGeneration) return;
      if (current.running) { this.publishVpnState(current); return; }
      if (await this.loadConfig(false, 'StartVpn') === false) throw new Error('请先选择有效配置');
      if (this.context) await syncVpnNoticePrefs(this.context);
      await this.loadVpnOptions();
      if (!this.desiredRunning || generation !== this.intentGeneration) return;
      const started = await this.socketProxy.startClash();
      if (!this.desiredRunning || generation !== this.intentGeneration) {
        if (started) await this.socketProxy.stopClash();
        return;
      }
      if (!started) throw new Error('VPN 启动失败');
      const state = await this.socketProxy.queryVpnState();
      if (generation !== this.intentGeneration) return;
      this.publishVpnState(state);
      EventHub.sendEvent(EventKey.checkIpInfo);
    } catch (e) {
      if (generation === this.intentGeneration) await this.reconcileVpnState();
      throw e as Error;
    }
  }
  async loadVpnOptions(){
    // 使用首选项持久化单个节点信息供卡片拉起服务
    let appConfig = AppStorage.get<AppConfig>("appConfig") || cardManager.getAppConfig()
    let clashConfig = AppStorage.get<ClashConfig>("clashConfig") || cardManager.getClashConfig()
    if (appConfig == null)
      return
    if (appConfig!.accessControl) {
      // 从数据库加载白名单
      const whiteApps = await accessControlRdb.getAppsByDomain('WHITE', 'name');
      // 提取出处于“选中”状态的包名
      let acceptList = whiteApps.filter(a => a.isSelected).map(a => a.package_name);
      // 补充强制放行的包名
      const protectedPackages = [
        this.context?.applicationInfo.name as string,
        'com.atomicservice.5765880207855877209'
      ];
      // 去重并加入保护列表
      protectedPackages.forEach(pkg => {
        if (pkg && !acceptList.includes(pkg)) {
          acceptList.push(pkg);
        }
      });
      // 从数据库加载黑名单
      const blackApps = await accessControlRdb.getAppsByDomain('BLACK', 'name');
      // 提取出处于“选中”状态的包名
      const rejectList = blackApps.filter(a => a.isSelected).map(a => a.package_name);
      console.log(`AccessControl 将加载 acceptList ${acceptList.length} 个，rejectList ${rejectList.length} 个`)
      const accessControl = {
        tunIp : clashConfig?.tun?.["tun-ip"],
        // Capture IPv6 at the VPN layer even when Mihomo DNS/outbound IPv6 remains disabled.
        ipv6: true,
        routeAddress: clashConfig?.["route-address"] ?? [],
        accessControl: { mode:appConfig?.accessControlMode ?? "", acceptList: acceptList, rejectList: rejectList } as AccessControl
      } as VpnRawOptions
      await this.socketProxy.setOptionStates(accessControl)
    } else {
      const accessControl = {
        tunIp : clashConfig?.tun?.["tun-ip"],
        // Capture IPv6 at the VPN layer even when Mihomo DNS/outbound IPv6 remains disabled.
        ipv6: true,
        routeAddress: clashConfig?.["route-address"] ?? [],
        accessControl: { mode:appConfig?.accessControlMode ?? "", acceptList: [], rejectList: [] } as AccessControl } as VpnRawOptions
      await this.socketProxy.setOptionStates(accessControl)
    }
    // 在日志控制台 过滤关键字 vpnConfig, 验证是否配置成功

  }

  async StopVpn(): Promise<void> {
    this.desiredRunning = false;
    const generation = ++this.intentGeneration;
    return this.queueVpnOperation(async () => {
      this.projectVpnPhase(VpnPhase.Stopping);
      try {
        if (!await this.socketProxy.stopClash()) throw new Error('内核未确认 VPN 停止');
        const stopped = initialVpnState();
        stopped.generation = this.intentGeneration;
        stopped.desiredRunning = this.desiredRunning;
        this.publishVpnState(stopped);
        EventHub.sendEvent(EventKey.StopedClashEntry);
        EventHub.sendEvent(EventKey.checkIpInfo);
      } catch (e) {
        if (generation === this.intentGeneration) await this.reconcileVpnState();
        throw e as Error;
      }
    });
  }

  async getRuntime(){
    return await this.socketProxy.getRuntime()
  }
  // 校验是否配置成功
  async vpnConfigIsLoad(){
    const flag = await this.socketProxy.vpnConfigIsLoad()
    return flag
  }

  async initProfile() {
    let appConfig = AppStorage.get<AppConfig>("appConfig") || cardManager.getAppConfig()
    EventHub.sendEvent(EventKey.StartLog, appConfig?.enableLogger)
    const attached = await this.activation.attach(async (): Promise<ConfigSnapshot | undefined> => {
      const state = await this.socketProxy.queryVpnState();
      if (!state.running) return undefined;
      const payload = await this.socketProxy.getConfigSnapshot();
      if (!payload) return undefined;
      const id = payload['profile-id'];
      const profile = await this.getProfile(id);
      if (!profile) throw new Error('运行配置已被删除，请先停止 VPN 并重新选择配置');
      return { id: id, name: profile.name ?? id, payload: payload };
    });
    if (!attached) await this.loadConfig(false, 'initProfile')
    EventHub.sendEvent(EventKey.FetchProxyGroup)
    console.error("ClashViewModel.initProfile 初始化成功");
  }

  proxyGroups :ProxyGroup[] = []

  async loadConfig(patch: boolean = true, name?: string): Promise<boolean> {
    return this.activation.reload(patch);
  }

  async initGeoIp(){
    let geoIp = await readFile(this.context?.resourceDir + "/geoip.metadb")
    let home = await getHome(this.context)
    writeFile(home+ "/geoip.metadb", geoIp)
    let geoip = await readFile(this.context?.resourceDir + "/GeoIP.dat")
    writeFile(home + "/GeoIP.dat", geoip)
    let geoSite = await readFile(this.context?.resourceDir + "/GeoSite.dat")
    writeFile(home + "/GeoSite.dat", geoSite)
    let Country = await readFile(this.context?.resourceDir + "/ASN.mmdb")
    writeFile(home + "/ASN.mmdb", Country)

  }
}
export async  function readFile(filePath: string): Promise<Uint8Array | null> {
  if(!await fs.access(filePath))
    return null;
  const file = await fs.open(filePath)
  const stats = await fs.stat(filePath)
  let bufSize = stats.size;
  let buf = new ArrayBuffer(bufSize);
  await fs.read(file.fd, buf, { offset: 0, length: bufSize });
  await fs.close(file);
  return new Uint8Array(buf);
}
export function writeFile(filePath: string, data: Uint8Array | null) {
  try {
    // 防止资源被覆盖
    if (fs.accessSync(filePath, fs.AccessModeType.EXIST))
      return;
    if(data != null && data.byteLength > 0){
      const file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE| fs.OpenMode.TRUNC)
      fs.writeSync(file.fd, data.buffer);
      fs.fsyncSync(file.fd)
      fs.closeSync(file);
    }
  }catch (e) {
    hilog.error(0x0000, 'EntryAbility', '%{public}s', 'write ' + filePath + ' failure: ' + e.message + e.stack);
  }

}

export default new ClashViewModel()
