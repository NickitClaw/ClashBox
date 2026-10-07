import { notificationManager } from '@kit.NotificationKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { JSON } from '@kit.ArkTS';
import { getTraffic } from 'libflclash.so';
import { Traffic } from '../models/Common';
import { DEFAULT_RECONNECT_TEXT, readVpnNoticePrefs, shouldPublishVpnNotice, VpnNoticePrefs } from './VpnNoticeStore';

const TAG = 'VpnNotice'

/** 常驻通知 ID：固定值，VPN 停止时扩展进程与 UI 进程都可据此取消（通知是应用级的） */
export const VPN_NOTICE_ID: number = 100010
/** 看门狗自愈失败"点击重连"通知 ID */
export const VPN_RECONNECT_NOTICE_ID: number = 100011
/** 通知刷新间隔，与原 UI 侧 setInterval 一致 */
const NOTICE_UPDATE_INTERVAL_MS: number = 1500

interface NoticeContent {
  title: string
  text: string
  slotType: notificationManager.SlotType
}

/**
 * VPN 常驻通知控制器，运行在 VPN 扩展进程内。
 * VPN 激活期间该进程由系统保活，因此 UI 进程退后台被挂起后通知仍能持续刷新。
 * 速率来源：同进程 NAPI 直调内核 getTraffic()，无需走 clash_go.sock。
 */
export class VpnNoticeController {
  private context: common.Context
  private timerId: number = -1
  private wantAgentObj?: WantAgent

  constructor(context: common.Context) {
    this.context = context
  }

  /** VPN 启动成功后调用：开关条件满足时发布常驻通知并开始定时刷新（幂等，重复调用先停再启） */
  async start(): Promise<void> {
    this.stopTimer()
    const prefs = readVpnNoticePrefs(this.context)
    if (!shouldPublishVpnNotice(prefs)) {
      console.info(`${TAG} 常驻通知开关未启用，跳过发布`)
      return
    }
    try {
      if (!await notificationManager.isNotificationEnabled()) {
        console.warn(`${TAG} 应用通知权限未授予，跳过发布`)
        return
      }
    } catch (e) {
      console.error(`${TAG} 通知权限检查失败: ${(e as Error).message}`)
      return
    }
    await this.publish(this.buildContent(prefs))
    this.timerId = setInterval(() => {
      this.tick()
    }, NOTICE_UPDATE_INTERVAL_MS)
    console.info(`${TAG} 常驻通知已发布并开始刷新 id=${VPN_NOTICE_ID}`)
  }

  /** VPN 停止 / 进程销毁时调用：停止刷新并取消常驻通知（重复调用安全） */
  stop(): void {
    this.stopTimer()
    notificationManager.cancel(VPN_NOTICE_ID)
      .then(() => console.info(`${TAG} 常驻通知已取消 id=${VPN_NOTICE_ID}`))
      .catch((e: Error) => console.warn(`${TAG} 取消常驻通知失败(可能不存在): ${e.message}`))
  }

  private stopTimer(): void {
    if (this.timerId != -1) {
      clearInterval(this.timerId)
      this.timerId = -1
    }
  }

  /** 每 tick 重读共享配置：运行中关闭常驻通知开关时立即撤下通知 */
  private async tick(): Promise<void> {
    const prefs = readVpnNoticePrefs(this.context)
    if (!shouldPublishVpnNotice(prefs)) {
      console.info(`${TAG} 常驻通知开关已关闭，停止刷新并取消通知`)
      this.stop()
      return
    }
    await this.publish(this.buildContent(prefs))
  }

  private buildContent(prefs: VpnNoticePrefs): NoticeContent {
    let up = '0 KB'
    let down = '0 KB'
    try {
      const raw = JSON.parse(getTraffic()) as Record<string, number>
      const traffic = new Traffic(raw?.up ?? 0, raw?.down ?? 0)
      up = traffic.up.toString()
      down = traffic.down.toString()
    } catch (e) {
      console.warn(`${TAG} getTraffic 解析失败: ${(e as Error).message}`)
    }
    return {
      title: prefs.proxyName || 'ClashBox',
      text: `${up}/s ↑ ${down}/s ↓`,
      // 服务提醒类型 -> LEVEL_HIGH; CONTENT_INFORMATION -> LEVEL_MIN（与原 UI 侧行为一致）
      slotType: prefs.statusNotice ? notificationManager.SlotType.SERVICE_INFORMATION :
        notificationManager.SlotType.CONTENT_INFORMATION
    }
  }

  private async publish(content: NoticeContent): Promise<void> {
    try {
      const request: notificationManager.NotificationRequest = {
        id: VPN_NOTICE_ID,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: content.title,
            text: content.text,
            additionalText: ''
          }
        },
        // 每次 publish 都携带 wantAgent，确保点击跳回 EntryAbility 不被覆盖更新丢掉
        wantAgent: await this.getWantAgent(),
        notificationSlotType: content.slotType,
        isAlertOnce: true,
        tapDismissed: false
      }
      await notificationManager.publish(request)
    } catch (e) {
      console.error(`${TAG} 常驻通知发布/更新失败: ${(e as Error).message}`)
    }
  }

  private async getWantAgent(): Promise<WantAgent | undefined> {
    if (this.wantAgentObj) {
      return this.wantAgentObj
    }
    try {
      this.wantAgentObj = await wantAgent.getWantAgent({
        wants: [
          {
            bundleName: this.context.applicationInfo.name,
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      })
    } catch (e) {
      console.error(`${TAG} 创建 wantAgent 失败: ${(e as Error).message}`)
    }
    return this.wantAgentObj
  }
}

/**
 * 看门狗自愈多次失败后发布"VPN 已断开，点击重连"通知（带 wantAgent 点击拉起 EntryAbility 自动重连）。
 * 与常驻通知相互独立：常驻通知只表示 VPN 运行中，此通知只在 VPN 异常断开时出现。
 */
export async function publishReconnectNotice(context: common.Context): Promise<void> {
  try {
    if (!await notificationManager.isNotificationEnabled()) {
      console.warn(`${TAG} 应用通知权限未授予，无法发布重连通知`)
      return
    }
    const text = readVpnNoticePrefs(context).reconnectText || DEFAULT_RECONNECT_TEXT
    const agent = await wantAgent.getWantAgent({
      wants: [
        {
          bundleName: context.applicationInfo.name,
          abilityName: 'EntryAbility',
          parameters: { 'autoReconnect': true }
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    })
    const request: notificationManager.NotificationRequest = {
      id: VPN_RECONNECT_NOTICE_ID,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: 'ClashBox',
          text: text,
          additionalText: ''
        }
      },
      wantAgent: agent,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION
    }
    await notificationManager.publish(request)
    console.info(`${TAG} 重连通知已发布 id=${VPN_RECONNECT_NOTICE_ID}`)
  } catch (e) {
    console.error(`${TAG} 重连通知发布失败: ${(e as Error).message}`)
  }
}
