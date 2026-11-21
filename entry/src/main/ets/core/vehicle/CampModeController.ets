import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Log } from '../../common/Log';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'CampModeController';

/**
 * 露营模式控制器 —— APP 侧编排的驻车空调定时守护。
 *
 * 车端只有 `ParkingClimateTimerService`（预约时刻语义），
 * 没有「运行 N 分钟」的协议，因此露营模式必须由 APP 编排：
 *   1. 开启时下发 `climate-start`，并记录到期时刻 endsAt = now + 时长；
 *   2. 到期时由调用方下发 `climate-stop`（净化在跑则一并停净化）；
 *   3. 时长可持久化，重启后 endsAt 仍在未来即视为仍在露营模式中。
 *
 * 本控制器只负责「时间」这一层，不碰车端指令 ——
 * 到期只上报事件，实际指令由页面侧下发。
 */
export class CampModeController {
  /** Preferences 存储名。 */
  static readonly STORE_NAME: string = 'camp_mode';
  /** 持久化键：当前时长（分钟）。 */
  static readonly KEY_DURATION: string = 'duration';
  /** 持久化键：到期时刻（epoch millis）。 */
  static readonly KEY_ENDS_AT: string = 'ends_at';
  /** 持久化键：空调目标温度（摄氏度）。 */
  static readonly KEY_TEMPERATURE: string = 'temperature';

  /** 档位数量：30 分钟 ~ 8 小时，步进 30 分钟。 */
  static readonly LEVEL_COUNT: number = 16;
  /** 最小时长（分钟）。 */
  static readonly MIN_MINUTES: number = 30;
  /** 最大时长（分钟）。 */
  static readonly MAX_MINUTES: number = 480;
  /** 步进（分钟）。 */
  static readonly STEP_MINUTES: number = 30;
  /** 默认时长（分钟）。 */
  static readonly DEFAULT_MINUTES: number = 60;
  /** 可选的空调目标温度档位（摄氏度）。 */
  static readonly TEMPERATURE_LEVELS: number[] = [20, 22, 24];
  /** 默认目标温度（摄氏度）。 */
  static readonly DEFAULT_TEMPERATURE: number = 22;

  /** 剩余时间心跳周期（毫秒）。 */
  static readonly TICK_INTERVAL_MS: number = 30000;

  private static store: preferences.Preferences | undefined = undefined;

  private context: common.UIAbilityContext | undefined = undefined;
  private endsAt: number = 0;
  private durationMinutes: number = CampModeController.DEFAULT_MINUTES;
  private temperatureCelsius: number = CampModeController.DEFAULT_TEMPERATURE;
  private expireTimer: number = -1;
  private tickTimer: number = -1;
  private onExpire: (() => void) | undefined = undefined;
  private onTick: ((remainingMinutes: number) => void) | undefined = undefined;

  constructor(onExpire?: () => void, onTick?: (remainingMinutes: number) => void) {
    this.onExpire = onExpire;
    this.onTick = onTick;
  }

  /**
   * 获取（并缓存）Preferences 实例。
   */
  private static async open(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    if (CampModeController.store === undefined) {
      CampModeController.store = await preferences.getPreferences(context, CampModeController.STORE_NAME);
    }
    return CampModeController.store;
  }

  /**
   * 绑定上下文并读取持久化状态。
   *
   * @returns 恢复后的时长（分钟）
   */
  async attach(context: common.UIAbilityContext): Promise<number> {
    this.context = context;
    try {
      const store = await CampModeController.open(context);
      const duration = await store.get(CampModeController.KEY_DURATION,
        CampModeController.DEFAULT_MINUTES) as number;
      const endsAt = await store.get(CampModeController.KEY_ENDS_AT, 0) as number;
      const temperature = await store.get(CampModeController.KEY_TEMPERATURE,
        CampModeController.DEFAULT_TEMPERATURE) as number;
      this.durationMinutes = CampModeController.clampMinutes(duration);
      this.temperatureCelsius = CampModeController.clampTemperature(temperature);
      this.endsAt = endsAt > Date.now() ? endsAt : 0;
      if (this.endsAt === 0) {
        await store.delete(CampModeController.KEY_ENDS_AT);
        await store.flush();
      }
      return this.durationMinutes;
    } catch (err) {
      Log.warn(TAG, `读取露营模式配置失败: ${(err as Error).message}`);
      return this.durationMinutes;
    }
  }

  /**
   * 把温度收敛到合法档位。
   */
  static clampTemperature(celsius: number): number {
    for (const level of CampModeController.TEMPERATURE_LEVELS) {
      if (level === celsius) {
        return celsius;
      }
    }
    return CampModeController.DEFAULT_TEMPERATURE;
  }

  /**
   * 当前目标温度（摄氏度）。
   */
  get temperature(): number {
    return this.temperatureCelsius;
  }

  /**
   * 保存目标温度档位。
   */
  async saveTemperature(celsius: number): Promise<void> {
    this.temperatureCelsius = CampModeController.clampTemperature(celsius);
    if (this.context === undefined) {
      return;
    }
    try {
      const store = await CampModeController.open(this.context);
      await store.put(CampModeController.KEY_TEMPERATURE, this.temperatureCelsius);
      await store.flush();
    } catch (err) {
      Log.warn(TAG, `保存露营模式温度失败: ${(err as Error).message}`);
    }
  }

  /**
   * 把分钟数收敛到合法档位。
   */
  static clampMinutes(minutes: number): number {
    if (minutes < CampModeController.MIN_MINUTES) {
      return CampModeController.MIN_MINUTES;
    }
    if (minutes > CampModeController.MAX_MINUTES) {
      return CampModeController.MAX_MINUTES;
    }
    return Math.round(minutes / CampModeController.STEP_MINUTES) * CampModeController.STEP_MINUTES;
  }

  /**
   * 当前时长（分钟）。
   */
  get duration(): number {
    return this.durationMinutes;
  }

  /**
   * 是否处于露营模式中（到期时刻在未来）。
   */
  isActive(): boolean {
    return this.endsAt > Date.now();
  }

  /**
   * 剩余分钟数。未开启时返回 0。
   */
  remainingMinutes(): number {
    if (this.endsAt <= 0) {
      return 0;
    }
    const left = this.endsAt - Date.now();
    return left <= 0 ? 0 : Math.ceil(left / 60000);
  }

  /**
   * 剩余时间占全程的比例（0 ~ 1），用于进度条。
   */
  remainingRatio(): number {
    const total = this.durationMinutes * 60000;
    if (total <= 0) {
      return 0;
    }
    const left = this.endsAt - Date.now();
    if (left <= 0) {
      return 0;
    }
    return Math.min(1, left / total);
  }

  /**
   * 保存时长档位。
   */
  async saveDuration(minutes: number): Promise<void> {
    this.durationMinutes = CampModeController.clampMinutes(minutes);
    if (this.context === undefined) {
      return;
    }
    try {
      const store = await CampModeController.open(this.context);
      await store.put(CampModeController.KEY_DURATION, this.durationMinutes);
      await store.flush();
    } catch (err) {
      Log.warn(TAG, `保存露营模式时长失败: ${(err as Error).message}`);
    }
  }

  /**
   * 开始露营模式：记录到期时刻并排程到期与心跳。
   */
  async start(minutes: number): Promise<void> {
    this.durationMinutes = CampModeController.clampMinutes(minutes);
    this.endsAt = Date.now() + this.durationMinutes * 60000;
    if (this.context !== undefined) {
      try {
        const store = await CampModeController.open(this.context);
        await store.put(CampModeController.KEY_DURATION, this.durationMinutes);
        await store.put(CampModeController.KEY_ENDS_AT, this.endsAt);
        await store.flush();
      } catch (err) {
        Log.warn(TAG, `保存露营模式到期时刻失败: ${(err as Error).message}`);
      }
    }
    this.scheduleExpire();
    this.startTick();
  }

  /**
   * 停止露营模式：清空到期时刻并撤掉定时器。
   */
  async stop(): Promise<void> {
    this.endsAt = 0;
    this.clearTimers();
    if (this.context !== undefined) {
      try {
        const store = await CampModeController.open(this.context);
        await store.delete(CampModeController.KEY_ENDS_AT);
        await store.flush();
      } catch (err) {
        Log.warn(TAG, `清除露营模式到期时刻失败: ${(err as Error).message}`);
      }
    }
  }

  /**
   * 续排到期定时器（重启恢复后调用）。
   */
  resume(): void {
    if (!this.isActive()) {
      return;
    }
    this.scheduleExpire();
    this.startTick();
  }

  /**
   * 到期定时器：单次 setTimeout，时长可变，不能用 setInterval。
   */
  private scheduleExpire(): void {
    if (this.expireTimer >= 0) {
      clearTimeout(this.expireTimer);
      this.expireTimer = -1;
    }
    const left = this.endsAt - Date.now();
    if (left <= 0) {
      return;
    }
    this.expireTimer = setTimeout(() => {
      this.expireTimer = -1;
      this.endsAt = 0;
      this.clearTick();
      if (this.onExpire !== undefined) {
        this.onExpire();
      }
    }, left);
  }

  /**
   * 剩余时间心跳：30 秒一次。
   */
  private startTick(): void {
    this.clearTick();
    this.tickTimer = setInterval(() => {
      if (this.onTick !== undefined) {
        this.onTick(this.remainingMinutes());
      }
    }, CampModeController.TICK_INTERVAL_MS);
  }

  private clearTick(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  private clearTimers(): void {
    if (this.expireTimer >= 0) {
      clearTimeout(this.expireTimer);
      this.expireTimer = -1;
    }
    this.clearTick();
  }
}
