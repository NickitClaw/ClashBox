import { Profile, ProfileType } from 'proxy_core'

/**
 * 订阅自动更新的到期筛选逻辑（UI 进程前台检查与 WorkSchedulerExtensionAbility 后台任务共用）。
 * 放在独立模块，避免 WorkScheduler 扩展进程加载 ClashViewModel 等 UI 依赖链。
 */

/** 更新间隔判断的误差容忍（5 秒），沿用原 ConfigAutoUpdateService 逻辑 */
const UPDATE_TOLERANCE_MS: number = 5 * 1000

/** Disabled profiles must be excluded from both foreground and background refresh. */
export function findAutoUpdateTargets(profiles: Profile[]): Profile[] {
  return profiles.filter((profile: Profile) => {
    return profile.autoUpdate && !profile.isUpdating && profile.type === ProfileType.Url
  })
}

/** 距离上次更新是否已到期间隔（含 5 秒误差容忍） */
export function isProfileUpdateDue(profile: Profile, now: number): boolean {
  const updateInterval = profile.autoUpdateDuration
  // 忽略小于等于0的间隔
  if (updateInterval <= 0) {
    return false
  }
  const lastUpdateTime = profile.lastUpdateDate || 0
  return now - lastUpdateTime >= updateInterval - UPDATE_TOLERANCE_MS
}
