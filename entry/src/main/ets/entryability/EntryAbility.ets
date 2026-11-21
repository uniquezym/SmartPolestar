import { AbilityConstant, common, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router, window } from '@kit.ArkUI';
import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';
import { BackgroundKeeper } from '../service/BackgroundKeeper';
import { BackgroundReset } from '../core/app/BackgroundReset';
import { CardIntent } from '../core/vehicle/CardIntent';
import { LiveViewData } from '../core/liveview/LiveViewData';
import { PurifyCommand } from '../core/liveview/PurifyCommand';
import { Log } from '../common/Log';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  /**
   * 卡片跳转带来的控制项。
   *
   * 非空表示本次启动是桌面卡片触发的车控请求（router 事件），
   * 需要把首页换成车控确认页。
   */
  private cardControl: string = '';

  /** 窗口舞台引用，热启动推页时需要。 */
  private windowStage: window.WindowStage | undefined = undefined;

  /** 实况窗「停止净化」事件的订阅句柄。 */
  private purifySubscriber: commonEventManager.CommonEventSubscriber | undefined = undefined;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(Log.DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    this.cardControl = EntryAbility.cardControlOf(want);
    if (this.cardControl.length > 0) {
      // 控制项通过进程内通道传给确认页 —— loadContent 没有路由 params 重载
      CardIntent.set(this.cardControl);
    }
    hilog.info(Log.DOMAIN, TAG, 'Ability onCreate');
    this.subscribePurifyStop();
  }

  /**
   * 订阅实况窗「停止净化」事件。
   *
   * 实况窗上的按钮用 WantAgent 发这个公共事件，
   * 应用进程收到后静默执行关闭 —— 不拉起任何界面。
   */
  private subscribePurifyStop(): void {
    if (this.purifySubscriber !== undefined) {
      return;
    }
    try {
      const info: commonEventManager.CommonEventSubscribeInfo = {
        events: [LiveViewData.STOP_EVENT],
        publisherBundleName: this.context.abilityInfo.bundleName
      };
      const subscriber = commonEventManager.createSubscriberSync(info);
      commonEventManager.subscribeToEvent(subscriber, (data: commonEventManager.CommonEventData) => {
        hilog.info(Log.DOMAIN, TAG, '收到实况窗停止净化事件');
        PurifyCommand.stop(this.context as common.UIAbilityContext).catch((err: Error) => {
          hilog.error(Log.DOMAIN, TAG, '停止净化失败. Cause: %{public}s', err.message);
        });
      }).catch((err: BusinessError) => {
        hilog.error(Log.DOMAIN, TAG, '订阅停止净化事件失败. Cause: %{public}s', err.message);
      });
      this.purifySubscriber = subscriber;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(Log.DOMAIN, TAG, '订阅停止净化事件异常. Cause: %{public}s', e.message);
    }
  }

  onDestroy(): void {
    hilog.info(Log.DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
    BackgroundKeeper.stop(this.context);
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(Log.DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');
    this.windowStage = windowStage;

    // 卡片触发的车控请求直接进确认页；正常启动进概览页
    const page = this.cardControl.length > 0 ? 'pages/CardControl' : 'pages/Index';

    windowStage.loadContent(page, (err: BusinessError) => {
      if (err.code) {
        hilog.error(Log.DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(Log.DOMAIN, TAG, 'Succeeded in loading the content.');
    });
  }

  /**
   * 应用已在后台运行时收到卡片的 router 事件。
   */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    const control = EntryAbility.cardControlOf(want);
    if (control.length === 0) {
      return;
    }
    this.cardControl = control;
    hilog.info(Log.DOMAIN, TAG, 'Ability onNewWant, card control: %{public}s', control);
    CardIntent.set(control);
    this.pushControlPage();
  }

  /**
   * 把车控确认页压入路由栈。
   *
   * 概览页保留在栈底，用户处理完车控可以返回。
   */
  private pushControlPage(): void {
    const stage = this.windowStage;
    if (stage === undefined) {
      return;
    }
    try {
      const options: router.RouterOptions = { url: 'pages/CardControl' };
      stage.getMainWindowSync().getUIContext().getRouter().pushUrl(options);
    } catch (err) {
      hilog.error(Log.DOMAIN, TAG, 'Failed to push control page. Cause: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 从 Want 中解析卡片传来的控制项。
   *
   * postCardAction 的 params 会被序列化到 want.parameters.params（JSON 字符串）。
   *
   * @param want 启动或热启动的 Want
   * @returns 控制项（lock / climate）；不是卡片请求时返回空串
   */
  private static cardControlOf(want: Want): string {
    const raw = want?.parameters?.params;
    if (raw === undefined || raw === null) {
      return '';
    }
    try {
      const params = JSON.parse(raw as string) as Record<string, Object>;
      const control = params['control'] as string;
      return (control === 'lock' || control === 'climate') ? control : '';
    } catch (err) {
      hilog.error(Log.DOMAIN, TAG, 'Failed to parse card params. Cause: %{public}s', JSON.stringify(err));
      return '';
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(Log.DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(Log.DOMAIN, TAG, 'Ability onForeground');
    // 申请长时任务：保证退到后台后 BLE 扫描与传感器采样不被回收
    BackgroundKeeper.start(this.context);
    // 这里只打日志，不做路由跳转 —— onForeground 时 UI 还没恢复前台，
    // router 指令会被丢弃。实际跳转让页面自己的 onPageShow 来做。
    BackgroundReset.onForeground();
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(Log.DOMAIN, TAG, 'Ability onBackground');
    // 记下进入后台时停在哪个页面 —— 只有那个页面恢复时才需要 back 回概览页。
    BackgroundReset.onBackground(this.currentPageName());
  }

  /**
   * 当前栈顶页面的名字。
   *
   * 取不到时返回空串 —— 此时不做页面级判断。
   */
  private currentPageName(): string {
    const stage = this.windowStage;
    if (stage === undefined) {
      return '';
    }
    try {
      return stage.getMainWindowSync().getUIContext().getRouter().getState().name;
    } catch (err) {
      return '';
    }
  }
}
