import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';

/**
 * 常驻通知配置的跨进程共享存储。
 * UI 进程在通知开关变化 / 切换节点 / 启动 VPN 前写入；VPN 扩展进程发布与更新常驻通知前读取。
 * 不使用 PersistentStorage(uiConfig/appConfig) 的原因：其底层 preferences 文件名是 ArkUI 内部实现细节，
 * 扩展进程无法可靠读取；独立 preferences 文件 + 显式 flush 是稳定契约。
 */
export const VPN_NOTICE_PREFS_STORE: string = 'clashbox_vpn_notice'

const KEY_ENABLED_NOTICE: string = 'enabledNotice'
const KEY_PERMANENT_NOTICE: string = 'permanentNotice'
const KEY_STATUS_NOTICE: string = 'statusNotice'
const KEY_COEXIST_NOTICE: string = 'coexistNotice'
const KEY_BACKGROUNDER: string = 'backgrounder'
const KEY_PROXY_NAME: string = 'proxyName'
const KEY_RECONNECT_TEXT: string = 'reconnectText'

/** 看门狗自愈失败通知文案的兜底值（正常由 UI 侧按当前语言写入） */
export const DEFAULT_RECONNECT_TEXT: string = 'VPN 已断开，点击重连'

export class VpnNoticePrefs {
  /** 通知总开关（uiConfig.Enablednotice） */
  enabledNotice: boolean = true
  /** 常驻通知开关（uiConfig.EnabledPermanentnotice） */
  permanentNotice: boolean = true
  /** 常驻状态栏（uiConfig.EnabledStatusNotice），为 true 时使用 SERVICE_INFORMATION 高等级槽位 */
  statusNotice: boolean = false
  /** 通知共存（uiConfig.EnabledCoexistNotice） */
  coexistNotice: boolean = false
  /** 任务保持（uiConfig.Enablebackgrounder，平板/2in1 长时任务自带通知） */
  backgrounder: boolean = false
  /** 当前节点名（appConfig.currentProxyName），作为常驻通知标题 */
  proxyName: string = ''
  /** 看门狗自愈失败通知正文（UI 侧写入的本地化文案） */
  reconnectText: string = DEFAULT_RECONNECT_TEXT
}

/** 与原 UI 侧发布条件一致: Enablednotice && EnabledPermanentnotice && (!Enablebackgrounder || EnabledCoexistNotice) */
export function shouldPublishVpnNotice(p: VpnNoticePrefs): boolean {
  return p.enabledNotice && p.permanentNotice && (!p.backgrounder || p.coexistNotice)
}

/** UI 进程写入：进程内缓存实例即可（同进程连续写不需要重读磁盘） */
export async function writeVpnNoticePrefs(context: Context, prefs: VpnNoticePrefs): Promise<void> {
  try {
    const store = preferences.getPreferencesSync(context, { name: VPN_NOTICE_PREFS_STORE })
    store.putSync(KEY_ENABLED_NOTICE, prefs.enabledNotice)
    store.putSync(KEY_PERMANENT_NOTICE, prefs.permanentNotice)
    store.putSync(KEY_STATUS_NOTICE, prefs.statusNotice)
    store.putSync(KEY_COEXIST_NOTICE, prefs.coexistNotice)
    store.putSync(KEY_BACKGROUNDER, prefs.backgrounder)
    store.putSync(KEY_PROXY_NAME, prefs.proxyName)
    store.putSync(KEY_RECONNECT_TEXT, prefs.reconnectText)
    await store.flush()
  } catch (e) {
    console.error(`VpnNoticeStore 写入失败: ${(e as Error).message}`)
  }
}

/**
 * VPN 扩展进程读取：preferences 实例有进程内缓存，跨进程写入不可见，
 * 先 removePreferencesFromCacheSync 再 getPreferencesSync 强制从磁盘加载最新值。
 */
export function readVpnNoticePrefs(context: Context): VpnNoticePrefs {
  const result = new VpnNoticePrefs()
  try {
    const options: preferences.Options = { name: VPN_NOTICE_PREFS_STORE }
    preferences.removePreferencesFromCacheSync(context, options)
    const store = preferences.getPreferencesSync(context, options)
    result.enabledNotice = store.getSync(KEY_ENABLED_NOTICE, true) as boolean
    result.permanentNotice = store.getSync(KEY_PERMANENT_NOTICE, true) as boolean
    result.statusNotice = store.getSync(KEY_STATUS_NOTICE, false) as boolean
    result.coexistNotice = store.getSync(KEY_COEXIST_NOTICE, false) as boolean
    result.backgrounder = store.getSync(KEY_BACKGROUNDER, false) as boolean
    result.proxyName = store.getSync(KEY_PROXY_NAME, '') as string
    result.reconnectText = store.getSync(KEY_RECONNECT_TEXT, DEFAULT_RECONNECT_TEXT) as string
  } catch (e) {
    console.error(`VpnNoticeStore 读取失败: ${(e as Error).message}`)
  }
  return result
}
