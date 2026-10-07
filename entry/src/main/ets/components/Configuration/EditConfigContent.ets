import { UIConfig } from "../../entryability/AppState"
import { BindSheetTitleCustomBuilderMenu, CustomConfirmDialog } from "../Common/Common"
import {
  BIND_SHEET_DRAG_BAR_HEIGHT,
  BIND_SHEET_MAIN_FONTSIZE,
  BIND_SHEET_MAIN_FONT_WEIGHT, BIND_SHEET_SUB_FONTSIZE,
  NewConfigData,} from "../../common/entity/Constants";
import { BindSheetTitleCustomBuilder } from "../Common/Common"
import { WebCodeEditor } from "../Common/CodeEditor";
import { EditorCommunicationManager, WebCodeEditorOptions } from "../../common/entity/WebCodeEditor";
import { webview } from "@kit.ArkWeb";
import { hilog } from "@kit.PerformanceAnalysisKit";
import { ConfigData } from "../../common/entity/PageArgumentEntity";

import ClashViewModel from "../../entryability/ClashViewModel";
import { Xb_ToastUtil } from "xb_components";

@Builder
export function EditConfigContentBuilder(name: string, param: Object){
  EditConfigContent()
}

@Component
struct EditConfigContent {

  /** 是否开启 配置页 `bindSheet` 组件的前景模糊 */
  @Consume('isEnableConfigPageBindSheetForegroundBlur') isEnableConfigPageBindSheetForegroundBlur: boolean
  // 是否显示bindSheet
  @StorageLink('ShowConfigBindSheet') isShowConfigAddBindSheet: boolean = false
  @StorageLink('ConfigContentChange') configContentChange: boolean = false
  /* 主题色 */
  @Consume('icon_emphasize') icon_emphasize: ResourceColor
  @Consume('currentColorMode') currentColorMode: boolean

  @StorageLink('ConfigContent') configStr: string = ''
  private savedContent: string = ''
  @State private saving: boolean = false

  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig()
  // 主页面栈
  @StorageLink('NavPathStack') pageInfos: NavPathStack = new NavPathStack()
  // 当前显示的工具集合 默认为空 待发生编辑事件之后才加入保存按钮菜单
  @State private fileMenus: Array<BindSheetTitleCustomBuilderMenu> = []
  // 当前触摸的配置行
  @StorageLink('currentTouchConfigData') currentTouchConfigData: ConfigData = NewConfigData

  // 高度断点
  @StorageLink ('currentHeightBreakpoint') heightBp: HeightBreakpoint = 0
  // 宽度断点
  @StorageLink ('currentWidthBreakpoint') widthBp: WidthBreakpoint = 1
  // 导航条区域的高度
  @StorageProp('bottomRectHeight') bottomRectHeight: number = 0
  @StorageProp('topRectHeight') topRectHeight: number = 0

  @State webController: webview.WebviewController = new webview.WebviewController();
  // 通信管理器实例
  @State commManager: EditorCommunicationManager = new EditorCommunicationManager(new webview.WebviewController());
  // 编辑器配置选项
  @State editorOptions: WebCodeEditorOptions = {
    // 初始内容
    content: this.configStr,
    wordWrap: this.uiConfig.editWordWrap || true, // 自动换行
    // 编辑器配置
    theme: 'light', // 主题：'dark' | 'light'
    language: 'javascript',  // 语言：'javascript' | 'typescript' | 'css' | 'html' | 'json' | 'python' | 'java'
    fontSize: '14px',
    showMinimap: true,
    // 回调函数
    onContentChange: (content: string) => {
      this.configStr = content;
      this.configContentChange = content !== this.savedContent;
      if (this.configContentChange) {
        if (!this.fileMenus.includes(this.saveMenus)) this.fileMenus.push(this.saveMenus);
      } else {
        this.fileMenus = this.fileMenus.filter((menu) => menu !== this.saveMenus);
      }
      console.info('WebCodeEditor 内容已更新');
    },
    onEditingChange: (isEditing: boolean) => {
      console.info(`WebCodeEditor 编辑状态: ${isEditing}`);
    },
    onSelectionChange: (selection) => {
      // Selection may contain subscription credentials; do not log its content.
    },
    onSave: () => {
      console.info('WebCodeEditor 保存操作触发');
      // 这里其实在网页内没写 (
      // this.saveConfigContent()
    },
    // 就绪回调
    onReady: () => {
      console.info('WebCodeEditor 就绪');
    },
    // 错误回调
    onError: (error: string) => {
      console.error(`WebCodeEditor 错误: ${error}`);
    }
  };

  aboutToAppear(): void {
    // 默认推送自动换行按钮
    this.fileMenus.push(this.moreMenu)
    this.saveMenus.symbolBackgroundColor = this.icon_emphasize
    this.editorOptions.theme = this.currentColorMode ? 'dark' : 'light'
    hilog.info(0x0000, 'WebCodeEditor', `初始要传递的 theme: ${this.editorOptions.theme}`);
    this.savedContent = this.configStr
    this.configContentChange = false
  }

  aboutToDisappear(): void {
    // 清理通信管理器
    // 延迟销毁，等待WebView工作线程处理完最后消息
    setTimeout(() => {
      if (this.commManager) {
        this.commManager.destroy();
      }
    }, 100)
  }

  build() {
    NavDestination() {
      Column() {
        // 标题栏
        BindSheetTitleCustomBuilder({
          pageInfos: this.pageInfos,
          isSubPage: true,
          titlePaddingLeft: BIND_SHEET_DRAG_BAR_HEIGHT / 2,
          mainTitle: $r('app.string.edit_config'),
          subTitle: '',
          mainTitleFontWeight: BIND_SHEET_MAIN_FONT_WEIGHT,
          mainTitleFontSize: BIND_SHEET_MAIN_FONTSIZE,
          subTitleFontSize: BIND_SHEET_SUB_FONTSIZE,
          titleBackgroundColor: $r('app.color.background'),
          padding: {
            // 为什么设置`15`，看Builder的参数中`padding`的介绍：ConfigAddBindSheetTitleBuilderParam
            left: 15,
            top: this.topRectHeight,
            bottom: 5
          },
          back: () => {
            this.isShowConfigAddBindSheet = true
          },
          needSetHeight: false,
          menus: this.fileMenus
        })
        // 编辑器
        WebCodeEditor({
          options: this.editorOptions,
          webController: this.webController,
          commManager: this.commManager, // 传入通信管理器
        })
          .enabled(!this.saving)
          .layoutWeight(1)
          .width('100%')
          .margin(8)
      }
      .clip(true)
      .width('100%')
      .height('100%')
      .padding({ bottom: this.bottomRectHeight })
    }
    .height('100%')
    .hideTitleBar(true)
    .backgroundColor($r('app.color.background'))
    .onBackPressed(() => {
      if (this.saving) return true;
      if (this.configContentChange) {
        // 弹框是否保存已经编辑好的配置
        this.configCustomConfirmDialogController?.open()
        // 更改bindSheet的前景模糊
        this.isEnableConfigPageBindSheetForegroundBlur = true
        return true
      } else {
        this.isShowConfigAddBindSheet = true
        return false
      }
    })
    .onReady( (ctx: NavDestinationContext) => {
      // 接收信息
      try {
        const params: string = ctx?.pathInfo?.param as string
        console.log('ClashBox #EditConfigContent #onReady 编辑配置页接收的params：', params)
      } catch (e) {
        console.log(`ClashBox#ImportConfigFromFile#onReady Navigate onReady catch exception: ${JSON.stringify(e)}`)
      }
    })
    .animation({ duration: this.uiConfig.animationSpeed , curve: Curve.Ease })
  }

  /** Stay on the editor on failure so that the user's text is not lost. */
  async saveConfigContent(): Promise<boolean> {
    if (this.saving) return false;
    this.saving = true;
    try {
      const content = await this.commManager.sendCommand('getContent');
      if (typeof content !== 'string') throw new Error('无法读取编辑内容，请重试');
      this.configStr = content;
      await ClashViewModel.saveProfileContent(this.currentTouchConfigData.configId, content, this.savedContent);
      this.savedContent = content;
      this.configContentChange = this.configStr !== content;
      if (this.configContentChange) return false;
      this.fileMenus = this.fileMenus.filter((menu) => menu !== this.saveMenus);
      return true;
    } catch (error) {
      this.configContentChange = this.configStr !== this.savedContent;
      const message = (error as Error)?.message || String(error);
      Xb_ToastUtil.showToast({ message: `保存失败：${message}`, duration: 3000 });
      return false;
    } finally {
      this.saving = false;
    }
  }

  async saveAndClose(): Promise<void> {
    if (await this.saveConfigContent()) {
      this.pageInfos.pop(true);
      this.isShowConfigAddBindSheet = true;
    }
  }

  // 配置是否保存弹框 Controller定义
  private configCustomConfirmDialogController: CustomDialogController = new CustomDialogController({
    builder: CustomConfirmDialog({
      title: $r('app.string.save_current_configuration'),
      cancelText: $r('app.string.Cancel'),
      confirmText: $r('app.string.Save'),
      cancelButtonBackgroundColor: Color.Transparent,
      cancel: () => {
        this.pageInfos.pop(true)
        this.isShowConfigAddBindSheet = true
      },
      confirm: ()=> {
        // 保存配置
        this.saveAndClose()
      }
    }),
    cancel: () => {
      this.pageInfos.pop(true)
      this.isShowConfigAddBindSheet = true
    },
    alignment: DialogAlignment.Center,
    width: 328,
    backgroundColor: $r('app.color.list_item_background_color'),
  })

  /** 设置自动换行 */
  async setWordWrap(enabled: boolean): Promise<void> {
    try {
      this.editorOptions.wordWrap = enabled;
      await this.commManager.sendCommand('setWordWrap', { enabled: enabled });
      hilog.info(0x0000, 'Edit WebCodeEditor', `Word wrap set to: ${enabled}`);
    } catch (error) {
      const errorMsg: string = `Failed to set word wrap: ${error}`;
      hilog.error(0x0000, 'Edit WebCodeEditor', errorMsg);
      throw new Error(errorMsg);
    }
  }

  // 功能按钮 - 自动换行
  private moreMenu: BindSheetTitleCustomBuilderMenu = {
    symbol: $r('sys.symbol.text_and_t'),
    symbolFontColor: [$r('sys.color.icon_secondary')],
    symbolBackgroundColor: $r('app.color.settings_container_background'),
    action: () => {
      this.uiConfig.editWordWrap = !this.uiConfig.editWordWrap
      this.setWordWrap(this.uiConfig.editWordWrap)
    }
  }

  // 保存按钮
  private saveMenus: BindSheetTitleCustomBuilderMenu = {
    symbol: $r('sys.symbol.save'),
    symbolFontColor: ['#e6ffffff'],
    // 跟随主题色：由于在这里直接赋值 this.icon_emphasize 编译器提示需要初始化 this.icon_emphasize 的值，放到了 aboutToAppear 回调里重新赋值
    symbolBackgroundColor: '#FF0A59F7',
    action: () => {
      this.saveAndClose()
    }
  }

}
