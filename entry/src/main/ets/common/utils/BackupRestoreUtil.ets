import { ProfileBackup, backupProfile } from 'proxy_core/src/main/ets/profile/ProfileBackup';
import { ClashConfig, migrateSnifferConfig } from "proxy_core";
import { Xb_FileUtils, Xb_GetResourceString, Xb_PreferenceUtil, Xb_ToastUtil } from "xb_components";
import { AppConfig, UIConfig } from "../../entryability/AppState";
import ClashViewModel from "../../entryability/ClashViewModel";
import { filterStringsByBooleans } from "../entity/Constants";
import { getJsonArrayType } from "../entity/utils";
import BuildProfile from 'BuildProfile';
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
      // Do not publish selection or report success until every profile has been restored.
      await ClashViewModel.addOrUpdateProfiles(config.configList);
      const app = config.appConfig;
      app.clashCore = resolveCoreMode(app.clashCore, BuildProfile.DEBUG);
      if (app.currentProfileId && !await ClashViewModel.getProfile(app.currentProfileId)) {
        app.currentProfileId = '';
        app.currentProfileName = undefined;
        app.currentProxyName = undefined;
      }
      if (getJsonArrayType(config.uiConfig.isShowHomeCard) === 'boolean') {
        config.uiConfig.isShowHomeCard = filterStringsByBooleans(config.uiConfig.isShowHomeCard, 'string') as string;
      }
      await Xb_PreferenceUtil.put('config_sort', config.configSort ?? '[]');
      AppStorage.set('uiConfig', config.uiConfig);
      AppStorage.set('clashConfig', migrateSnifferConfig(config.clashConfig));
      AppStorage.set('appConfig', app);
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
