import { BORDER_RADIUS_20 } from '../../common/entity/Constants'
import TopBuilder from './TopBuilder'
import { AppConfig, ClashCore, UIConfig } from '../../entryability/AppState'
import ClashViewModel from '../../entryability/ClashViewModel'
import { PromptAction } from '@kit.ArkUI'
import { customAnimationUtil } from '../../common/utils/Animation'
import { common } from '@kit.AbilityKit'
import { PageMargin } from '../../common/breakpoint/BreakPoint'
import BuildProfile from 'BuildProfile'
import { resolveCoreMode } from '../../common/services/CoreMode'

interface KernelListItem {
  title: ResourceStr
  subtitle: ResourceStr
  core: ClashCore
}

@Component
struct Kernel {
  @Consume('NavSettingsPathStack') SettingsPageInfos: NavPathStack
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  @StorageLink('currentHeightBreakpoint') heightBp: HeightBreakpoint = 0
  @StorageLink('currentWidthBreakpoint') widthBp: WidthBreakpoint = 1
  @StorageLink('appConfig') appConfig: AppConfig = new AppConfig()
  @Prop developerMode: boolean = false
  @State private switching: boolean = false
  @State private kernel: KernelListItem[] = []

  private promptAction: PromptAction = this.getUIContext().getPromptAction()
  private context = this.getUIContext().getHostContext()! as common.UIAbilityContext

  async handleClick(core: ClashCore): Promise<void> {
    if (this.switching || core === this.appConfig.clashCore) return
    if (core !== resolveCoreMode(core, BuildProfile.DEBUG)) return
    if (core === ClashCore.ClashMeta && !this.developerMode) return
    this.switching = true
    try {
      // Confirm shutdown before changing the saved mode; restart creates the new core.
      await ClashViewModel.StopVpn()
      this.appConfig.clashCore = core
      AppStorage.set('appConfig', this.appConfig)
      this.promptAction.showToast({ message: $r('app.string.restart_tips'), duration: 2000 })
      setTimeout(() => {
        this.context.getApplicationContext().killAllProcesses()
      }, 2000)
    } catch (error) {
      this.switching = false
      this.promptAction.showToast({ message: (error as Error).message })
    }
  }

  aboutToAppear(): void {
    this.kernel = [{ title: 'mihomo', subtitle: $r('app.string.standard_core_description'), core: ClashCore.mihomo }]
    if (BuildProfile.DEBUG && this.developerMode) {
      this.kernel.push({ title: $r('app.string.foreground_core_title'),
        subtitle: $r('app.string.switch_core_foreground_prompt'), core: ClashCore.ClashMeta })
    }
  }

  build() {
    NavDestination() {
      TopBuilder({
        title: BuildProfile.DEBUG && this.developerMode ? $r('app.string.developer_options') : $r('app.string.kernel'),
        pathStack: this.SettingsPageInfos
      })
      Column({ space: 10 }) {
        Column({ space: 8 }) {
          ForEach(this.kernel, (item: KernelListItem, index: number) => {
            Row() {
              Image($rawfile('mihomo.png'))
                .width(48)
                .height(48)
                .borderRadius(15)
              Column() {
                Text(item.title)
                  .fontWeight(FontWeight.Bold)
                  .fontSize(16)
                Text(item.subtitle)
                  .fontSize(14)
                  .margin({ top: 2 })
              }
              .margin({ left: 12, right: 12 })
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Checkbox({ name: 'kernel' + item.core, group: 'core' })
                .selectedColor(this.icon_emphasize)
                .select(item.core === this.appConfig.clashCore)
                .hitTestBehavior(HitTestMode.None)
            }
            .constraintSize({ minHeight: 72 })
            .width('100%')
            .enabled(!this.switching)
            .onClick(() => { this.handleClick(item.core) })
            if (index < this.kernel.length - 1) {
              Divider().color($r('app.color.divider'))
            }
          }, (item: KernelListItem) => item.core.toString())
        }
        .padding(12)
        .width('100%')
        .backgroundColor($r('app.color.container_background'))
        .borderRadius(BORDER_RADIUS_20)
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))

        Text($r('app.string.switch_core_prompt'))
          .fontSize(15)
      }
      .alignItems(HorizontalAlign.Start)
      .padding({ left: PageMargin(this.widthBp, this.heightBp), right: PageMargin(this.widthBp, this.heightBp) })
    }
    .width('100%')
    .height('100%')
    .hideTitleBar(true)
    .backgroundColor($r('app.color.background'))
  }
}
export default Kernel
