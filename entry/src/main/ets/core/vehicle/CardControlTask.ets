import { common } from '@kit.AbilityKit';
import { VehicleRepository } from './VehicleRepository';
import { ControlCoordinator } from './ControlCoordinator';
import { VehicleCommands } from '../net/VehicleCommands';
import { GrpcClient } from '../net/grpc/GrpcClient';
import { CardPublisher } from './CardPublisher';
import { WidgetStore, WidgetSnapshot } from './WidgetStore';
import { CardNotifier } from './CardNotifier';
import { BusinessError, Log } from '../../common/Log';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'CardControlTask';

/**
 * 桌面卡片车控的直接执行链路。
 *
 * 【交互】
 *   卡片按钮 → postCardAction 的 message 事件 → 本类执行 → 回写卡片 + 通知栏提示。
 *   全程不拉起任何界面 —— 用户点完卡片就停在桌面。
 *
 * 【为什么不走指纹与二次确认】
 *   卡片进程（FormExtensionAbility）弹不出指纹框，也承载不了确认弹窗；
 *   而且进程生命周期只有约 10 秒，做不了「验证 → 下发 → 轮询确认」这条链路。
 *   因此卡片上的操作是「点一下直接执行」。
 *
 * 【时间预算】
 *   FormExtensionAbility 回调窗口约 10 秒，这里的链路必须在这之内跑完：
 *     读快照（Preferences）→ 读会话（Preferences + HUKS）→ 读状态（1 次 gRPC）
 *     → 下发指令（1 次 gRPC）→ 回写卡片 → 通知栏提示
 *   所以刻意做了这些取舍：
 *     - 不拉车辆列表（VIN 直接取快照里缓存的）
 *     - gRPC 主机名走本地缓存，省掉一次服务发现往返
 *     - 确认轮询最多 4 秒，超时就以「指令已发送」收尾
 */
export class CardControlTask {
  /** 车锁控制项。 */
  static readonly CONTROL_LOCK: string = 'lock';

  /** 驻车空调控制项。 */
  static readonly CONTROL_CLIMATE: string = 'climate';

  /** 确认轮询的最长等待时长（毫秒）。 */
  private static readonly CONFIRM_BUDGET_MS: number = 3000;

  /** 轮询间隔（毫秒）。 */
  private static readonly POLL_INTERVAL_MS: number = 400;

  /** 是否正在执行，防止连点造成重复下发。 */
  private static running: boolean = false;

  /**
   * 执行一次卡片车控。
   *
   * @param context 卡片提供方的上下文
   * @param formId  触发本次操作的卡片 ID
   * @param message 卡片传来的事件载荷（控制项）
   */
  static async run(context: common.Context, formId: string, message: string): Promise<void> {
    if (CardControlTask.running) {
      Log.info(TAG, '已有车控在执行中，忽略本次点击');
      return;
    }
    CardControlTask.running = true;
    try {
      await CardControlTask.execute(context, formId, message);
    } catch (err) {
      const e = err as BusinessError;
      Log.error(TAG, `卡片车控异常 code=${e.code} ${e.message}`);
      await CardNotifier.publish('车辆操作失败', e.message.length > 0 ? e.message : '请稍后重试');
    } finally {
      CardControlTask.running = false;
    }
  }

  /**
   * 从事件载荷里解析控制项。
   *
   * message 事件的载荷有几种可能的形态：
   *   - 直接就是控制项本身（'lock' / 'climate'）
   *   - params 整体序列化的 JSON（'{"control":"lock"}'）
   *   - params 里 value 字段的字符串
   * 三种都认，认不出就当无效事件。
   *
   * @param message 事件载荷
   * @returns 控制项；无法识别时返回空串
   */
  static parseControl(message: string): string {
    if (message.length === 0) {
      return '';
    }
    if (message === CardControlTask.CONTROL_LOCK || message === CardControlTask.CONTROL_CLIMATE) {
      return message;
    }
    try {
      const parsed = JSON.parse(message) as Record<string, Object>;
      const control = (parsed?.['control'] ?? parsed?.['value']) as string;
      if (control === CardControlTask.CONTROL_LOCK || control === CardControlTask.CONTROL_CLIMATE) {
        return control;
      }
    } catch (err) {
      Log.warn(TAG, `卡片事件载荷无法解析: ${message}`);
    }
    return '';
  }

  /**
   * 车控流程本体。
   */
  private static async execute(context: common.Context, formId: string, message: string): Promise<void> {
    const control = CardControlTask.parseControl(message);
    if (control.length === 0) {
      Log.warn(TAG, `卡片事件无法识别: ${message}`);
      return;
    }

    // 1. 读快照 —— VIN 与上一次的状态都从这里拿，避免额外的网络往返
    const snapshot = await WidgetStore.load(context);
    if (snapshot === undefined) {
      await CardControlTask.report(context, formId, undefined, '操作失败', '请先打开应用同步车辆状态');
      return;
    }

    // 2. 会话
    const repository = new VehicleRepository(context);
    try {
      await repository.loadSession();
    } catch (err) {
      const e = err as BusinessError;
      const text = e.code === 401 ? '请先打开应用登录后再使用卡片控制' : '登录状态已失效';
      await CardControlTask.report(context, formId, snapshot, '操作失败', text);
      return;
    }

    // 3. VIN —— 优先用快照里缓存的，缺失时才去拉车辆列表
    let vin: string = snapshot.vin;
    if (vin.length === 0) {
      try {
        const vins = await repository.fetchVehicles();
        vin = vins.length > 0 ? vins[0] : '';
      } catch (err) {
        vin = '';
      }
    }
    if (vin.length === 0) {
      await CardControlTask.report(context, formId, snapshot, '操作失败', '账号下没有发现车辆');
      return;
    }

    // 4. 读当前状态 —— 决定是锁还是解锁 / 开启还是关闭
    const current = await CardControlTask.readCurrentState(repository, control, vin, snapshot);
    if (current.length === 0) {
      await CardControlTask.report(context, formId, snapshot, '操作失败', '车辆状态不可用，请先打开应用同步车辆');
      return;
    }

    // 5. 下发指令
    const action = CardControlTask.actionOf(control, current);
    const session = repository.getSession();
    // 上一步的状态读取失败时会退回快照里的旧状态，
    // 那时还没建过 gRPC 通道 —— 这里显式准备一次。
    let client: GrpcClient | undefined = undefined;
    try {
      client = await repository.prepare();
    } catch (err) {
      const e = err as BusinessError;
      await CardControlTask.report(context, formId, snapshot, '操作失败',
        e.message.length > 0 ? e.message : '网络不可用，请稍后重试');
      return;
    }
    if (session === undefined || client === undefined) {
      await CardControlTask.report(context, formId, snapshot, '操作失败', '会话未就绪，请重试');
      return;
    }

    let sent: boolean = false;
    let failure: string = '';
    try {
      const coordinator = new ControlCoordinator(context, session, client);
      await coordinator.execute(vin, action, (success: boolean, message: string) => {
        sent = success;
        if (!success) {
          failure = message;
        }
      });
    } catch (err) {
      const e = err as BusinessError;
      failure = e.message.length > 0 ? e.message : '车控执行异常';
    }

    if (!sent) {
      Log.warn(TAG, `卡片车控下发失败: ${failure}`);
      await CardControlTask.report(context, formId, snapshot, '操作失败',
        failure.length > 0 ? failure : '指令下发失败');
      return;
    }

    const target = CardControlTask.targetStateOf(control, action);
    const label = CardControlTask.controlLabel(control);

    // 6. 立刻给反馈 + 回写卡片。
    // 卡片进程只有约 10 秒窗口，所以不等车端确认就先告诉用户「已发送」。
    const updated = CardControlTask.applyTarget(snapshot, control, target, '处理中…', true);
    await WidgetStore.save(context, updated);
    await CardPublisher.pushTo(formId, updated);

    // 7. 轮询确认 —— 车端可能还没推进到终态。
    const confirmed = await CardControlTask.confirm(repository, control, vin, target);
    const resultText = confirmed ? `${label}已${target}` : `${label}指令已发送`;
    const final = CardControlTask.applyTarget(snapshot, control, target, resultText, true);
    await WidgetStore.save(context, final);
    await CardPublisher.pushTo(formId, final);
    await CardNotifier.publish(resultText, resultText);
    Log.info(TAG, `卡片车控完成: ${control} ${action} → ${target}（${confirmed ? '已确认' : '已下发'}）`);
  }

  /**
   * 把操作结果显示到卡片上，并同步发一条通知。
   *
   * 卡片进程弹不了 Toast，操作结果**必须**落在卡片自己身上 ——
   * 通知只是补充，通知开关被关掉时卡片上的结果依然可见。
   *
   * @param context  上下文
   * @param formId   卡片 ID
   * @param snapshot 状态快照；为空表示连快照都没有
   * @param title    结果标题
   * @param text     结果正文
   */
  private static async report(context: common.Context, formId: string,
    snapshot: WidgetSnapshot | undefined, title: string, text: string): Promise<void> {
    if (snapshot !== undefined) {
      const marked = CardControlTask.applyTarget(snapshot, '', '', text, true);
      await WidgetStore.save(context, marked);
      await CardPublisher.pushTo(formId, marked);
    }
    await CardNotifier.publish(title, text);
  }

  /**
   * 控制项的中文名。
   */
  private static controlLabel(control: string): string {
    return control === CardControlTask.CONTROL_LOCK ? '车锁' : '驻车空调';
  }

  /**
   * 读取控制项的当前状态。
   *
   * 优先读车端实时状态；读不到时退回快照里缓存的上一次状态 ——
   * 那份数据可能过时，但方向总比直接失败强。
   *
   * @returns 状态文案；无法确定时返回空串
   */
  private static async readCurrentState(repository: VehicleRepository, control: string,
    vin: string, snapshot: WidgetSnapshot): Promise<string> {
    try {
      if (control === CardControlTask.CONTROL_LOCK) {
        const state = await repository.readDomain('exterior', vin);
        if (state.locked === '未锁' || state.locked === '已锁') {
          return state.locked;
        }
      } else {
        const state = await repository.readDomain('climate', vin);
        if (state.climate === '开启' || state.climate === '关闭') {
          return state.climate;
        }
      }
    } catch (err) {
      Log.warn(TAG, `卡片读取车辆状态失败: ${(err as Error).message}`);
    }

    if (control === CardControlTask.CONTROL_LOCK) {
      if (snapshot.locked === '未锁' || snapshot.locked === '已锁') {
        return snapshot.locked;
      }
      return '';
    }
    if (snapshot.climate === '开启' || snapshot.climate === '关闭') {
      return snapshot.climate;
    }
    return '';
  }

  /**
   * 按当前状态决定动作。
   *
   * 卡片上显示的是**当前状态**，点一下就是切换到相反状态。
   */
  private static actionOf(control: string, current: string): string {
    if (control === CardControlTask.CONTROL_LOCK) {
      return current === '未锁' ? VehicleCommands.ACTION_LOCK : VehicleCommands.ACTION_UNLOCK;
    }
    return current === '开启'
      ? VehicleCommands.ACTION_CLIMATE_STOP
      : VehicleCommands.ACTION_CLIMATE_START;
  }

  /**
   * 动作对应的目标状态。
   */
  private static targetStateOf(control: string, action: string): string {
    if (control === CardControlTask.CONTROL_LOCK) {
      return action === VehicleCommands.ACTION_LOCK ? '已锁' : '未锁';
    }
    return action === VehicleCommands.ACTION_CLIMATE_START ? '开启' : '关闭';
  }

  /**
   * 写回快照：更新控制项状态，并带上操作结果文案。
   *
   * @param snapshot  原始快照
   * @param control   控制项；空串表示只更新结果文案，不改状态
   * @param target    目标状态
   * @param opText    操作结果文案
   * @param opVisible 结果是否显示
   */
  private static applyTarget(snapshot: WidgetSnapshot, control: string, target: string,
    opText: string, opVisible: boolean): WidgetSnapshot {
    const next: WidgetSnapshot = {
      vin: snapshot.vin,
      modelName: snapshot.modelName,
      battery: snapshot.battery,
      range: snapshot.range,
      charging: snapshot.charging,
      chargerConnection: snapshot.chargerConnection,
      powerWatts: snapshot.powerWatts,
      currentAmps: snapshot.currentAmps,
      remainingMinutes: snapshot.remainingMinutes,
      locked: snapshot.locked,
      climate: snapshot.climate,
      opText: opText,
      opVisible: opVisible,
      opAt: opVisible ? Date.now() : 0,
      updatedAt: Date.now()
    };
    if (control === CardControlTask.CONTROL_LOCK) {
      next.locked = target;
    } else if (control === CardControlTask.CONTROL_CLIMATE) {
      next.climate = target;
    }
    return next;
  }

  /**
   * 轮询车端直到确认状态已切换。
   *
   * @returns 车端是否已确认；false 表示指令已下发但车端还没推进到终态
   */
  private static async confirm(repository: VehicleRepository, control: string, vin: string,
    target: string): Promise<boolean> {
    const startedAt: number = Date.now();
    while (Date.now() - startedAt < CardControlTask.CONFIRM_BUDGET_MS) {
      await CardControlTask.delay(CardControlTask.POLL_INTERVAL_MS);
      try {
        const current = await CardControlTask.readCurrentState(repository, control, vin,
          CardControlTask.emptySnapshot());
        if (current === target) {
          return true;
        }
      } catch (err) {
        Log.warn(TAG, `卡片轮询车辆状态失败: ${(err as Error).message}`);
      }
    }
    return false;
  }

  /**
   * 轮询时的占位快照 —— 读不到实时状态时不该回退到过时数据。
   */
  private static emptySnapshot(): WidgetSnapshot {
    return {
      vin: '',
      modelName: '',
      battery: -1,
      range: -1,
      charging: '',
      chargerConnection: '',
      powerWatts: 0,
      currentAmps: 0,
      remainingMinutes: 0,
      locked: '',
      climate: '',
      opText: '',
      opVisible: false,
      opAt: 0,
      updatedAt: 0
    };
  }

  /**
   * 延时。
   */
  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}
