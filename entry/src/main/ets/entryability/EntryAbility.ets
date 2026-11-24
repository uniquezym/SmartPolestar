import { AbilityConstant, common, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError, commonEventManager } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { BackgroundKeeper } from '../service/BackgroundKeeper';
import { BackgroundReset } from '../core/app/BackgroundReset';
import { LiveViewData } from '../core/liveview/LiveViewData';
import { PurifyCommand } from '../core/liveview/PurifyCommand';
import { Log } from '../common/Log';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
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
    hilog.info(Log.DOMAIN, TAG, 'Ability onCreate');
    this.subscribePurifyStop();
    this.requestNotificationPermission();
  }

  /**
   * 申请通知权限。
   *
   * 卡片车控的结果会用通知提示（同时也写在卡片上）。
   * 通知权限没开时发布通知会报 1600004，通知栏提示这条路就断了 ——
   * 这里主动申请一次，用户拒绝也不影响卡片上的结果展示。
   */
  private requestNotificationPermission(): void {
    try {
      notificationManager.requestEnableNotification(this.context as common.UIAbilityContext)
        .then(() => {
          hilog.info(Log.DOMAIN, TAG, '通知权限已开启');
        })
        .catch((err: BusinessError) => {
          hilog.info(Log.DOMAIN, TAG, '通知权限未开启，结果仅显示在卡片上');
        });
    } catch (err) {
      hilog.info(Log.DOMAIN, TAG, '申请通知权限异常，结果仅显示在卡片上');
    }
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

    // 卡片车控走 message 事件在提供方进程内直接执行，不拉起本应用 ——
    // 所以这里永远只需要加载概览页。
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(Log.DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(Log.DOMAIN, TAG, 'Succeeded in loading the content.');
    });
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
