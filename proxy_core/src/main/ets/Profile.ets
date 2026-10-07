import fs from '@ohos.file.fs';
import { Context } from '@kit.AbilityKit';
import { getProfilePath, getProfilesPath } from './appPath';
import { ProxyGroup, ProxyType, SubscriptionInfo } from './models/Common';
import { SocketProxyService } from './rpc/SocketProxyService';
import { YamlUtils } from './utils/YamlUtils';
import { ProfileStorage, ProfileTransaction, ConfigValidator, generateUUID, readProfileText } from './profile/ProfileStorage';
import { ProfileTransformer, ProfileTransformOptions } from './profile/ProfileTransformer';
import { ProfileDownloader } from './profile/ProfileDownloader';

export { generateUUID } from './profile/ProfileStorage';

export enum ProfileType {
  File,
  Url,
  External
}

export class Profile {
  id: string
  name: string | null
  type: ProfileType
  url: string = ""
  flag: string = ""
  customUA: string = ""
  overrideMode?: 'rule' | 'script' = 'rule'
  // 自定义附加规则（每个配置独立）
  customRules: string[] = []
  currentGroupName: string | null = null
  isUpdating: boolean = false
  autoUpdate: boolean = true
  lastUpdateDate: number
  autoUpdateDuration: number
  subscriptionInfo: SubscriptionInfo | null
  proxySelected: Map<string, string> = new Map()
  context?: Context
  // 是否自动修正 TLS 指纹（补全/替换为支持后量子曲线 ML-KEM 的新版 chrome），默认开启
  fixTlsFingerprint: boolean = true
  // YAML 覆写片段(entry 层注入, 所有配置生成路径统一应用深度合并)
  yamlOverride: string = ''
  shouldCancelUpdate?: () => boolean

  constructor(type = ProfileType.Url, url: string) {
    this.id = generateUUID()
    this.name = null
    this.type = type // 0 url
    this.url = url
    this.autoUpdateDuration = 60 * 1000 // 1 分钟
    this.lastUpdateDate = new Date().getTime()
    this.subscriptionInfo = null
  }

  private globalUa: string = "clash-verge/v2.5.1"

  loadContext(context: Context | undefined, globalUa: string | undefined = "clash-verge/v2.5.1") {
    this.context = context
    this.globalUa = globalUa
  }

  private storage(): ProfileStorage {
    return new ProfileStorage(this.context, this.id, () => this.shouldCancelUpdate?.() === true);
  }

  private transformOptions(customRules: string[], deleteRules: string[], script: string = ''): ProfileTransformOptions {
    return { name: this.name ?? '', customRules: customRules.map((r) => r), deleteRules: deleteRules.map((r) => r),
      script: script, fixTlsFingerprint: this.fixTlsFingerprint, yamlOverride: this.yamlOverride };
  }

  async checkAndUpdate(socketProxy: SocketProxyService, customRules: string[] = [], deleteRules: string[] = []): Promise<void> {
    if (!await this.check() && this.url !== '') await this.update(socketProxy, customRules, deleteRules);
  }

  async check(): Promise<boolean> {
    return await fs.access(await getProfilePath(this.context, this.id));
  }

  async delete(): Promise<void> {
    await this.storage().transaction(async (files) => {
      await files.delete();
      await this.cleanEmptyDirUnlocked();
    });
  }

  async update(socketProxy: SocketProxyService, customRules: string[] = [], deleteRules: string[] = []): Promise<boolean> {
    const options = this.transformOptions(customRules, deleteRules);
    const url = this.url;
    const ua = this.globalUa;
    return this.storage().transaction(async (files) => {
      const downloader = new ProfileDownloader(this.context!, socketProxy, () => this.shouldCancelUpdate?.() === true);
      const downloaded = await downloader.download(url, ua);
      const name = downloaded.name || this.name || ProfileDownloader.defaultName(url) || this.id;
      const subscription = downloaded.userinfo ? SubscriptionInfo.formHString(downloaded.userinfo) : this.subscriptionInfo;
      options.name = name;
      await this.prepareAndCommit(files, downloaded.content, (path: string): Promise<string> => socketProxy.vailConfig(path), options);
      // Only publish metadata after the corresponding bytes have passed validation and committed.
      this.name = name;
      this.subscriptionInfo = subscription;
      this.lastUpdateDate = Date.now();
      return true;
    });
  }

  private async prepareAndCommit(files: ProfileTransaction, raw: string | ArrayBuffer,
    validate: ConfigValidator, options: ProfileTransformOptions): Promise<void> {
    const content = await ProfileTransformer.prepare(raw, options);
    await files.commit(content, validate, { clearBackup: true });
  }

  async save(raw: string | ArrayBuffer, validate: ConfigValidator, customRules: string[] = [],
    deleteRules: string[] = [], scriptContent: string = ''): Promise<Profile> {
    const options = this.transformOptions(customRules, deleteRules, scriptContent);
    await this.storage().transaction((files) => this.prepareAndCommit(files, raw, validate, options));
    this.lastUpdateDate = Date.now();
    return this;
  }

  async saveByUri(uri: string, validate: ConfigValidator, customRules: string[] = [],
    deleteRules: string[] = [], scriptContent: string = ''): Promise<Profile> {
    const options = this.transformOptions(customRules, deleteRules, scriptContent);
    await this.storage().transaction(async (files) => {
      await this.prepareAndCommit(files, await readProfileText(uri), validate, options);
    });
    this.lastUpdateDate = Date.now();
    return this;
  }

  /** The editor modifies the effective YAML: preserve its text instead of reapplying rules/scripts. */
  async saveEditedContent(content: string, validate: ConfigValidator, expectedContent: string): Promise<void> {
    await this.storage().transaction(async (files) => {
      const current = await files.read();
      if (current === undefined) throw new Error('配置已被删除，请返回配置列表');
      if (current !== expectedContent) throw new Error('配置已被其他任务更新，请重新打开后编辑');
      await files.commit(content, validate, { clearBackup: true });
    });
  }

  getSelectedProxyName(g: ProxyGroup): string | undefined {
    if (g.type !== ProxyType.Selector) return g.now
    let dd = this.proxySelected.get(g.name) ?? g.now
    return dd
  }

  getSelectedMap(): Record<string, string> {
    const jsonObject: Record<string, string> = {};
    this.proxySelected.forEach((value, key) => {
      jsonObject[key] = value;
    });
    return jsonObject
  }

  async getMatchTarget(): Promise<string> {
    try {
      return YamlUtils.extractMatchTarget(await readProfileText(await getProfilePath(this.context, this.id)));
    } catch (_) {
      return 'DIRECT';
    }
  }

  /** All read/modify/write operations hold the same lock from reading through validation and rename. */
  async repairMissingRules(validate: ConfigValidator, customRules: string[] = [], deleteRules: string[] = []): Promise<boolean> {
    const options = this.transformOptions(customRules, deleteRules);
    return this.storage().transaction(async (files) => {
      const current = await files.read();
      if (current === undefined || !ProfileTransformer.needsRuleRepair(current, options.customRules, options.deleteRules)) return false;
      const content = await ProfileTransformer.prepare(current, options);
      if (content === current) return false;
      await files.commit(content, validate);
      return true;
    });
  }

  async forceRewriteRules(validate: ConfigValidator, customRules: string[] = [], deleteRules: string[] = []): Promise<boolean> {
    const options = this.transformOptions(customRules, deleteRules);
    return this.storage().transaction(async (files) => {
      const current = await files.read();
      if (current === undefined) return false;
      const content = await ProfileTransformer.prepare(current, options);
      if (content === current) return false;
      await files.commit(content, validate);
      return true;
    });
  }

  async ensureProvidersLazy(validate: ConfigValidator): Promise<boolean> {
    return this.storage().transaction(async (files) => {
      const current = await files.read();
      if (current === undefined) return false;
      const content = ProfileTransformer.providersLazy(current);
      if (content === current) return false;
      await files.commit(content, validate);
      return true;
    });
  }

  async reapplyScript(validate: ConfigValidator, scriptContent: string = '', customRules: string[] = [],
    deleteRules: string[] = [], yamlOverride: string = ''): Promise<boolean> {
    const options = this.transformOptions(customRules, deleteRules, scriptContent);
    options.yamlOverride = yamlOverride;
    return this.storage().transaction(async (files) => {
      const current = await files.read();
      if (current === undefined) return false;
      // Repeated application starts from the first backup, avoiding accumulated script effects.
      const original = await files.readBackup() ?? current;
      const content = await ProfileTransformer.prepare(original, options);
      if (content !== current) await files.commit(content, validate, { backup: original });
      this.yamlOverride = yamlOverride;
      return true;
    });
  }

  async restoreScriptBackup(validate: ConfigValidator, customRules: string[] = [], deleteRules: string[] = []): Promise<boolean> {
    const options = this.transformOptions(customRules, deleteRules);
    return this.storage().transaction(async (files) => {
      const backup = await files.readBackup();
      if (backup === undefined) return false;
      await this.prepareAndCommit(files, backup, validate, options);
      return true;
    });
  }

  async cleanScriptBackup(): Promise<void> {
    await this.storage().transaction((files) => files.clearBackup());
  }

  async cleanEmptyDir(): Promise<void> {
    await this.storage().transaction(() => this.cleanEmptyDirUnlocked());
  }

  private async cleanEmptyDirUnlocked(): Promise<void> {
    try {
      const baseDir = await getProfilesPath(this.context);
      const profileDir = `${baseDir}/${this.id}`;
      console.debug(`Profile.cleanEmptyDir profileDir: ${profileDir}`);

      // 目录本身不存在就不处理
      if (!(await fs.access(profileDir))) {
        return;
      }
      // 列目录内容（非递归），只要不为空就不删
      const files = await fs.listFile(profileDir); // 不带 options 即非递归
      if (files.length === 0) {
        await fs.rmdir(profileDir);
        console.debug(`Profile.cleanEmptyDir 已清理空文件夹: ${profileDir}`);
      } else {
        console.debug(`Profile.cleanEmptyDir 目录非空，跳过清理: ${profileDir}`);
      }
    } catch (e) {
      // 发生任何异常都不影响主流程
      console.warn(`Profile.cleanEmptyDir 异常，放弃清理: ${JSON.stringify(e)}`);
    }
  }

}
