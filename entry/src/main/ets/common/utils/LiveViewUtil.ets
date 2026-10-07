
import { liveViewManager } from '@kit.LiveViewKit';
import { Want, wantAgent } from '@kit.AbilityKit';
import { Xb_GetResourceString } from 'xb_components';
import { AppConfig } from '../../entryability/AppState';
import { BusinessError } from '@kit.BasicServicesKit';

class LiveViewUtil {

  private static context: Context;
  /** 实况窗刷新定时器（与实况窗 ID 分离；原实现共用 liveID，停止/失败路径极易泄漏定时器） */
  private liveTimerId: number = 0
  /** 实况窗 ID（start/update/stop 三段必须一致，固定值即可，单例只维护一个实况窗） */
  private liveViewId: number = 1

  public async init(context: Context): Promise<boolean> {
    LiveViewUtil.context = context
    return true
  }

  /** context 兜底：正常由 Index 页面 aboutToAppear 时 init() 注入；未注入时抛出明确错误 */
  private static safeContext(): Context {
    if (!LiveViewUtil.context) {
      throw new Error('LiveViewUtil context 未初始化（init 未被调用）')
    }
    return LiveViewUtil.context
  }

  /** 先清旧定时器：任何路径（启动失败/重复启动/停止/系统接口异常）都不允许定时器累积 */
  private clearTimer(): void {
    if (this.liveTimerId != 0) {
      clearInterval(this.liveTimerId)
      this.liveTimerId = 0
    }
  }

  public async startLiveView(): Promise<liveViewManager.LiveViewResult> {
    // 重复启动时先清理可能残留的旧定时器
    this.clearTimer()
    // 校验实况窗开关是否打开
    if (!await LiveViewUtil.isLiveViewEnabled()) {
      throw new Error("LiveViewUtil Live view is disabled.");
    }
    // 创建实况窗（成功后才启动刷新定时器，失败路径不产生孤儿定时器）
    const defaultView = await this.buildDefaultView();
    try {
      const result = await liveViewManager.startLiveView(defaultView);
      this.liveTimerId = setInterval(async () => {
        try {
          await this.updateLiveView()
        } catch (e) {
          console.error(`LiveViewUtil 实况窗刷新失败: ${(e as Error).message}`)
        }
      }, 1000)
      return result
    } catch (error) {
      throw new Error(error);
    }
  }

  private async updateLiveView(): Promise<liveViewManager.LiveViewResult> {
    // 校验实况窗开关是否打开
    if (!await LiveViewUtil.isLiveViewEnabled()) {
      throw new Error("LiveViewUtil Live view is disabled.");
    }
    const appConfig: AppConfig = AppStorage.get<AppConfig>("appConfig") ?? new AppConfig()
    const themeColor = AppStorage.get<string>("ThemeColor") ?? "#E61E4377"
    const proxyStartingDuration = AppStorage.get<string>('proxyStartingDuration') ?? '0:0:0'
    // 实况窗内容
    const defaultView = await this.buildDefaultView();
    defaultView.liveViewData.primary.title = appConfig.currentProxyName;
    // 实况窗
    defaultView.liveViewData.primary.content = [
      { text: Xb_GetResourceString($r('app.string.px_sec_screen_use_time'), LiveViewUtil.safeContext()) },
      { text: `: ${proxyStartingDuration}`, textColor: themeColor }, // 运行时间
    ];
    defaultView.liveViewData.primary.layoutData = {
      layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PROGRESS,
      progress: 0,
      lineType: 0,
    };
    // 实况胶囊
    defaultView.liveViewData.capsule = {
      type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
      status: 1,
      icon: 'foreground_box_cat_large.png', // 实况胶囊的图标，取值为“/resources/rawfile”路径下的文件名或image.PixelMap
      backgroundColor: themeColor,
      title: proxyStartingDuration
    };
    // 更新实况窗
    return await liveViewManager.updateLiveView(defaultView);
  }

  public async stopLiveView(): Promise<liveViewManager.LiveViewResult> {
    // 先清定时器：即使后续系统接口抛错（如实况窗被系统关闭），定时器也不残留
    this.clearTimer()
    // 校验实况窗开关是否打开
    if (!await LiveViewUtil.isLiveViewEnabled()) {
      throw new Error("LiveViewUtil Live view is disabled.");
    }
    // 实况窗内容
    const defaultView = await this.buildDefaultView();
    defaultView.liveViewData.primary.content = [
      { text: 'ClashBox' },
    ];
    // 结束实况窗
    try {
      return await liveViewManager.stopLiveView(defaultView);
    } catch (error) {
      throw new Error(error);
    }
  }

  private async buildDefaultView(): Promise<liveViewManager.LiveView> {
    const appConfig: AppConfig = AppStorage.get<AppConfig>("appConfig") ?? new AppConfig()
    const themeColor = AppStorage.get<string>("ThemeColor") ?? "#E61E4377"
    const proxyStartingDuration = AppStorage.get<string>('proxyStartingDuration') ?? '0:0:0'
    return {
      // 构造实况窗请求体
      id: this.liveViewId, // 实况窗ID，开发者生成
      event: "QUEUE", // 实况窗的应用场景。QUEUE：排队
      timer: {
        time: 620000,
        isCountdown: false,
        isPaused: false
      },
      liveViewData: {
        primary: {
          title: appConfig.currentProxyName,  // 节点名
          content: [
            { text: Xb_GetResourceString($r('app.string.px_sec_screen_use_time'), LiveViewUtil.safeContext()) },
            { text: `${proxyStartingDuration}`, textColor: themeColor }, // 运行时间
          ], // 设置textColor字段时，所有拥有textColor字段的对象仅能设置同一种颜色，不设置textColor时，默认展示#FF000000
          keepTime: 15,
          clickAction: await LiveViewUtil.buildWantAgent(),
          layoutData: {
            layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_PROGRESS,
            progress: 0,
            color: "#FFFF0000",
            backgroundColor: "#FF000000",
            indicatorType: liveViewManager.IndicatorType.INDICATOR_TYPE_OVERLAY,
            indicatorIcon: "indicator.png", // 进度条指示器图标，取值为“/resources/rawfile”路径下的文件名或image.PixelMap
            lineType: liveViewManager.LineType.LINE_TYPE_DOTTED_LINE,
            nodeIcons: ["icon_1.png","icon_2.png"] // 进度条节点图标集合，每个元素取值为“/resources/rawfile”路径下的文件名或image.PixelMap
          }
        }
      }
    };
  }

  private static async isLiveViewEnabled(): Promise<boolean> {
    return await liveViewManager.isLiveViewEnabled();
  }

  private static async buildWantAgent(): Promise<Want> {
    const wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: LiveViewUtil.safeContext().applicationInfo.name, // 应用实际bundleName
          abilityName: 'EntryAbility'
        } as Want
      ],
      actionType: wantAgent.OperationType.START_ABILITIES,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    const agent = await wantAgent.getWantAgent(wantAgentInfo);
    return agent;
  }

}

export default new LiveViewUtil()