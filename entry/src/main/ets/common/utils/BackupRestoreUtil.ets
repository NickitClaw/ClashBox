import { ProfileBackup, backupProfile } from 'proxy_core/src/main/ets/profile/ProfileBackup';
import { ClashConfig, migrateSnifferConfig } from "proxy_core";
import { Xb_FileUtils, Xb_GetResourceString, Xb_PreferenceUtil, Xb_ToastUtil } from "xb_components";
import { AppConfig, UIConfig } from "../../entryability/AppState";
import ClashViewModel from "../../entryability/ClashViewModel";
import { filterStringsByBooleans } from "../entity/Constants";
import { getJsonArrayType } from "../entity/utils";
import BuildProfile from 'BuildProfile';
import { cardManager } from './CardManageUtil';
import { resolveCoreMode } from '../services/CoreMode';


export interface BackupConfig {
  appConfig: AppConfig
  uiConfig: UIConfig
  configSort: string
  clashConfig: ClashConfig
  configList: ProfileBackup[]
}

class BackupRestoreUtil {

  private static context: Context

  public init(context: Context) {
    BackupRestoreUtil.context = context
  }

  public async backup(): Promise<string> {
    try {
      const appConfig: AppConfig = AppStorage.get<AppConfig>("appConfig") ?? new AppConfig()
      const uiConfig: UIConfig = AppStorage.get<UIConfig>("uiConfig") ?? new UIConfig()
      const configSort: string = await Xb_PreferenceUtil.get('config_sort', '')
      const clashConfig: ClashConfig = AppStorage.get<ClashConfig>("clashConfig") ?? new ClashConfig()
      const configList = (await ClashViewModel.getProfiles()).map(backupProfile)
      const backupConfig: BackupConfig = {
        appConfig: appConfig,
        uiConfig: uiConfig,
        configSort: configSort,
        clashConfig: clashConfig,
        configList: configList
      }
      const file_path = await Xb_FileUtils.exportDataByFile<BackupConfig>('ClashBoxConfig', backupConfig, BackupRestoreUtil.context, false)
      console.log(`ClashBoxConfig.backup 配置文件导出成功 备份文件的缓存路径为：${file_path}`)
      return file_path
    } catch (err) {
      Xb_ToastUtil.showToast({ message: $r('app.string.export_failed') })
      console.error(`ClashBoxConfig.backup 配置文件导出失败 code: ${err.code} message: ${err.message}`)
      return ''
    }
  }

  public async restore(config: BackupConfig | null = null): Promise<boolean> {
    try {
      if (config === null) {
        const uri = await Xb_FileUtils.openFile(BackupRestoreUtil.context);
        if (!uri) return false;
        config = await Xb_FileUtils.importDataByFile<BackupConfig>(uri);
      }
      if (!config || !Array.isArray(config.configList)) throw new Error('备份配置解析失败');
      if (!config.appConfig || !config.uiConfig || !config.clashConfig) throw new Error('备份缺少应用设置');
      config = JSON.parse(JSON.stringify(config)) as BackupConfig;
      const restoredClash = migrateSnifferConfig(config.clashConfig);
      config.appConfig.clashCore = resolveCoreMode(config.appConfig.clashCore, BuildProfile.DEBUG);
      if (getJsonArrayType(config.uiConfig.isShowHomeCard) === 'boolean') {
        config.uiConfig.isShowHomeCard = filterStringsByBooleans(config.uiConfig.isShowHomeCard, 'string') as string;
      }
      const app = config.appConfig;
      if (app.currentProfileId && !config.configList.some((p: ProfileBackup) => p.id === app.currentProfileId) &&
        !await ClashViewModel.getProfile(app.currentProfileId)) {
        app.currentProfileId = '';
        app.currentProfileName = undefined;
        app.currentProxyName = undefined;
      }
      const restored = config;
      let oldApp: AppConfig;
      let oldUi: UIConfig;
      let oldClash: ClashConfig;
      let oldSort: string;
      let oldCardApp: AppConfig;
      let oldCardClash: ClashConfig;
      let captured = false;
      await ClashViewModel.addOrUpdateProfiles(config.configList, async () => {
        oldApp = AppStorage.get<AppConfig>('appConfig') ?? new AppConfig();
        oldUi = AppStorage.get<UIConfig>('uiConfig') ?? new UIConfig();
        oldClash = AppStorage.get<ClashConfig>('clashConfig') ?? new ClashConfig();
        oldCardApp = cardManager.getAppConfig() ?? oldApp;
        oldCardClash = cardManager.getClashConfig() ?? oldClash;
        oldSort = await Xb_PreferenceUtil.get('config_sort', '[]');
        captured = true;
        await Xb_PreferenceUtil.put('config_sort', restored.configSort ?? '[]');
        cardManager.setAppConfig(app);
        cardManager.setClashConfig(restoredClash);
        if (!AppStorage.set('uiConfig', restored.uiConfig) || !AppStorage.set('clashConfig', restoredClash) ||
          !AppStorage.set('appConfig', app)) throw new Error('应用设置写入失败');
      }, async () => {
        if (!captured) return;
        // Try every compensation even if persistent storage remains unavailable.
        let failed = false;
        try { await Xb_PreferenceUtil.put('config_sort', oldSort); } catch (_) { failed = true; }
        try { cardManager.setAppConfig(oldCardApp); } catch (_) { failed = true; }
        try { cardManager.setClashConfig(oldCardClash); } catch (_) { failed = true; }
        if (!AppStorage.set('uiConfig', oldUi)) failed = true;
        if (!AppStorage.set('clashConfig', oldClash)) failed = true;
        if (!AppStorage.set('appConfig', oldApp)) failed = true;
        if (failed) throw new Error('恢复失败且部分设置回滚失败，请保留原备份并重新恢复');
      });
      Xb_ToastUtil.showToast({ message: $r('app.string.import_success') });
      setTimeout(() => { Xb_ToastUtil.restartApp(); }, 2000);
      return true;
    } catch (err) {
      Xb_ToastUtil.showToast({ message: `配置恢复失败：${(err as Error).message}` });
      return false;
    }
  }
}

export default new BackupRestoreUtil()
