import fs from '@ohos.file.fs';
import { Context } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { getProfilePath, getProfilesPath } from '../appPath';

export type ConfigValidator = (path: string) => Promise<string>;

export interface ProfileCommitOptions {
  backup?: string;
  clearBackup?: boolean;
}

export function generateUUID(): string {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = Math.random() * 16 | 0;
    return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
  });
}

/** Also accepts document URIs; handles short reads without leaking the descriptor. */
export async function readProfileText(path: string): Promise<string> {
  const file = await fs.open(path, fs.OpenMode.READ_ONLY);
  try {
    const stat = await fs.stat(file.fd);
    const bytes = new Uint8Array(stat.size);
    let offset = 0;
    while (offset < bytes.length) {
      const chunk = new ArrayBuffer(Math.min(bytes.length - offset, 65536));
      const count = await fs.read(file.fd, chunk);
      if (count <= 0) throw new Error('配置文件读取不完整');
      bytes.set(new Uint8Array(chunk, 0, count), offset);
      offset += count;
    }
    return util.TextDecoder.create('utf-8', { ignoreBOM: true }).decodeToString(bytes);
  } finally {
    await fs.close(file.fd);
  }
}

/** Writes a private staging file; callers choose when it becomes visible. */
export async function writeProfileText(path: string, content: string): Promise<void> {
  const bytes = new util.TextEncoder().encodeInto(content);
  const buffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer;
  const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
  try {
    let offset = 0;
    while (offset < buffer.byteLength) {
      const count = await fs.write(file.fd, buffer.slice(offset));
      if (count <= 0) throw new Error('配置文件写入失败');
      offset += count;
    }
    await fs.fsync(file.fd);
  } finally {
    await fs.close(file.fd);
  }
}

/** Only valid inside ProfileStorage.transaction; never acquire the same lock recursively. */
export class ProfileTransaction {
  private active: boolean = true;
  private backupPath: string;
  private path: string;
  private cancelled?: () => boolean;

  constructor(path: string, cancelled?: () => boolean) {
    this.path = path;
    this.cancelled = cancelled;
    this.backupPath = path.replace(/config\.yaml$/, 'config_script_backup.yaml');
  }

  finish(): void { this.active = false; }

  check(): void {
    if (!this.active) throw new Error('配置事务已结束');
    if (this.cancelled?.()) throw new Error('配置操作已取消');
  }

  async read(): Promise<string | undefined> {
    this.check();
    return await fs.access(this.path) ? await readProfileText(this.path) : undefined;
  }

  async readBackup(): Promise<string | undefined> {
    this.check();
    return await fs.access(this.backupPath) ? await readProfileText(this.backupPath) : undefined;
  }

  /** Validate the exact sibling file that is renamed into place; backup only after validation. */
  async commit(content: string, validate: ConfigValidator, options: ProfileCommitOptions = {}): Promise<void> {
    this.check();
    const temp = `${this.path}.${generateUUID()}.tmp`;
    let createdBackup = false;
    let retiredBackup: string | undefined;
    let committed = false;
    try {
      await writeProfileText(temp, content);
      const message = await validate(temp);
      if (message !== '') throw new Error(message);
      this.check();
      // Remove an obsolete script baseline as part of this commit. If the config rename
      // fails, restore it; cleanup after a successful rename cannot turn success into failure.
      if (options.clearBackup && await fs.access(this.backupPath)) {
        const retired = `${this.backupPath}.${generateUUID()}.tmp`;
        await fs.rename(this.backupPath, retired);
        retiredBackup = retired;
      }
      if (options.backup !== undefined && !await fs.access(this.backupPath)) {
        const backupTemp = `${this.backupPath}.${generateUUID()}.tmp`;
        try {
          await writeProfileText(backupTemp, options.backup);
          this.check();
          await fs.rename(backupTemp, this.backupPath);
          createdBackup = true;
        } finally {
          try { await fs.unlink(backupTemp); } catch (_) {}
        }
      }
      this.check();
      await fs.rename(temp, this.path);
      committed = true;
    } catch (e) {
      if (createdBackup) {
        try { await fs.unlink(this.backupPath); } catch (_) {}
      }
      if (retiredBackup !== undefined) await fs.rename(retiredBackup, this.backupPath);
      throw e as Error;
    } finally {
      try { await fs.unlink(temp); } catch (_) {}
      if (committed && retiredBackup !== undefined) {
        try { await fs.unlink(retiredBackup); } catch (_) {}
      }
    }
  }

  async clearBackup(): Promise<void> {
    // Cleanup of a completed commit must not be cancelled halfway through.
    if (!this.active) throw new Error('配置事务已结束');
    if (await fs.access(this.backupPath)) await fs.unlink(this.backupPath);
  }

  async delete(): Promise<void> {
    this.check();
    if (await fs.access(this.path)) await fs.unlink(this.path);
    await this.clearBackup();
  }

  /** Restore previously read bytes, including a script backup without a config file. */
  async restore(content: string | undefined, backup: string | undefined): Promise<void> {
    if (content !== undefined) {
      await this.commit(content, async () => '', { clearBackup: true, backup: backup });
      return;
    }
    await this.delete();
    if (backup !== undefined) {
      const temp = `${this.backupPath}.${generateUUID()}.tmp`;
      try {
        await writeProfileText(temp, backup);
        await fs.rename(temp, this.backupPath);
      } finally { try { await fs.unlink(temp); } catch (_) {} }
    }
  }
}

export class ProfileStorage {
  private context: Context | undefined;
  private id: string;
  private cancelled?: () => boolean;

  constructor(context: Context | undefined, id: string, cancelled?: () => boolean) {
    this.context = context;
    this.id = id;
    this.cancelled = cancelled;
  }

  async transaction<T>(operation: (files: ProfileTransaction) => Promise<T>): Promise<T> {
    if (!this.context) throw new Error('配置存储尚未初始化');
    const directory = await getProfilesPath(this.context);
    // Keep the inode: unlinking a lock file permits two simultaneous owners.
    const lock = await fs.open(`${directory}/${this.id}.lock`, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
    let acquired = false;
    let files: ProfileTransaction | undefined;
    try {
      const deadline = Date.now() + 60000;
      while (!acquired) {
        if (this.cancelled?.()) throw new Error('配置操作已取消');
        try {
          lock.tryLock(true);
          acquired = true;
        } catch (e) {
          if ((e as BusinessError).code !== 13900034) throw e as Error;
          if (Date.now() >= deadline) throw new Error('配置正在被另一个任务修改，请稍后重试');
          await new Promise<void>((resolve) => { setTimeout(resolve, 50); });
        }
      }
      files = new ProfileTransaction(await getProfilePath(this.context, this.id), this.cancelled);
      files.check();
      return await operation(files);
    } finally {
      files?.finish();
      try { if (acquired) lock.unlock(); } finally { await fs.close(lock.fd); }
    }
  }
}
