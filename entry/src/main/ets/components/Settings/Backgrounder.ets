
import TopBuilder from "./TopBuilder"
import { toggleRowList } from "../Common/Common"
import { UIConfig } from "../../entryability/AppState"
import { PageMargin } from "../../common/breakpoint/BreakPoint"
import { deviceInfo } from '@kit.BasicServicesKit';

@Component
struct Backgrounder {
  // UI控制变量
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  // 后台保持控制变量
  @State @Watch('onBackgroundValueChange') isKeepTask: boolean = false
  @Consume('NavSettingsPathStack') SettingsPageInfos: NavPathStack
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  // 高度断点
  @StorageLink ('currentHeightBreakpoint') heightBp: HeightBreakpoint = 0
  // 宽度断点
  @StorageLink ('currentWidthBreakpoint') widthBp: WidthBreakpoint = 1

  build() {
    NavDestination() {
      TopBuilder({
        title: $r('app.string.Backgrounder'),
        pathStack: this.SettingsPageInfos
      })
      List({space: 10}) {
        // 任务保持
        if (deviceInfo.deviceType === 'tablet' || deviceInfo.deviceType === '2in1') {
          ListItem() {
            Row() {
              toggleRowList({
                icons: $r('sys.symbol.lock_filled_arrow_counterclockwise'),
                title: $r('app.string.keep_task'),
              }) {
                Toggle({ type: ToggleType.Switch, isOn: $$this.isKeepTask })
                  .selectedColor(this.icon_emphasize)
                  .margin({right: 12})
                  .hitTestBehavior(HitTestMode.None)
              }
            }
          }
          .onClick(() => {
            this.isKeepTask = !this.isKeepTask
          })
        }
        // 提示
        ListItem() {
          Text($r('app.string.backgrounder_tips'))
            .fontWeight(FontWeight.Normal)
            .fontSize(15)
        }
      }
      .width('100%')
      .contentEndOffset(72)
      .alignListItem(ListItemAlign.Center)
      .padding({ left: PageMargin(this.widthBp, this.heightBp), right: PageMargin(this.widthBp, this.heightBp) })
    }
    .hideTitleBar(true)
    .backgroundColor($r('app.color.background'))
    .onBackPressed(() => {
      this.SettingsPageInfos.clear();
      return true;
    })
  }

  aboutToAppear(): void {
    // 初始化开关状态
    this.isKeepTask = this.uiConfig.backgroundKeepTask
  }

  aboutToDisappear(): void {
    this.onBackgroundValueChange()
  }

  onBackgroundValueChange() {
    // 持久化开关状态
    this.uiConfig.backgroundKeepTask = this.isKeepTask
    // 改变后台运行全局变量的状态
    this.uiConfig.Enablebackgrounder = this.isKeepTask
  }
}
export default Backgrounder
