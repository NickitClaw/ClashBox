import { common, Context } from "@kit.AbilityKit";
import { workScheduler } from "@kit.BackgroundTasksKit";
import { BusinessError } from "@kit.BasicServicesKit";
import { hilog } from "@kit.PerformanceAnalysisKit";
import ClashViewModel from "../../entryability/ClashViewModel";
import { Profile } from "proxy_core";
import { convertMillisecondsToTimeGap, DEFAULT_TIMEOUT } from "../entity/Constants";
import { Xb_GetResourceString, Xb_NotificationUtils } from "xb_components";
import { notificationManager } from "@kit.NotificationKit";
import { findAutoUpdateTargets, isProfileUpdateDue } from "./AutoUpdateFilter";

/** 订阅自动更新延迟任务的固定 workId，更新前取消已注册任务。 */
const AUTO_UPDATE_WORK_ID: number = 1001
/**
 * WorkScheduler 循环任务的最小循环间隔：20 分钟。
 * 依据：WorkInfo.repeatCycleTime 官方文档与系统约束（小于 20 分钟按 20 分钟执行）；
 * 且实际执行频率还受应用待机分组限制（活跃分组最小 2 小时、经常使用 4 小时、
 * 常用 24 小时、极少使用 48 小时、受限分组禁止），因此这里的间隔只是"下限请求"。
 */
const MIN_WORK_INTERVAL_MS: number = 20 * 60 * 1000
/** WorkSchedulerExtensionAbility 名称，与 module.json5 extensionAbilities 声明一致 */
const WORK_ABILITY_NAME: string = 'ConfigUpdateWorkAbility'

/**
 * 配置自动更新服务（WorkScheduler 版）
 * 周期性订阅更新已迁移到系统延迟任务（WorkSchedulerExtensionAbility 独立进程执行），
 * 应用退后台/被杀后仍由系统按约束拉起；本类只负责：
 * 1. UI 侧注册/更新/停止延迟任务（应用启动、VPN 启动、订阅增删改时调用）
 * 2. 前台运行时的立即检查（checkNow，含 Toast 与通知）
 */
export class ConfigAutoUpdateService {
  private context: Context | null = null;
  /** 是否正在更新（前台检查防重入） */
  private isUpdating: boolean = false;
  /** 需要自动更新的配置（前台检查用） */
  private autoUpdateProfiles: Profile[] = [];
  private registrationQueue: Promise<void> = Promise.resolve();

  initContext(context: Context): void {
    this.context = context;
    hilog.debug(0xFF00, "ConfigAutoUpdateService", "初始化配置自动更新服务");
  }

  /**
   * 启动配置自动更新服务：立即执行一次前台检查，并按订阅勾选情况注册/停止延迟任务
   */
  async start(): Promise<void> {
    hilog.warn(0xFF00, "ConfigAutoUpdateService", "启动配置自动更新服务");
    // 立即执行一次前台检查（没有需要更新的配置时仅记录日志，不视为失败）
    try {
      await this.checkAndUpdateConfigs();
    } catch (e) {
      hilog.warn(0xFF00, "ConfigAutoUpdateService", `启动时立即检查跳过: ${e}`)
    }
    await this.refreshWorkRegistration();
    hilog.warn(0xFF00, "ConfigAutoUpdateService", "配置自动更新服务启动成功");
  }

  /**
   * 停止配置自动更新服务：取消已注册的延迟任务
   * （仅供内部在"无订阅勾选自动更新"时调用；UI 进程销毁不应停止系统级延迟任务）
   */
  async stop(): Promise<void> {
    hilog.warn(0xFF00, "ConfigAutoUpdateService", "停止配置自动更新服务");
    await this.queueRegistration(() => this.cancelWork());
    hilog.info(0xFF00, "ConfigAutoUpdateService", "配置自动更新服务已停止");
  }

  /**
   * 重置配置自动更新服务：订阅增删改后重新评估注册（无勾选自动更新时停止任务）
   */
  async reset() {
    try {
      await this.refreshWorkRegistration();
    } catch (error) {
      hilog.error(0xFF00, 'ConfigAutoUpdateService',
        `配置自动更新服务重置失败 - ${JSON.stringify(error)}`);
    }
  }

  /**
   * 手动触发检查更新（用于应用切回前台时）
   */
  async checkNow(): Promise<void> {
    hilog.info(0xFF00, "ConfigAutoUpdateService", "手动触发配置更新检查");
    await this.checkAndUpdateConfigs();
  }

  /**
   * 按当前订阅勾选情况注册/更新/停止 WorkScheduler 延迟任务。
   * 约束：NETWORK_TYPE_ANY + 不限充电状态 + 循环间隔取用户配置与系统最小间隔（20 分钟）的较大值。
   */
  private queueRegistration(work: () => Promise<void>): Promise<void> {
    const pending = this.registrationQueue.then(work);
    this.registrationQueue = pending.catch(() => {});
    return pending;
  }

  private refreshWorkRegistration(): Promise<void> {
    return this.queueRegistration(() => this.updateWorkRegistration());
  }

  private async updateWorkRegistration(): Promise<void> {
    const profiles = await ClashViewModel.getProfiles();
    const targets = findAutoUpdateTargets(profiles);
    if (targets.length == 0) {
      hilog.info(0xFF00, "ConfigAutoUpdateService", "没有勾选自动更新的订阅，停止延迟任务");
      await this.cancelWork();
      return;
    }
    // 找出更新频率最快的配置的毫秒值
    const updateIntervalArray: number[] = [];
    for (const profile of targets) {
      // 小于1分钟的重置为默认值并更新一次数据库
      if (profile.autoUpdateDuration < DEFAULT_TIMEOUT) {
        profile.autoUpdateDuration = DEFAULT_TIMEOUT; // 默认1分钟
        await ClashViewModel.updateProfile(profile);
      }
      updateIntervalArray.push(profile.autoUpdateDuration);
    }
    // 循环间隔取用户配置与系统最小间隔（20 分钟）的较大值
    const userInterval: number = Math.min(...updateIntervalArray)
    const repeatCycleTime = Math.max(userInterval, MIN_WORK_INTERVAL_MS)
    const bundleName = this.requireBundleName()
    const workInfo: workScheduler.WorkInfo = {
      workId: AUTO_UPDATE_WORK_ID,
      bundleName: bundleName,
      abilityName: WORK_ABILITY_NAME,
      networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
      isRepeat: true,
      repeatCycleTime: repeatCycleTime,
      isPersisted: true // 重启后恢复任务
    }
    // 使用系统返回的完整条件取消旧任务，不用新条件或缺少条件的 WorkInfo。
    await this.cancelWork();
    try {
      workScheduler.startWork(workInfo);
      hilog.warn(0xFF00, "ConfigAutoUpdateService",
        `订阅自动更新延迟任务已注册：间隔 ${repeatCycleTime / 60000} 分钟（用户配置 ${userInterval / 60000} 分钟）`)
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0xFF00, "ConfigAutoUpdateService",
        `注册订阅自动更新延迟任务失败: code=${err.code}, msg=${err.message}`)
      throw new Error(`注册订阅自动更新任务失败: ${err.code}, ${err.message}`);
    }
  }

  private requireBundleName(): string {
    const bundleName = this.context?.applicationInfo.name;
    if (!bundleName) throw new Error('配置自动更新服务尚未初始化');
    return bundleName;
  }

  private async cancelWork(): Promise<void> {
    const bundleName = this.requireBundleName();
    const works = await workScheduler.obtainAllWorks();
    for (const work of works) {
      if (work.workId === AUTO_UPDATE_WORK_ID && work.bundleName === bundleName &&
        work.abilityName === WORK_ABILITY_NAME) {
        workScheduler.stopWork(work, true);
        hilog.info(0xFF00, "ConfigAutoUpdateService", "订阅自动更新延迟任务已停止");
      }
    }
  }

  /**
   * 前台检查并更新所有需要自动更新的配置（含 Toast 与结果通知；后台周期更新由 WorkSchedulerExtensionAbility 执行）
   */
  private async checkAndUpdateConfigs(): Promise<void> {
    // 防止重复执行
    if (this.isUpdating) {
      hilog.warn(0xFF00, "ConfigAutoUpdateService", "配置更新正在进行中，跳过本次检查");
      return;
    }

    this.isUpdating = true;

    try {
      hilog.warn(0xFF00, "ConfigAutoUpdateService", "开始检查配置更新");

      // 获取所有配置
      const profiles = await ClashViewModel.getProfiles();
      hilog.info(0xFF00, "ConfigAutoUpdateService", `获取到 ${profiles.length} 个配置`);

      // 筛选需要自动更新的配置
      this.autoUpdateProfiles = findAutoUpdateTargets(profiles);

      hilog.info(0xFF00, "ConfigAutoUpdateService",
        `需要自动更新的配置数量: ${this.autoUpdateProfiles.length}`);

      if (this.autoUpdateProfiles.length === 0) {
        return Promise.reject("没有需要自动更新的配置");
      }

      // 当前时间
      const now = Date.now();

      // 检查每个配置是否需要更新
      for (const profile of this.autoUpdateProfiles) {
        try {
          const updateInterval = profile.autoUpdateDuration

          const lastUpdateTime = profile.lastUpdateDate || 0;
          const timeSinceLastUpdate = now - lastUpdateTime;

          // 格式化打印字符串
          let updateIntervalStr = `${updateInterval}毫秒`
          const timeGap = convertMillisecondsToTimeGap(updateInterval)
          switch (timeGap.unit) {
            case 0: // 分钟
              updateIntervalStr = `${timeGap.value}分钟`
              break;
            case 1: // 小时
              updateIntervalStr = `${timeGap.value}小时`
              break;
            case 2: // 天
              updateIntervalStr = `${timeGap.value}天`
              break;
          }

          hilog.info(0xFF00, "ConfigAutoUpdateService",
            `配置 [${profile.name}] - 上次更新: ${new Date(lastUpdateTime).toLocaleString()}, ` +
              `更新间隔: ${updateInterval} - ${updateIntervalStr}, 距离上次更新: ${Math.floor(timeSinceLastUpdate /
                1000 / 60)}分钟`);

          // 判断是否需要更新（含 5 秒误差容忍，与后台任务一致）
          if (isProfileUpdateDue(profile, now)) {
            hilog.info(0xFF00, "ConfigAutoUpdateService",
              `配置 [${profile.name}] 需要更新，开始更新...`);

            // 执行更新
            await ClashViewModel.updateProfileConfig(profile.id);

            // 推送通知消息 - 成功
            if (this.context) {
              await Xb_NotificationUtils.publishTextNotification(
                (this.context as common.UIAbilityContext),
                Number(profile.id),
                {
                  title: "ClashBox",
                  text: `${Xb_GetResourceString($r('app.string.Configuration'),
                    this.context)} ${profile.name} ${Xb_GetResourceString($r('app.string.update_success'),
                    this.context)}`
                },
                notificationManager.SlotType.SERVICE_INFORMATION,
                { abilityName: 'EntryAbility' }
              )
            }

            hilog.info(0xFF00, "ConfigAutoUpdateService",
              `配置 [${profile.name}] 更新完成`);
          } else {
            const remainingTime = Math.floor((updateInterval - timeSinceLastUpdate) / 1000 / 60);
            hilog.info(0xFF00, "ConfigAutoUpdateService",
              `配置 [${profile.name}] 无需更新，还需等待 ${remainingTime} 分钟`);
          }
        } catch (error) {
          hilog.error(0xFF00, "ConfigAutoUpdateService", error);

          // 推送通知消息 - 失败
          if (this.context) {
            await Xb_NotificationUtils.publishTextNotification(
              (this.context as common.UIAbilityContext),
              Number(profile.id),
              {
                title: "ClashBox",
                text: error
              },
              notificationManager.SlotType.SERVICE_INFORMATION,
              { abilityName: 'EntryAbility' }
            )
          }
        }
      }

      hilog.info(0xFF00, "ConfigAutoUpdateService", "配置更新检查完成");
    } catch (error) {
      const err = error as BusinessError;
      hilog.error(0xFF00, "ConfigAutoUpdateService",
        `配置更新检查失败: ${err.message}`);
      return Promise.reject(err.message);
    } finally {
      this.isUpdating = false;
    }
  }
}

export default new ConfigAutoUpdateService();
