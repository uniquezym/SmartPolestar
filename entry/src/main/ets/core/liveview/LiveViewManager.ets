import { liveViewManager } from '@kit.LiveViewKit';
import { wantAgent, common, WantAgent } from '@kit.AbilityKit';
import { AirPurifyLiveData, LiveViewData } from './LiveViewData';
import { BusinessError, Log } from '../../common/Log';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'LiveViewManager';

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
   * 实况窗顺序号。
   *
   * 官方示例 start 用 1、update 用 2，同一生命周期内严格递增；
   * 顺序不对会报 1003500011（实况窗顺序不正确）。
   */
  private static sequence: number = 0;

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
        Log.warn(TAG, 'LiveView 能力未开通，实况窗功能不可用');
      }
    } catch (err) {
      const e = err as BusinessError;
      LiveViewManager.enabled = false;
      Log.warn(TAG, `查询 LiveView 能力失败: code=${e.code} ${e.message}`);
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
      const view = await LiveViewManager.buildLiveView(context, data);
      await liveViewManager.startLiveView(view);
      Log.info(TAG, `空气净化实况窗已创建: id=${LiveViewManager.LIVE_VIEW_ID}`);
    } catch (err) {
      const e = err as BusinessError;
      if (e.code === 1003500005) {
        // 权益未开通 —— 华为侧没给本应用开实况窗权限，代码无法绕过
        Log.warn(TAG, '实况窗权益未开通：请在 AppGallery Connect 申请实况窗服务权益，或添加调测设备');
        return;
      }
      Log.warn(TAG, `创建空气净化实况窗失败: code=${e.code} ${e.message}`);
    }
  }

  /**
   * 更新实况窗内容。
   *
   * @param context UIAbility 上下文
   * @param data    要展示的数据
   * @returns 实况窗是否仍然存在
   *          false 表示它已被删除或从未建成，调用方需要重新创建
   */
  static async update(context: common.UIAbilityContext,
    data: AirPurifyLiveData): Promise<boolean> {
    if (!await LiveViewManager.isAvailable()) {
      return false;
    }
    try {
      const view = await LiveViewManager.buildLiveView(context, data);
      await liveViewManager.updateLiveView(view);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      if (e.code === 1003500009) {
        // 实况窗不存在 —— 上一次建窗可能失败或已被删除，需要重新创建
        Log.info(TAG, '空气净化实况窗不存在，将重新创建');
        return false;
      }
      if (e.code === 1003500010) {
        // 已结束 —— 同样需要重建
        return false;
      }
      Log.warn(TAG, `更新空气净化实况窗失败: code=${e.code} ${e.message}`);
      return true;
    }
  }

  /**
   * 销毁实况窗。
   *
   * @param context UIAbility 上下文
   */
  static async stop(context: common.UIAbilityContext): Promise<void> {
    if (!await LiveViewManager.isAvailable()) {
      return;
    }
    try {
      // stopLiveView 只需要 id 与 event，
      // 但接口签名要求完整的 LiveView —— 这里用空数据把其余字段填上。
      // 不推进 sequence —— 结束不是一次「更新」，沿用上次的顺序号即可。
      const view = await LiveViewManager.buildLiveView(context, LiveViewData.EMPTY_DATA, false);
      await liveViewManager.stopLiveView(view);
      Log.info(TAG, `空气净化实况窗已销毁: id=${LiveViewManager.LIVE_VIEW_ID}`);
    } catch (err) {
      const e = err as BusinessError;
      // 1003500009 = 不存在，1003500010 = 已结束 —— 都说明它早没了
      if (e.code !== 1003500009 && e.code !== 1003500010) {
        Log.warn(TAG, `销毁空气净化实况窗失败: code=${e.code} ${e.message}`);
      }
    }
  }

  /**
   * 清理上次残留的实况窗。
   *
   * 应用启动时调用：车端可能早就关了净化（甚至应用被杀掉期间到时停机），
   * 实况窗却还留在状态栏显示「净化中」。这里把它停掉。
   *
   * @param context      UIAbility 上下文
   * @param stillRunning 车端是否仍在净化
   */
  static async reconcile(context: common.UIAbilityContext, stillRunning: boolean): Promise<void> {
    if (!await LiveViewManager.exists()) {
      return;
    }
    if (!stillRunning) {
      await LiveViewManager.stop(context);
      Log.info(TAG, '已清理残留的空气净化实况窗');
    }
  }

  /**
   * 组装实况窗数据。
   *
   * 卡片态分三块：
   *   固定区 —— 标题「空气净化中」+ 内容（AQI / PM2.5 / 剩余时间）
   *   辅助区 —— extensionData，拓展按钮位（停止净化）
   * 胶囊态：
   *   capsule —— 「净化中」+ 剩余分钟数
   *
   * 【primary 的三个必填项】
   * clickAction、extensionData、layoutData 缺一不可，
   * 少了任何一个 startLiveView 都会报 401
   * （The type of primary.xxx must be ...）。
   * 这三项是链式校验 —— 补上前一个才会报出下一个。
   *
   * 【extensionData.clickAction 与 serviceButtons 必须同时给】
   * 官方对 serviceButtons 的说明是：
   * 「更新连续服务按钮时，需要同时更新辅助区 ExtensionData 的 clickAction 字段
   *   和连续服务按钮。」
   * 也就是说辅助区的点击动作由 extensionData.clickAction 承载，
   * serviceButtons 只是这一块的按钮外观 —— 两者必须成对出现。
   *
   * 【sequence】
   * 官方示例 start 用 1、update 用 2，对应错误码 1003500011
   * （实况窗顺序不正确）。创建与更新都递增，结束则沿用上一次的值
   * —— 官方说未携带的可选字段会继承上一次的状态。
   *
   * @param context      UIAbility 上下文
   * @param data         要展示的数据
   * @param bumpSequence 是否推进顺序号（创建/更新为 true，结束为 false）
   */
  private static async buildLiveView(context: common.UIAbilityContext,
    data: AirPurifyLiveData, bumpSequence: boolean = true): Promise<liveViewManager.LiveView> {
    const stopAgent = await LiveViewManager.buildStopAgent(context);
    const primary: liveViewManager.PrimaryData = {
      title: LiveViewData.TITLE,
      content: [
        {
          text: LiveViewData.contentText(data)
        }
      ],
      // 归档时长：实况窗结束后在通知中心保留的分钟数
      keepTime: 0,
      // 卡片主体的默认动作：回到应用看详情
      clickAction: await LiveViewManager.buildOpenAgent(context),
      // 辅助区：拓展按钮位（停止净化）
      // 文字用按钮文案而不是状态词 —— extensionData.clickAction 与
      // serviceButtons 是同一处动作，点辅助区任何位置都是「停止净化」，
      // 写「净化中」会让人以为点状态词只是看详情。
      extensionData: {
        text: LiveViewData.STOP_LABEL,
        type: liveViewManager.ExtensionType.EXTENSION_TYPE_COMMON_TEXT,
        clickAction: stopAgent
      },
      // 扩展区：与辅助区拓展按钮位同一处动作，
      // 官方要求 serviceButtons 与 extensionData.clickAction 同时更新
      layoutData: {
        layoutType: liveViewManager.LayoutType.LAYOUT_TYPE_DEFAULT,
        serviceButtons: [
          {
            name: LiveViewData.STOP_LABEL,
            clickAction: stopAgent
          }
        ],
        isServiceButtonsDisplayed: true
      }
    };
    return {
      id: LiveViewManager.LIVE_VIEW_ID,
      event: LiveViewData.EVENT_NAME,
      sequence: bumpSequence ? LiveViewManager.nextSequence() : LiveViewManager.sequence,
      isMute: true,
      liveViewData: {
        primary: primary,
        capsule: {
          type: liveViewManager.CapsuleType.CAPSULE_TYPE_TEXT,
          status: 1,
          icon: LiveViewData.CAPSULE_ICON,
          title: LiveViewData.RUNNING_LABEL,
          content: LiveViewData.capsuleText(data),
          backgroundColor: LiveViewData.CAPSULE_BACKGROUND
        }
      }
    };
  }

  /**
   * 取下一个 sequence 值。
   *
   * 官方对 sequence 的用法是 start=1、update=2 逐次递增，
   * 顺序不对会报 1003500011。
   */
  private static nextSequence(): number {
    LiveViewManager.sequence += 1;
    return LiveViewManager.sequence;
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

  /**
   * 构造「打开应用」的 WantAgent。
   *
   * 实况窗卡片的默认点击动作 —— 点卡片主体回应用看详情。
   */
  private static async buildOpenAgent(context: common.UIAbilityContext): Promise<WantAgent> {
    const info: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: context.abilityInfo.bundleName,
          abilityName: LiveViewData.ABILITY_NAME
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITIES,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return wantAgent.getWantAgent(info);
  }
}
