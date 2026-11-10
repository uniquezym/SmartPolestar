import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, common, WantAgent } from '@kit.AbilityKit';
import { BusinessError, Log } from '../common/Log';

/**
 * 长时任务维持器 —— 对应 Android 端的前台服务 + 常驻通知。
 *
 * Android 端用 START_STICKY 前台服务保证 BLE 扫描与加速度采样不被回收；
 * HarmonyOS 侧改为申请「蓝牙交互」类型长时任务，系统会展示常驻通知，
 * 应用退到后台后仍可持续运行（具体存活时长由系统调度，需真机验证）。
 */
export class BackgroundKeeper {
  /** 是否已启动，避免重复申请。 */
  private static running: boolean = false;

  /**
   * 申请长时任务。
   *
   * @param context UIAbility 上下文
   * @returns 是否申请成功（失败不阻塞主流程）
   */
  static async start(context: common.UIAbilityContext): Promise<boolean> {
    if (BackgroundKeeper.running) {
      return true;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        // 点击常驻通知时回到主页面
        wants: [
          {
            bundleName: context.abilityInfo.bundleName,
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);

      const request = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [
        backgroundTaskManager.BackgroundTaskMode.MODE_BLUETOOTH_INTERACTION
      ];
      request.backgroundTaskSubmodes = [
        backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_CAR_KEY_NORMAL_NOTIFICATION
      ];
      request.wantAgent = agent;

      await backgroundTaskManager.startBackgroundRunning(context, request);
      BackgroundKeeper.running = true;
      Log.info('长时任务已启动: MODE_BLUETOOTH_INTERACTION');
      return true;
    } catch (err) {
      const e = err as BusinessError;
      // 常见失败：未授予 KEEP_BACKGROUND_RUNNING、系统繁忙
      Log.warn(`长时任务申请失败: code=${e.code} ${e.message}`);
      return false;
    }
  }

  /**
   * 结束长时任务。
   */
  static async stop(context: common.UIAbilityContext): Promise<void> {
    if (!BackgroundKeeper.running) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      BackgroundKeeper.running = false;
      Log.info('长时任务已停止');
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`长时任务停止失败: code=${e.code} ${e.message}`);
    }
  }

  /**
   * 长时任务是否处于运行中。
   */
  static isRunning(): boolean {
    return BackgroundKeeper.running;
  }
}
