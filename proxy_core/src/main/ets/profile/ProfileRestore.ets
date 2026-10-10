import { Context } from '@kit.AbilityKit';
import { Profile } from '../Profile';
import { ProfileStorage, ProfileTransaction, generateUUID } from './ProfileStorage';

interface PreparedProfile {
  profile: Profile;
  content: string;
}
interface PreviousFiles {
  files: ProfileTransaction;
  content?: string;
  backup?: string;
}

/** Stage everything before touching existing IDs; hold target locks until DB commit or rollback. */
export async function restoreProfilesAtomically(context: Context | undefined, profiles: Profile[],
  prepare: (profile: Profile) => Promise<void>,
  persist: (profiles: Profile[], replaceFiles: () => Promise<void>) => Promise<void>): Promise<void> {
  const prepared: PreparedProfile[] = [];
  for (const profile of profiles) {
    const id = profile.id;
    profile.id = `restore_${generateUUID()}`;
    try {
      await prepare(profile);
      const content = await new ProfileStorage(context, profile.id).transaction((files) => files.read());
      if (!content) throw new Error('配置文件不存在，恢复失败');
      prepared.push({ profile: profile, content: content });
    } finally {
      try { await profile.delete(); } finally { profile.id = id; }
    }
  }
  prepared.sort((a: PreparedProfile, b: PreparedProfile) => a.profile.id.localeCompare(b.profile.id));
  const locked: ProfileTransaction[] = [];
  const acquire = async (index: number): Promise<void> => {
    if (index < prepared.length) {
      await new ProfileStorage(context, prepared[index].profile.id).transaction(async (files) => {
        locked.push(files);
        try { await acquire(index + 1); } finally { locked.pop(); }
      });
      return;
    }
    const previous: PreviousFiles[] = [];
    for (const files of locked) previous.push({ files: files, content: await files.read(), backup: await files.readBackup() });
    let changed = 0;
    try {
      await persist(profiles, async () => {
        for (let i = 0; i < prepared.length; i++) {
          // Exactly the already validated bytes, protected by all destination locks.
          await locked[i].commit(prepared[i].content, async () => '', { clearBackup: true });
          changed++;
        }
      });
    } catch (e) {
      let rollbackFailed = false;
      for (let i = changed - 1; i >= 0; i--) {
        const old = previous[i];
        try {
          await old.files.restore(old.content, old.backup);
        } catch (_) { rollbackFailed = true; }
      }
      if (rollbackFailed) throw new Error('恢复失败且部分文件回滚失败，请保留原备份并重新恢复');
      throw e as Error;
    }
  };
  await acquire(0);
}
