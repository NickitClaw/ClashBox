import { Profile, ProfileType } from '../Profile';
import { SubscriptionInfo } from '../models/Common';

/** Plain JSON metadata. Map/Context instances must never be serialized as backup records. */
export interface ProfileBackup {
  id: string;
  type: ProfileType;
  url: string;
  name?: string | null;
  currentGroupName?: string | null;
  isUpdating?: boolean;
  autoUpdate?: boolean;
  autoUpdateDuration?: number;
  lastUpdateDate?: number;
  subscriptionInfo?: SubscriptionInfo | null;
  proxySelected?: Record<string, string>;
  customUA?: string;
  flag?: string;
  overrideMode?: 'rule' | 'script';
  customRules?: string[];
}

export function backupProfile(profile: Profile): ProfileBackup {
  return { id: profile.id, type: profile.type, url: profile.url, name: profile.name,
    currentGroupName: profile.currentGroupName, isUpdating: profile.isUpdating,
    autoUpdate: profile.autoUpdate, autoUpdateDuration: profile.autoUpdateDuration,
    lastUpdateDate: profile.lastUpdateDate, subscriptionInfo: profile.subscriptionInfo,
    proxySelected: profile.getSelectedMap(), customUA: profile.customUA, flag: profile.flag,
    overrideMode: profile.overrideMode, customRules: profile.customRules.map((rule: string) => rule) };
}

export function restoreProfileMetadata(data: ProfileBackup): Profile {
  // IDs become filesystem paths. Preserve valid legacy IDs, never accept path components.
  if (typeof data.id !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$/.test(data.id)) {
    throw new Error('备份包含无效的配置 ID');
  }
  if (![ProfileType.Url, ProfileType.File, ProfileType.External].includes(data.type)) {
    throw new Error('备份包含无效的配置类型');
  }
  const profile = new Profile(data.type, data.url);
  profile.id = data.id;
  profile.name = data.name ?? null;
  profile.currentGroupName = data.currentGroupName ?? null;
  profile.isUpdating = data.isUpdating ?? false;
  profile.autoUpdate = data.autoUpdate ?? true;
  profile.autoUpdateDuration = data.autoUpdateDuration ?? profile.autoUpdateDuration;
  profile.lastUpdateDate = data.lastUpdateDate ?? profile.lastUpdateDate;
  profile.subscriptionInfo = data.subscriptionInfo ?? null;
  profile.customUA = data.customUA ?? '';
  profile.flag = data.flag ?? '';
  profile.overrideMode = data.overrideMode === 'script' ? 'script' : 'rule';
  profile.customRules = (data.customRules ?? []).map((rule: string) => rule);
  const selected = data.proxySelected ?? {};
  Object.keys(selected).forEach((group: string) => {
    if (typeof selected[group] !== 'string') throw new Error('备份包含无效的节点选择');
    profile.proxySelected.set(group, selected[group]);
  });
  return profile;
}
