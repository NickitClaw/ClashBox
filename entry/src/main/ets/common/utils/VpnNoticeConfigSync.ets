import { Context } from '@kit.AbilityKit';
import { AppConfig, UIConfig } from '../../entryability/AppState';
import { VpnNoticePrefs, writeVpnNoticePrefs } from 'proxy_core';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 把 UI 侧的通知开关与当前节点名同步到跨进程共享 preferences（clashbox_vpn_notice）。
 * VPN 扩展进程发布/刷新常驻通知、看门狗发布重连通知时读取该文件。
 *
 * 同步时机：启动 VPN 前、切换节点后、通知相关开关变化后、删除当前配置后。
 * @param proxyNameOverride 部分切换节点的调用方不写 appConfig.currentProxyName，此时显式传入新节点名
 */
export async function syncVpnNoticePrefs(context: Context, proxyNameOverride?: string): Promise<void> {
  try {
    const uiConfig = AppStorage.get<UIConfig>('uiConfig') ?? new UIConfig()
    const appConfig = AppStorage.get<AppConfig>('appConfig')
    const prefs = new VpnNoticePrefs()
    prefs.enabledNotice = uiConfig.Enablednotice
    prefs.permanentNotice = uiConfig.EnabledPermanentnotice
    prefs.statusNotice = uiConfig.EnabledStatusNotice
    prefs.coexistNotice = uiConfig.EnabledCoexistNotice
    prefs.backgrounder = uiConfig.Enablebackgrounder
    prefs.proxyName = proxyNameOverride ?? appConfig?.currentProxyName ?? ''
    // 看门狗"点击重连"通知的本地化文案：资源在 entry 侧，扩展进程无法引用，随同步写入
    prefs.reconnectText = context.resourceManager.getStringSync($r('app.string.vpn_reconnect_notice_text').id)
    await writeVpnNoticePrefs(context, prefs)
  } catch (e) {
    hilog.error(0xFF00, 'VpnNoticeConfigSync', `同步常驻通知配置失败: ${(e as Error).message}`)
  }
}
