import { WorkSchedulerExtensionAbility, workScheduler } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { wantAgent, WantAgent } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { getHome, Profile, SocketProxyService } from 'proxy_core';
import { ProfileRepo } from 'proxy_core/src/main/ets/ProfileRepo';
import { initClash, validateConfig } from 'libflclash.so';
import { findAutoUpdateTargets, isProfileUpdateDue } from '../common/utils/AutoUpdateFilter';

const TAG = 'ConfigUpdateWork'
/** 订阅更新结果通知 ID 段起点（按 profile.id 哈希偏移，避免与常驻通知/重连通知冲突） */
const NOTICE_ID_BASE = 20000
/** 与 UI 侧一致的 UA（ClashViewModel.init 中 AppState.globalUA） */
const DEFAULT_UA = 'clash.meta/1.19.5'

/**
 * 内核校验回退代理：优先走 clash_go.sock RPC（VPN 扩展进程在线时与 UI 路径一致）；
 * 扩展进程被系统回收导致 RPC 不可达时，在本进程加载内核仅做配置校验
 *（initClash 幂等，仅设置 home 目录；validateConfig 为纯解析，不写盘）。
 */
class LocalValidateSocketProxy extends SocketProxyService {
  private localCoreInited = false

  override async vailConfig(filepath: string): Promise<string> {
    try {
      return await super.vailConfig(filepath)
    } catch (e) {
      hilog.warn(0xFF00, TAG, `内核 RPC 校验不可达(${(e as Error).message})，回退到本进程内核校验`)
      if (!this.localCoreInited) {
        initClash(await getHome(this.context), '1.0.0')
        this.localCoreInited = true
      }
      const content = fs.readTextSync(filepath)
      // NAPI validateConfig 接收配置内容字符串（区别于 RPC ValidConfig 接收文件路径）
      return await validateConfig(content)
    }
  }
}

/**
 * 订阅自动更新延迟任务：由 WorkScheduler 按注册的网络/循环间隔约束拉起，
 * 对勾选自动更新且已到期的 URL 订阅逐个执行更新（复用原 ConfigAutoUpdateService 的更新流程）。
 * 进程模型：独立扩展进程，共享应用沙箱（RDB fsclash.db / profiles 目录均可直接访问）。
 */
export default class ConfigUpdateWorkAbility extends WorkSchedulerExtensionAbility {
  private generation: number = 0
  /**
   * 延迟任务触发回调。注意：循环任务（isRepeat=true）在执行完后不要调用 stopWork，
   * 否则本次调度会被停止；系统会在事件循环空闲后回收进程，任务超时时长为 2 分钟。
   */
  onWorkStart(work: workScheduler.WorkInfo): void {
    hilog.info(0xFF00, TAG, `订阅自动更新延迟任务触发 workId=${work.workId}`)
    const generation = ++this.generation
    this.runAutoUpdate(generation).catch((e: Error) => {
      hilog.error(0xFF00, TAG, `订阅自动更新执行失败: ${e.message}`)
    })
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    ++this.generation
    hilog.info(0xFF00, TAG, `订阅自动更新延迟任务停止 workId=${work.workId}`)
  }

  private async runAutoUpdate(generation: number): Promise<void> {
    const repo = new ProfileRepo()
    await repo.init(this.context)
    const profiles = await repo.queryAll()
    const targets = findAutoUpdateTargets(profiles)
    hilog.info(0xFF00, TAG, `共 ${profiles.length} 个配置，其中 ${targets.length} 个勾选自动更新`)
    if (targets.length == 0) {
      return
    }
    const now = Date.now()
    const socketProxy = new LocalValidateSocketProxy()
    socketProxy.init(this.context)
    for (const profile of targets) {
      if (generation !== this.generation) return
      if (!isProfileUpdateDue(profile, now)) {
        hilog.info(0xFF00, TAG, `配置 [${profile.name}] 未到更新间隔，跳过`)
        continue
      }
      try {
        profile.shouldCancelUpdate = () => generation !== this.generation
        profile.loadContext(this.context, DEFAULT_UA)
        await profile.update(socketProxy)
        if (generation !== this.generation) return
        await repo.updateDownloadMetadata(profile)
        hilog.info(0xFF00, TAG, `配置 [${profile.name}] 更新完成`)
        await this.publishResult(profile, null)
      } catch (e) {
        if (generation !== this.generation) return
        const err = e as Error
        hilog.error(0xFF00, TAG, `配置 [${profile.name}] 更新失败: ${err.message}`)
        await this.publishResult(profile, err)
      }
    }
  }

  /** 更新结果通知（成功/失败），与 UI 侧自动更新成功的通知语义一致：点击跳回 EntryAbility */
  private async publishResult(profile: Profile, error: Error | null): Promise<void> {
    try {
      if (!await notificationManager.isNotificationEnabled()) {
        return
      }
      const res = this.context.resourceManager
      const text = error == null
        ? `${res.getStringSync($r('app.string.Configuration').id)} ${profile.name} ${res.getStringSync($r('app.string.update_success').id)}`
        : `${res.getStringSync($r('app.string.Configuration').id)} ${profile.name} ${res.getStringSync($r('app.string.update_failed').id)}: ${error.message}`
      const agent: WantAgent = await wantAgent.getWantAgent({
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
      const request: notificationManager.NotificationRequest = {
        id: ConfigUpdateWorkAbility.noticeIdOf(profile.id),
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
    } catch (e) {
      hilog.error(0xFF00, TAG, `更新结果通知发布失败: ${(e as Error).message}`)
    }
  }

  /** 由 profile.id 派生稳定数字通知 ID（原 UI 侧 Number(uuid)=NaN 的行为不可靠，这里改为稳定哈希） */
  private static noticeIdOf(profileId: string): number {
    let hash = 0
    for (let i = 0; i < profileId.length; i++) {
      hash = (hash * 31 + profileId.charCodeAt(i)) % 50000
    }
    return NOTICE_ID_BASE + hash
  }
}
