import { liveViewManager } from '@kit.LiveViewKit';
import { wantAgent, common, WantAgent } from '@kit.AbilityKit';
import { AirPurifyLiveData, LiveViewData } from './LiveViewData';
import { BusinessError, Log } from '../../common/Log';

/**
 * 空气净化实况窗管理器。
 *
 * 负责实况窗的创建、更新与销毁。
 *
 * 【实况窗 ID 是自己生成的】
 * LiveView 的 id 由开发者自行决定，不是系统分配的。
 * 这里用固定值 —— 同一业务永远用同一个 id，
 * 好处是进程被杀重开后仍能用 id 找回（或清掉）那个实况窗。
 */
export class LiveViewManager {
  /** 空气净化实况窗的固定 ID。 */
  static readonly LIVE_VIEW_ID: number = 1001;

  /** 是否已确认本应用有权创建实况窗。 */
  private static enabled: boolean | undefined = undefined;

  /**
   * 实况窗是否可用。
   *
   * LiveView 能力需要华为侧开通，未开通时 isLiveViewEnabled 返回 false ——
   * 这时功能整体不可用，但绝不能影响主流程。
   */
  static async isAvailable(): Promise<boolean> {
    if (LiveViewManager.enabled !== undefined) {
      return LiveViewManager.enabled;
    }
    try {
      const result = await liveViewManager.isLiveViewEnabled();
      LiveViewManager.enabled = result;
      if (!result) {
        Log.warn('LiveView 能力未开通，实况窗功能不可用');
      }
    } catch (err) {
      const e = err as BusinessError;
      LiveViewManager.enabled = false;
      Log.warn(`查询 LiveView 能力失败: code=${e.code} ${e.message}`);
    }
    return LiveViewManager.enabled;
  }

  /**
   * 当前是否存在实况窗。
   */
  static async exists(): Promise<boolean> {
    if (!await LiveViewManager.isAvailable()) {
      return false;
    }
    try {
      await liveViewManager.getActiveLiveView(LiveViewManager.LIVE_VIEW_ID);
      return true;
    } catch (err) {
      // 1003500009 = 不存在 —— 这是正常情况，不是错误
      return false;
    }
  }

  /**
   * 创建实况窗。
   *
   * 同一 id 同一时刻只能有一个实况窗，重复创建会报 1003500006（已存在），
   * 所以先无条件停一次再重建。
   *
   * @param context UIAbility 上下文
   * @param data    要展示的数据
   */
  static async start(context: common.UIAbilityContext, data: AirPurifyLiveData): Promise<void> {
    if (!await LiveViewManager.isAvailable()) {
      return;
    }

    // 已经有实况窗了就直接更新内容 ——
    // 同一 id 只能有一个实况窗，重复 start 会报「已存在」，
    // 先停再重建则会让实况窗在状态栏闪一下。
    if (await LiveViewManager.exists()) {
      await LiveViewManager.update(context, data);
      return;
    }

    try {
      const agent = await LiveViewManager.buildStopAgent(context);
      await liveViewManager.startLiveView(
        LiveViewManager.buildLiveView(data, agent));
      Log.info(`空气净化实况窗已创建: id=${LiveViewManager.LIVE_VIEW_ID}`);
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`创建空气净化实况窗失败: code=${e.code} ${e.message}`);
    }
  }

  /**
   * 更新实况窗内容。
   *
   * 没有实况窗时直接返回 —— 更新是尽力而为的，
   * 拿不到就等下一次状态变化再试。
   *
   * @param context UIAbility 上下文
   * @param data    要展示的数据
   */
  static async update(context: common.UIAbilityContext, data: AirPurifyLiveData): Promise<void> {
    if (!await LiveViewManager.isAvailable()) {
      return;
    }
    try {
      const agent = await LiveViewManager.buildStopAgent(context);
      await liveViewManager.updateLiveView(
        LiveViewManager.buildLiveView(data, agent));
    } catch (err) {
      const e = err as BusinessError;
      if (e.code !== 1003500009 && e.code !== 1003500010) {
        Log.warn(`更新空气净化实况窗失败: code=${e.code} ${e.message}`);
      }
    }
  }

  /**
   * 销毁实况窗。
   */
  static async stop(): Promise<void> {
    if (!await LiveViewManager.isAvailable()) {
      return;
    }
    try {
      // stopLiveView 只需要 id 与 event，
      // 但接口签名要求完整的 LiveView —— 这里用空数据把其余字段填上。
      // 点击动作对停止没有意义，可以不带。
      await liveViewManager.stopLiveView(
        LiveViewManager.buildLiveView(LiveViewData.EMPTY_DATA));
      Log.info(`空气净化实况窗已销毁: id=${LiveViewManager.LIVE_VIEW_ID}`);
    } catch (err) {
      const e = err as BusinessError;
      // 1003500009 = 不存在，1003500010 = 已结束 —— 都说明它早没了
      if (e.code !== 1003500009 && e.code !== 1003500010) {
        Log.warn(`销毁空气净化实况窗失败: code=${e.code} ${e.message}`);
      }
    }
  }

  /**
   * 清理上次残留的实况窗。
   *
   * 应用启动时调用：车端可能早就关了净化（甚至应用被杀掉期间到时停机），
   * 实况窗却还留在状态栏显示「净化中」。这里把它停掉。
   *
   * @param stillRunning 车端是否仍在净化
   */
  static async reconcile(stillRunning: boolean): Promise<void> {
    if (!await LiveViewManager.exists()) {
      return;
    }
    if (!stillRunning) {
      await LiveViewManager.stop();
      Log.info('已清理残留的空气净化实况窗');
    }
  }

  /**
   * 组装实况窗数据。
   *
   * 卡片态分三块：
   *   固定区   —— 标题「空气净化」+ 内容（AQI / PM2.5 / 剩余时间）
   *   辅助区   —— extensionData，「运行中」状态词
   *   扩展区   —— layoutData.serviceButtons，「停止净化」服务按钮
   * 胶囊态：
   *   capsule —— 「净化中」+ 剩余分钟数
   *
   * 【卡片主体不挂点击动作】
   * 实况窗要自闭环 —— 展开卡片就能看到全部信息，不该把用户拽进应用。
   * 只有「停止净化」按钮有动作。
   */
  private static buildLiveView(data: AirPurifyLiveData,
    agent?: WantAgent): liveViewManager.LiveView {
    const primary: liveViewManager.PrimaryData = {
      title: LiveViewData.TITLE,
      content: [
        {
          text: LiveViewData.contentText(data)
        }
      ],
      // 归档时长：实况窗结束后在通知中心保留的分钟数
      keepTime: 0,
      // 辅助区：状态词
      extensionData: {
        text: LiveViewData.RUNNING_LABEL,
        type: liveViewManager.ExtensionType.EXTENSION_TYPE_COMMON_TEXT
      }
    };
    if (agent !== undefined) {
      // 扩展区：唯一带动作的地方 —— 「停止净化」
      primary.layoutData = {
        layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_DEFAULT,
        serviceButtons: [
          {
            name: LiveViewData.STOP_LABEL,
            clickAction: agent
          }
        ],
        isServiceButtonsDisplayed: true
      };
    }
    return {
      id: LiveViewManager.LIVE_VIEW_ID,
      event: LiveViewData.EVENT_NAME,
      isMute: true,
      liveViewData: {
        primary: primary,
        capsule: {
          type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
          status: 1,
          title: LiveViewData.RUNNING_LABEL,
          content: LiveViewData.capsuleText(data)
        }
      }
    };
  }

  /**
   * 构造「停止净化」的 WantAgent。
   *
   * 用 SEND_COMMON_EVENT 而不是 START_ABILITY ——
   * 前者只在应用进程内投递事件，不拉起任何界面，
   * 用户点按钮时不会被打断到确认页。
   */
  private static async buildStopAgent(context: common.UIAbilityContext): Promise<WantAgent> {
    const info: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.abilityInfo.bundleName,
          action: LiveViewData.STOP_EVENT,
          parameters: {}
        }
      ],
      actionType: wantAgent.OperationType.SEND_COMMON_EVENT,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return wantAgent.getWantAgent(info);
  }
}
