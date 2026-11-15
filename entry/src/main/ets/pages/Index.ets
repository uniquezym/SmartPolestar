import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { VehicleRepository } from '../core/vehicle/VehicleRepository';
import { ControlCoordinator } from '../core/vehicle/ControlCoordinator';
import { VehicleCommands } from '../core/net/VehicleCommands';
import { VehicleState, ChargeStage, ChargeStageResolver } from '../core/model/VehicleState';
import { AppIcon, AppIconName } from '../components/Icons';
import { StateToggle, ToggleKind, TogglePhase } from '../components/StateToggle';
import { VehiclePlan } from '../components/VehiclePlan';
import { StateRow } from '../components/StateRow';
import { Control } from './Control';
import { Detail } from './Detail';
import { PlaceResolver } from '../core/vehicle/PlaceResolver';
import { MapLauncher } from '../core/vehicle/MapLauncher';
import { CardPublisher } from '../core/vehicle/CardPublisher';
import { BiometricGuard, BiometricResult } from '../core/vehicle/BiometricGuard';
import { SessionStore } from '../core/session/SessionStore';
import { BusinessError, Log } from '../common/Log';

/**
 * 车辆状态总览页。
 *
 * 设计语言：Nordic Instrument —— 暖纸白底、发丝线分隔、表格数字、
 * 单一品牌强调色（沃尔沃深蓝），状态与操作分层。
 *
 * 页面结构：
 *   顶栏（车型 + 可切换里程）→ 车辆俯视图 + 右侧快捷开关 → 电量续航指标
 *   → 充电卡（仅插枪时出现）→ 车辆状态清单
 */
@Entry
@Component
struct Index {
  /**
   * 切回前台时触发主动刷新的最小时间间隔（毫秒）。
   *
   * 频繁切后台/前台不该每次都打接口。取 2 小时 —— 对齐原版 ga0.m1402P
   * 的位置数据缓存有效期（stale 30 分钟 / 正常 2 小时）。
   * 用户可随时下拉刷新强制更新。
   */
  private static readonly RESUME_REFRESH_INTERVAL_MS: number = 2 * 60 * 60 * 1000;

  /**
   * 「距上次刷新」文案的刷新周期（毫秒）。
   *
   * 对齐原版 MainActivity 的 30 秒定时任务：只重算文案，不打接口。
   */
  private static readonly TEXT_TICK_INTERVAL_MS: number = 30000;

  /**
   * 充电中轮询电池状态的周期（毫秒）。
   *
   * 只在「充电中 / 智能充电」时启用，且只读 battery 一个域，
   * 避免每分钟拉全量状态（8 个域）。
   */
  private static readonly CHARGE_POLL_INTERVAL_MS: number = 60000;

  /**
   * 空调 / 净化状态检查的兜底间隔，同时也是检查间隔的上限（毫秒）。
   *
   * 这两项都会到时自动停机：驻车空调与空气净化跑到设定时长后车端自动
   * 停机，UI 必须跟着回落，否则按钮会一直停在「开」。
   *
   * 不做固定周期轮询 —— 车端在状态里给出「剩余运行分钟数」，据此推算
   * 预计结束时刻，把检查排在那一刻之前，一次读取即可确认是否已停机。
   * 固定周期要么太慢（漏掉停机），要么太密（白白发请求）。
   *
   * 30 分钟的上限是「看门狗」：用户在车端手动关掉空调/净化时，
   * 我们无法预知，最迟 30 分钟内会发现。取 30 分钟是因为驻车空调的
   * 常见时长就是 30 分钟 —— 上限放宽到不短于典型时长，
   * 一次完整的空调周期通常只需要 1 次状态检查。
   */
  private static readonly CLIMATE_CHECK_MAX_INTERVAL_MS: number = 1800000;

  /**
   * 预计结束时刻之后的复核延迟量（毫秒）。
   *
   * 车端是在**预计结束时刻**停机的，所以检查要排在那一刻**之后**。
   * 提前查必然还是「开启」，查完发现没停又得再排一轮 ——
   * 那样到期前后会以 15 秒一轮连查，一次空调反而多出七八次请求。
   *
   * 延迟 30 秒是因为车端的剩余分钟数是取整的，实际停机可能比
   * 预计时刻晚几十秒。查早了就靠「已过结束时刻」的 15 秒确认兜底。
   */
  private static readonly CLIMATE_CHECK_BUFFER_MS: number = 30000;

  /**
   * 临近结束时的最小检查间隔（毫秒）。
   *
   * 剩余时间为 0 或 1 分钟时，检查点已经紧贴预计结束时刻，
   * 用这个下限避免出现「每 0 毫秒查一次」的空转。
   */
  private static readonly CLIMATE_CHECK_MIN_INTERVAL_MS: number = 30000;

  /**
   * 已过预计结束时刻时的确认间隔（毫秒）。
   *
   * 到点了还没停机，需要尽快确认到底停没停。
   * 连续几次确认后仍报「开启」，会退到兜底间隔，不会一直这样查。
   */
  private static readonly CLIMATE_CHECK_OVERDUE_MS: number = 15000;

  /**
   * 连续多少次检查落在预计结束时刻之后仍报「开启」。
   *
   * 超过这个次数说明车端没在倒计时（或用户手动续时），改用兜底间隔，
   * 避免高频空转。8 次 × 15 秒 = 两分钟的确认窗口，
   * 足够覆盖车端剩余分钟数取整带来的误差。
   */
  private static readonly CLIMATE_CHECK_ENDGAME_LIMIT: number = 8;

  /** 正在拉取车辆状态。顶栏右上角显示刷新动效。 */
  @State loading: boolean = false;
  /** 下拉刷新指示器状态。 */
  @State refreshing: boolean = false;
  /** 上次成功刷新的时刻（epoch millis）。 */
  @State lastRefreshAt: number = 0;
  /** 距上次刷新的相对时间文案。 */
  @State lastRefreshText: string = '';
  @State errorMessage: string = '';
  @State hasSession: boolean = false;

  @State battery: number = -1;
  @State range: number = -1;
  /** 电池容量（kWh），来自 GetMyCars。 */
  @State batteryCapacityKwh: number = -1;
  @State charging: string = '—';
  @State chargerConnection: string = '未知';
  @State chargingType: string = '未知';
  @State powerWatts: number = 0;
  @State currentAmps: number = 0;
  @State remainingMinutes: number = 0;

  @State locked: string = '—';
  @State windows: string = '—';
  /** 驻车空调状态文案。卡片快照需要它。 */
  @State climate: string = '未知';
  @State odometerKm: number = -1;
  @State tripManualKm: number = -1;
  @State tripAutomaticKm: number = -1;
  /** 自充电小计里程。 */
  @State tripSinceChargeKm: number = -1;
  /** 三个口径的平均车速（km/h）。 */
  @State manualAverageSpeedKph: number = -1;
  @State automaticAverageSpeedKph: number = -1;
  @State sinceChargeAverageSpeedKph: number = -1;
  /** 三个口径的平均能耗（kWh/100km）。 */
  @State manualAverageEnergyKwhPer100Km: number = -1;
  @State automaticAverageEnergyKwhPer100Km: number = -1;
  @State sinceChargeAverageEnergyKwhPer100Km: number = -1;
  /** 三个口径的累计能耗（Wh）。 */
  @State manualEnergyWh: number = -1;
  @State automaticEnergyWh: number = -1;
  @State sinceChargeEnergyWh: number = -1;
  @State parkedTime: string = '—';
  /** 停车时刻（epoch millis），用于文案定时刷新。 */
  @State parkedTimestamp: number = 0;
  @State parkedCoordinate: string = '';
  /** 停车地点名（经纬度反查结果）。解析中时为空串。 */
  @State parkedPlace: string = '';
  /** 停车纬度。 */
  @State parkedLatitude: number = -1;
  /** 停车经度。 */
  @State parkedLongitude: number = -1;
  @State vin: string = '';
  @State modelName: string = '极星2';
  @State contentCodes: string = '';

  /** 四个状态开关的阶段。 */
  @State lockPhase: TogglePhase = TogglePhase.OFF;
  @State climatePhase: TogglePhase = TogglePhase.OFF;
  @State airPhase: TogglePhase = TogglePhase.OFF;
  @State windowPhase: TogglePhase = TogglePhase.OFF;

  /** 尾门解锁态 —— 车模尾门标记点显示警示色。 */
  @State trunkUnlocked: boolean = false;
  /** 尾门指令执行中 —— 标记点显示蓝色描边与旋转指示器。 */
  @State trunkBusy: boolean = false;
  /** 机盖开启 —— 车模标记点显示警示色。 */
  @State hoodOpen: boolean = false;
  /** 充电口开启 —— 车模标记点显示警示色。 */
  @State portOpen: boolean = false;
  /**
   * 四扇车窗状态，顺序：0=左前 1=右前 2=左后 3=右后。
   *
   * 车模逐扇染色，值 1 或 3 视为开启。
   */
  @State windowStates: number[] = [];
  /**
   * 四个车门状态，顺序：0=左前 1=右前 2=左后 3=右后。
   *
   * 车模逐扇绘制展开门板，值 1 或 3 视为开启。
   */
  @State doorStates: number[] = [];

  /** 里程口径：0=总里程 1=手动小计 2=自动小计。 */
  @State mileageMode: number = 0;

  /** 当前 Tab：0=概览 1=控制 2=详情。 */
  @State currentTab: number = 0;

  private context: common.UIAbilityContext | undefined = undefined;
  private repository: VehicleRepository | undefined = undefined;
  /** 「距上次刷新」文案的定时器句柄。 */
  private textTimer: number = -1;
  /** 充电中轮询电池状态的定时器句柄。 */
  private chargeTimer: number = -1;
  /** 充电轮询是否已有请求在途，避免并发重复拉取。 */
  private chargePolling: boolean = false;
  /** 空调 / 净化状态检查是否已有请求在途。 */
  private climatePolling: boolean = false;
  /** 空调剩余运行分钟数，用于推算预计结束时刻。 */
  private climateRemainingMinutes: number = -1;
  /** 净化剩余运行分钟数，用于推算预计结束时刻。 */
  private airRemainingMinutes: number = -1;
  /** 上一次推算预计结束时刻时用到的空调剩余分钟数。 */
  private climateObservedRemaining: number = -1;
  /** 上一次推算预计结束时刻时用到的净化剩余分钟数。 */
  private airObservedRemaining: number = -1;
  /** 下一次状态检查的定时器句柄（单次延时，不是周期）。 */
  private climateTimer: number = -1;
  /** 已安排的检查间隔，用于避免重复排程。 */
  private climateScheduledDelay: number = 0;
  /** 空调预计结束时刻（epoch millis），0 表示未知。 */
  private climateExpectedEnd: number = 0;
  /** 净化预计结束时刻（epoch millis），0 表示未知。 */
  private airExpectedEnd: number = 0;
  /** 连续多少次检查落在预计结束时刻之后仍报「开启」。 */
  private climateEndgameCount: number = 0;

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.repository = new VehicleRepository(this.context);
    this.requestLocationPermission();
    // 先读完刷新时刻再拉数据，保证「距上次刷新」的判断用的是真实值
    this.startup();
  }

  /**
   * 启动「距上次刷新」文案的定时更新。
   *
   * 对齐原版 MainActivity 的 30 秒定时任务（s00 case 1）：只重算文案，
   * 不打接口。这样「5 分钟前」会自己跳到「10 分钟前」，
   * 「最后停车位置」的「X 小时前」同理。
   *
   * 刷新进行中（loading / refreshing）时冻结文案，等刷新完成后统一更新。
   */
  private startTextTimer(): void {
    this.stopTextTimer();
    this.textTimer = setInterval(() => {
      if (this.loading || this.refreshing) {
        return;
      }
      this.refreshText();
    }, Index.TEXT_TICK_INTERVAL_MS);
  }

  /**
   * 重算「距上次刷新」文案与「最后停车位置」的时间文案。
   *
   * 两处都只做文案换算，不打接口。
   */
  private refreshText(): void {
    if (this.lastRefreshAt > 0) {
      this.lastRefreshText = Index.formatElapsed(this.lastRefreshAt, Date.now());
    }
    if (this.parkedTimestamp > 0) {
      this.parkedTime = this.formatParkedTime(this.parkedTimestamp);
    }
  }

  /**
   * 停止文案定时器。
   */
  private stopTextTimer(): void {
    if (this.textTimer !== -1) {
      clearInterval(this.textTimer);
      this.textTimer = -1;
    }
  }

  /**
   * 页面隐藏时停止文案定时器（切到后台不再更新）。
   */
  onPageHide(): void {
    this.stopTextTimer();
    this.stopChargeTimer();
    // 只取消已排的检查点，保留预计结束时刻 —— 它是绝对时刻，
    // 回到前台时按它重排即可，不用重新推算。
    this.clearClimateSchedule();
  }

  /**
   * 页面销毁时清理定时器。
   */
  aboutToDisappear(): void {
    this.stopTextTimer();
    this.stopChargeTimer();
    this.stopClimateTimer();
  }

  /**
   * 启动充电轮询。
   *
   * 只在充电中才启动；已经启动则不重复启动。脱离充电状态时由
   * syncChargeTimer 在下一次轮询后自动停止。
   */
  private startChargeTimer(): void {
    if (this.chargeTimer !== -1) {
      return;
    }
    this.chargeTimer = setInterval(() => {
      this.pollBattery();
    }, Index.CHARGE_POLL_INTERVAL_MS);
    Log.info('充电中：启动电池状态轮询');
  }

  /**
   * 停止充电轮询。
   */
  private stopChargeTimer(): void {
    if (this.chargeTimer !== -1) {
      clearInterval(this.chargeTimer);
      this.chargeTimer = -1;
      Log.info('停止电池状态轮询');
    }
  }

  /**
   * 根据当前充电阶段启停轮询。
   *
   * 只有「充电中」和「已暂停」需要轮询 —— 这两种情况下电量还会继续变。
   * 其余阶段电量是静止的，轮询没有意义。
   */
  private syncChargeTimer(): void {
    const stage = this.chargeStage();
    if (stage === ChargeStage.CHARGING || stage === ChargeStage.PAUSED) {
      this.startChargeTimer();
    } else {
      this.stopChargeTimer();
    }
  }

  /**
   * 静默拉一次电池状态。
   *
   * 只读 battery 一个域，不触发整页刷新动效。
   * 请求在途时直接跳过，避免并发。
   */
  private async pollBattery(): Promise<void> {
    if (this.repository === undefined || this.vin.length === 0) {
      return;
    }
    if (this.chargePolling) {
      return;
    }
    this.chargePolling = true;
    try {
      const state = await this.repository.readDomain('battery', this.vin);
      this.battery = state.battery ?? -1;
      this.range = state.range ?? -1;
      this.charging = state.charging;
      this.chargerConnection = state.chargerConnection;
      this.chargingType = state.chargingType;
      this.powerWatts = state.powerWatts ?? 0;
      this.currentAmps = state.currentAmps ?? 0;
      this.remainingMinutes = state.timeToFullMinutes ?? 0;
      // 充电中电量在变，卡片也要跟着更新
      this.publishCard();
    } catch (err) {
      const e = err as BusinessError;
      // 静默失败：轮询出错不该打扰用户，也不该把整页刷成错误态
      Log.warn(`充电轮询失败: code=${e.code} ${e.message}`);
    } finally {
      this.chargePolling = false;
      // 充电状态可能已变化（充满后转为已完成），据此启停轮询
      this.syncChargeTimer();
    }
  }

  /**
   * 根据当前空调 / 净化状态安排下一次状态检查。
   *
   * 这两项都会到时自动停机（车端到时停机），所以开启期间必须能发现
   * 它们已经停了，把按钮回落。
   *
   * 策略是「按预计结束时刻定时」而不是固定周期轮询：
   *   - 车端在状态里给出剩余运行分钟数 → 推算预计结束时刻
   *   - 把检查排在那个时刻之后，一次读取即可确认是否已停机
   *   - 拿不到剩余时长（老车 / 车端未返回）→ 退到兜底间隔
   *
   * 固定周期轮询的问题：周期短了浪费请求（一次 30 分钟的空调要查 6 次），
   * 周期长了又会漏掉停机时刻。
   */
  private syncClimateTimer(): void {
    const climateOn = this.climatePhase === TogglePhase.ON;
    const airOn = this.airPhase === TogglePhase.ON;
    if (!climateOn && !airOn) {
      this.stopClimateTimer();
      return;
    }

    // 预计结束时刻只在两种情况下重算：
    //   1. 刚刚转为开启 —— 建立锚点
    //   2. 剩余时长变长了 —— 用户在车端续了时
    // 其余情况一律沿用旧锚点。若每轮都用「当前剩余」重算，
    // 车端剩余值不递减时结束时刻会一直往后漂，永远等不到收尾。
    const now = Date.now();
    this.climateExpectedEnd = Index.refreshExpectedEnd(
      this.climateExpectedEnd, this.climateObservedRemaining,
      this.climateRemainingMinutes, climateOn, now);
    this.climateObservedRemaining = climateOn ? this.climateRemainingMinutes : -1;

    this.airExpectedEnd = Index.refreshExpectedEnd(
      this.airExpectedEnd, this.airObservedRemaining,
      this.airRemainingMinutes, airOn, now);
    this.airObservedRemaining = airOn ? this.airRemainingMinutes : -1;

    // 两项都在跑时取更早的那个结束时刻 —— 先结束的先查，避免漏掉。
    const deadline = Index.earliestDeadline(this.climateExpectedEnd, this.airExpectedEnd);

    let delay: number = Index.CLIMATE_CHECK_MAX_INTERVAL_MS;
    if (deadline > 0) {
      // 检查点排在预计结束时刻**之后** —— 车端到点才停机，提前查是白查。
      const wait = deadline + Index.CLIMATE_CHECK_BUFFER_MS - now;
      if (wait <= 0) {
        // 已经过了预计结束时刻，尽快确认到底停没停。
        delay = Index.CLIMATE_CHECK_OVERDUE_MS;
      } else {
        delay = Math.max(Index.CLIMATE_CHECK_MIN_INTERVAL_MS, Math.min(wait, delay));
      }
    }
    // 到了预计结束时刻还反复报「开启」——车端没在倒计时（或用户手动续时），
    // 连续几次之后改用兜底间隔，避免高频空转。
    if (this.climateEndgameCount >= Index.CLIMATE_CHECK_ENDGAME_LIMIT) {
      delay = Index.CLIMATE_CHECK_MAX_INTERVAL_MS;
    }

    // 间隔没变就不用重排 —— 空调与净化常常在同一秒结束，
    // 重排会白白丢掉已排好的检查点。
    if (this.climateTimer !== -1 && this.climateScheduledDelay === delay) {
      return;
    }

    // 只清掉已排的检查点，保留预计结束时刻与收尾计数 ——
    // stopClimateTimer 会把这两者一起清零，那样每轮重排都会丢掉状态。
    this.clearClimateSchedule();
    this.climateScheduledDelay = delay;
    // 用 setTimeout 而非 setInterval：ArkTS 的 setInterval 只能等间隔触发，
    // 而这里的检查点每次都不同（随剩余时长收敛），必须单次排程。
    this.climateTimer = setTimeout(() => {
      this.climateTimer = -1;
      this.climateScheduledDelay = 0;
      this.pollClimate();
    }, delay);
    Log.info(`空调/净化运行中：安排状态检查，${delay}ms 后`
      + `（剩余 ${this.climateRemainingMinutes}/${this.airRemainingMinutes} 分钟）`);
  }

  /**
   * 取消已安排的检查点，但不动状态。
   */
  private clearClimateSchedule(): void {
    if (this.climateTimer !== -1) {
      clearTimeout(this.climateTimer);
      this.climateTimer = -1;
    }
    this.climateScheduledDelay = 0;
  }

  /**
   * 停止空调 / 净化状态检查，并清掉相关状态。
   */
  private stopClimateTimer(): void {
    this.clearClimateSchedule();
    this.climateEndgameCount = 0;
    this.climateExpectedEnd = 0;
    this.airExpectedEnd = 0;
  }

  /**
   * 静默拉一次空调与空气净化状态。
   *
   * 只读 climate + air 两个域，不触发整页刷新动效。
   * 这两个功能会到时自动关闭，必须靠状态检查把按钮状态落定。
   */
  private async pollClimate(): Promise<void> {
    if (this.repository === undefined || this.vin.length === 0) {
      return;
    }
    if (this.climatePolling) {
      return;
    }
    this.climatePolling = true;
    try {
      const climateState = await this.repository.readDomain('climate', this.vin);
      const climateWasOn = this.climatePhase === TogglePhase.ON;
      if (climateState.climate === '开启') {
        this.climatePhase = TogglePhase.ON;
      } else if (climateState.climate === '关闭') {
        this.climatePhase = TogglePhase.OFF;
      }
      this.climateRemainingMinutes = climateState.climateRuntimeMinutes ?? -1;
      this.climate = climateState.climate;

      const airState = await this.repository.readDomain('air', this.vin);
      const airWasOn = this.airPhase === TogglePhase.ON;
      if (airState.air === '开启') {
        this.airPhase = TogglePhase.ON;
      } else if (airState.air === '关闭') {
        this.airPhase = TogglePhase.OFF;
      }
      this.airRemainingMinutes = airState.airRuntimeMinutes ?? -1;

      const now = Date.now();
      const stillOn = this.climatePhase === TogglePhase.ON || this.airPhase === TogglePhase.ON;

      // 到了预计结束时刻仍报「开启」——车端没在倒计时（或用户手动续时），
      // 连续几次之后改用兜底间隔，避免高频空转。
      const pastDeadline = (this.climateExpectedEnd > 0 && this.climateExpectedEnd <= now) ||
        (this.airExpectedEnd > 0 && this.airExpectedEnd <= now);
      if (stillOn && pastDeadline) {
        this.climateEndgameCount++;
      } else {
        this.climateEndgameCount = 0;
      }

      // 状态有变化时同步桌面卡片 —— 空调/净化停了，卡片文案也要跟着改。
      if (climateWasOn !== (this.climatePhase === TogglePhase.ON) ||
        airWasOn !== (this.airPhase === TogglePhase.ON)) {
        this.publishCard();
      }
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`空调/净化状态检查失败: code=${e.code} ${e.message}`);
    } finally {
      this.climatePolling = false;
      // 状态可能已变为关闭，据此重排下一次检查
      this.syncClimateTimer();
    }
  }

  /**
   * 取两个预计结束时刻中更早的那个。0 表示未知。
   */
  private static earliestDeadline(a: number, b: number): number {
    if (a <= 0) {
      return b;
    }
    if (b <= 0) {
      return a;
    }
    return Math.min(a, b);
  }

  /**
   * 重算预计结束时刻。
   *
   * 只在「刚开启」或「剩余时长变长」时重算：
   *   - 刚开启：还没有锚点，用当前剩余分钟数建立
   *   - 剩余变长：用户在车端续了时，锚点要跟着往后挪
   * 其余情况沿用旧锚点 —— 车端的剩余值可能不精确递减，
   * 每轮重算会让结束时刻一直往后漂，永远等不到收尾。
   *
   * @param expectedEnd       现有锚点，0 表示还没有
   * @param observedRemaining 上次观测到的剩余分钟数，-1 表示未知
   * @param remaining         当前剩余分钟数，-1 表示未知
   * @param running           当前是否在运行
   * @param now               当前时刻
   * @returns 新的预计结束时刻，0 表示未知
   */
  private static refreshExpectedEnd(expectedEnd: number, observedRemaining: number,
    remaining: number, running: boolean, now: number): number {
    if (!running) {
      return 0;
    }
    if (remaining < 0) {
      // 拿不到剩余时长：没有锚点可用，只能退回兜底间隔。
      return expectedEnd;
    }
    if (expectedEnd <= 0) {
      // 刚开启 —— 建立锚点。
      return now + remaining * 60000;
    }
    if (observedRemaining >= 0 && remaining > observedRemaining) {
      // 续了时 —— 锚点往后挪一个差值。
      return expectedEnd + (remaining - observedRemaining) * 60000;
    }
    return expectedEnd;
  }

  /**
   * 启动流程：读取上次刷新时刻 → 加载会话与状态。
   */
  private async startup(): Promise<void> {
    await this.loadRefreshTime();
    this.startTextTimer();
    await this.bootstrap();
  }

  /**
   * 申请定位权限。
   *
   * 仅用于把停车坐标解析成地址名。进页面时申请一次，避免用户点击
   * 「最后停车位置」时才弹窗打断。拒绝也不影响功能 —— 地点名退化为坐标。
   *
   * 必须同时申请 LOCATION（精确定位）：只有 APPROXIMATELY_LOCATION 时，
   * 系统逆地理编码只会返回到区县级。
   */
  private async requestLocationPermission(): Promise<void> {
    const context = this.context;
    if (context === undefined) {
      return;
    }
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      await atManager.requestPermissionsFromUser(context, [
        'ohos.permission.APPROXIMATELY_LOCATION',
        'ohos.permission.LOCATION'
      ]);
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`申请位置权限失败: code=${e.code} ${e.message}`);
    }
  }

  /**
   * 页面每次显示时触发（切回前台也会）。
   *
   * 后台期间令牌可能已过期，或本地会话被清理，因此回到前台要重新读取会话。
   * 但**状态刷新**按需触发：距上次刷新不足阈值就不打扰用户。
   */
  onPageShow(): void {
    if (this.repository === undefined) {
      return;
    }
    // 首次显示由 bootstrap 负责，避免重复请求
    if (!this.hasSession) {
      return;
    }
    this.startTextTimer();
    // 切回前台立即重算一次文案，不等 30 秒定时器
    this.refreshText();
    // 充电中的轮询在页面隐藏时已停，回到前台需要恢复
    this.syncChargeTimer();
    // 空调 / 净化的状态检查同理 —— 预计结束时刻是绝对时刻，
    // 隐藏期间即使已经过了也会立刻查一次确认。
    this.syncClimateTimer();
    this.resume();
  }

  /**
   * 从后台恢复。
   *
   * 只做两件事：
   *   1. 重新读取会话（后台期间令牌可能过期）
   *   2. 距上次刷新超过阈值时才拉一次状态
   */
  private async resume(): Promise<void> {
    if (this.repository === undefined) {
      return;
    }

    try {
      await this.repository.loadSession();
    } catch (err) {
      const e = err as BusinessError;
      if (e.code === 401) {
        this.getUIContext().getRouter().replaceUrl({ url: 'pages/Login' });
        return;
      }
      Log.warn(`恢复前台时读取会话失败: ${e.message}`);
      return;
    }

    if (!this.shouldRefreshOnResume()) {
      Log.info(`距上次刷新不足 ${Index.RESUME_REFRESH_INTERVAL_MS}ms，跳过自动刷新`);
      return;
    }

    await this.refresh();
  }

  /**
   * 判断切回前台时是否需要主动刷新。
   *
   * 规则：距上次成功刷新超过阈值才刷新，避免频繁切后台/前台都打接口。
   * 从未刷新过则立即刷新。
   */
  private shouldRefreshOnResume(): boolean {
    if (this.lastRefreshAt <= 0) {
      return true;
    }
    return Date.now() - this.lastRefreshAt >= Index.RESUME_REFRESH_INTERVAL_MS;
  }

  /**
   * 加载会话并拉取状态。
   */
  private async bootstrap(): Promise<void> {
    if (this.repository === undefined) {
      return;
    }
    this.loading = true;
    this.errorMessage = '';
    try {
      await this.repository.loadSession();
      this.hasSession = true;
      await this.refresh();
    } catch (err) {
      const e = err as BusinessError;
      if (e.code === 401) {
        // 未登录，跳转登录页
        this.getUIContext().getRouter().replaceUrl({ url: 'pages/Login' });
        return;
      }
      this.errorMessage = e.message.length > 0 ? e.message : '加载失败';
      Log.error(`加载失败: ${e.message}`);
    } finally {
      this.loading = false;
      // 启动流程结束后同步一次文案，保证显示的是最新刷新时刻
      this.refreshText();
    }
  }

  /**
   * 刷新车辆状态。
   */
  private async refresh(): Promise<void> {
    if (this.repository === undefined) {
      return;
    }
    this.loading = true;
    this.errorMessage = '';
    try {
      const states = await this.repository.readAllStates();
      if (states.length === 0) {
        this.errorMessage = '账号下没有发现车辆';
        return;
      }
      this.applyState(states[0]);
      // 记录刷新时刻，供「距上次刷新」文案使用
      this.markRefreshed();
      // 把状态同步到桌面卡片
      this.publishCard();
    } catch (err) {
      const e = err as BusinessError;
      if (e.code === 401) {
        // 会话失效：回登录页，而不是显示成「没有车辆」
        Log.warn('会话已失效，跳转登录页');
        this.getUIContext().getRouter().replaceUrl({ url: 'pages/Login' });
        return;
      }
      this.errorMessage = e.message.length > 0 ? e.message : '状态读取失败';
      Log.error(`状态读取失败: ${e.message}`);
    } finally {
      this.loading = false;
      // 刷新彻底结束后再更新文案，避免过程中看到跳变。
      // 下拉刷新时先不更新，等下拉指示器收起后由 onPullRefresh 统一更新。
      if (!this.refreshing) {
        this.refreshText();
      }
    }
  }

  /**
   * 把当前状态同步到桌面卡片。
   *
   * 失败不影响主流程 —— 卡片只是状态的一个出口，
   * 不该因为推送失败而让整页刷新报错。
   */
  private publishCard(): void {
    const context = this.context;
    if (context === undefined || this.vin.length === 0) {
      return;
    }
    const snapshot = CardPublisher.snapshot(
      this.vin, this.modelName, this.battery, this.range,
      this.charging, this.chargerConnection, this.powerWatts, this.currentAmps,
      this.remainingMinutes, this.locked, this.climate);
    CardPublisher.publish(context, snapshot).catch((err: Error) => {
      Log.warn(`同步卡片失败: ${err.message}`);
    });
  }

  /**
   * 记录本次刷新完成的时刻。
   *
   * 对应 Android 端写 SharedPreferences("session", "last_refresh_at")。
   * 文案不在这里更新 —— 统一由 refresh() 的 finally 在 loading 归位后刷新。
   */
  private markRefreshed(): void {
    const context = this.context;
    if (context === undefined) {
      return;
    }
    const now = Date.now();
    this.lastRefreshAt = now;
    // 存储写入不阻塞刷新
    SessionStore.setLastRefreshAt(context, now).catch((err: Error) => {
      Log.warn(`记录刷新时刻失败: ${err.message}`);
    });
  }

  /**
   * 读取上次刷新时刻并生成文案。
   *
   * 对应 Android 端 m401n0：小于 1e11 的时间戳按秒处理，需 ×1000。
   */
  private async loadRefreshTime(): Promise<void> {
    const context = this.context;
    if (context === undefined) {
      return;
    }
    try {
      const stored = await SessionStore.getLastRefreshAt(context);
      // 本次进入页面若已刷新过，就不要用旧的存储值覆盖「刚刚」
      if (stored > 0 && this.lastRefreshAt === 0) {
        this.lastRefreshAt = stored;
        this.lastRefreshText = Index.formatElapsed(stored, Date.now());
      }
    } catch (err) {
      Log.warn(`读取刷新时刻失败: ${(err as Error).message}`);
    }
  }

  /**
   * 把时间差转成相对时间文案。
   *
   * 还原自 Android 端 m401n0：
   *   < 10 秒      → 刚刚
   *   < 1 分钟     → 不到 1 分钟
   *   < 1 小时     → N 分钟前
   *   < 1 天       → N 小时前
   *   其余         → N 天前
   * 时间戳小于 1e11 时按秒处理（×1000）。
   */
  private static formatElapsed(from: number, now: number): string {
    let ts = from;
    if (ts > 0 && ts < 100000000000) {
      ts *= 1000;
    }
    const delta = Math.max(0, now - ts);
    if (delta < 10000) {
      return '刚刚';
    }
    if (delta < 60000) {
      return '不到 1 分钟';
    }
    if (delta < 3600000) {
      return `${Math.max(1, Math.floor(delta / 60000))} 分钟前`;
    }
    if (delta < 86400000) {
      return `${Math.max(1, Math.floor(delta / 3600000))} 小时前`;
    }
    return `${Math.max(1, Math.floor(delta / 86400000))} 天前`;
  }

  /**
   * 下拉刷新回调。
   *
   * 刷新过程中「距上次刷新」的文案保持不变，等刷新完成、下拉指示器收起后再更新。
   */
  private async onPullRefresh(): Promise<void> {
    this.refreshing = true;
    try {
      await this.refresh();
    } finally {
      this.refreshing = false;
      // 刷新已结束，此时才更新「距上次刷新」的文案
      this.refreshText();
    }
  }

  /**
   * 把状态对象映射到 UI 字段。
   */
  private applyState(state: VehicleState): void {
    this.vin = state.vin;
    if (state.modelName.length > 0) {
      this.modelName = state.modelName;
    }
    this.contentCodes = state.contentCodes;

    this.battery = state.battery ?? -1;
    this.range = state.range ?? -1;
    this.batteryCapacityKwh = state.batteryCapacityKwh ?? -1;
    this.charging = state.charging;
    this.chargerConnection = state.chargerConnection;
    this.chargingType = state.chargingType;
    this.powerWatts = state.powerWatts ?? 0;
    this.currentAmps = state.currentAmps ?? 0;
    this.remainingMinutes = state.timeToFullMinutes ?? 0;
    // 充电状态决定是否启动轮询
    this.syncChargeTimer();

    this.locked = state.locked;
    this.windows = state.windows;
    this.climate = state.climate;

    this.odometerKm = state.odometerKm ?? -1;
    this.tripManualKm = state.tripManualKm ?? -1;
    this.tripAutomaticKm = state.tripAutomaticKm ?? -1;
    this.tripSinceChargeKm = state.tripSinceChargeKm ?? -1;
    this.manualAverageSpeedKph = state.manualAverageSpeedKph ?? -1;
    this.automaticAverageSpeedKph = state.automaticAverageSpeedKph ?? -1;
    this.sinceChargeAverageSpeedKph = state.sinceChargeAverageSpeedKph ?? -1;
    this.manualAverageEnergyKwhPer100Km = state.tripManualAverageEnergyKwhPer100Km ?? -1;
    this.automaticAverageEnergyKwhPer100Km = state.tripAutomaticAverageEnergyKwhPer100Km ?? -1;
    this.sinceChargeAverageEnergyKwhPer100Km = state.tripSinceChargeAverageEnergyKwhPer100Km ?? -1;
    this.manualEnergyWh = state.tripManualEnergyWh ?? -1;
    this.automaticEnergyWh = state.tripAutomaticEnergyWh ?? -1;
    this.sinceChargeEnergyWh = state.tripSinceChargeEnergyWh ?? -1;

    if (state.parkedTimestamp !== undefined && state.parkedTimestamp > 0) {
      this.parkedTimestamp = state.parkedTimestamp;
      this.parkedTime = this.formatParkedTime(state.parkedTimestamp);
    }
    // 停车坐标变化时重新反查地点名
    if (state.parkedLatitude !== undefined && state.parkedLongitude !== undefined) {
      this.parkedLatitude = state.parkedLatitude;
      this.parkedLongitude = state.parkedLongitude;
      this.parkedCoordinate = `${state.parkedLatitude.toFixed(4)}, ${state.parkedLongitude.toFixed(4)}`;
      this.resolveParkedPlace();
    }

    // 开关初始态由当前车辆状态推导。
    // 只有状态明确时才覆盖：车端在指令生效前会返回「处理中」/「未知」，
    // 此时若一律映射成关闭，会把用户刚开启的状态弹回去。
    if (state.locked === '未锁') {
      this.lockPhase = TogglePhase.ON;
    } else if (state.locked === '已锁') {
      this.lockPhase = TogglePhase.OFF;
    }
    if (state.climate === '开启') {
      this.climatePhase = TogglePhase.ON;
    } else if (state.climate === '关闭') {
      this.climatePhase = TogglePhase.OFF;
    }
    if (state.air === '开启') {
      this.airPhase = TogglePhase.ON;
    } else if (state.air === '关闭') {
      this.airPhase = TogglePhase.OFF;
    }
    if (state.windows === '车窗已关闭') {
      this.windowPhase = TogglePhase.OFF;
    } else if (state.windows === '车窗未关闭') {
      this.windowPhase = TogglePhase.ON;
    }

    // 车模标记点：尾门锁、机盖、充电口。判定对齐原版 g10（1 或 3 视为开启）。
    if (state.tailgateLock === '未锁') {
      this.trunkUnlocked = true;
    } else if (state.tailgateLock === '已锁') {
      this.trunkUnlocked = false;
    }
    this.hoodOpen = state.hoodState === 1 || state.hoodState === 3;
    this.portOpen = state.chargePortState === 1 || state.chargePortState === 3;

    // 车模门窗：逐扇独立染色 / 绘制展开门板
    this.windowStates = state.windowStates;
    this.doorStates = state.doorStates;

    // 空调 / 净化到时会自动关闭，开启期间要持续检查才能让按钮回落。
    // 剩余时长用来推算预计结束时刻，把状态检查排在那之前。
    this.climateRemainingMinutes = state.climateRuntimeMinutes ?? -1;
    this.airRemainingMinutes = state.airRuntimeMinutes ?? -1;
    this.syncClimateTimer();
  }

  /**
   * 停车时间相对当前时刻的描述。
   *
   * 对齐 Android 端 m401n0：时间戳小于 1e11 时按秒处理，需 ×1000。
   */
  private formatParkedTime(timestamp: number): string {
    let ts = timestamp;
    if (ts > 0 && ts < 100000000000) {
      ts *= 1000;
    }
    const delta = Date.now() - ts;
    if (delta < 0 || delta > 86400000 * 30) {
      return '—';
    }
    if (delta < 60000) {
      return '刚刚';
    }
    if (delta < 3600000) {
      return `${Math.max(1, Math.floor(delta / 60000))} 分钟前`;
    }
    if (delta < 86400000) {
      return `${Math.max(1, Math.floor(delta / 3600000))} 小时前`;
    }
    return `${Math.max(1, Math.floor(delta / 86400000))} 天前`;
  }

  /**
   * 可用电量（kWh）= 电量百分比 × 电池容量。
   */
  private usableKwh(): string {
    if (this.battery < 0 || this.batteryCapacityKwh <= 0) {
      return '—';
    }
    return `${(this.battery * this.batteryCapacityKwh / 100).toFixed(1)} kWh`;
  }

  /**
   * 满电估算续航（km）= 当前续航 ÷ 当前电量比例。
   */
  private fullRangeKm(): string {
    if (this.range < 0 || this.battery <= 0) {
      return '—';
    }
    return `${Math.round(this.range * 100 / this.battery)} km`;
  }

  /**
   * 是否处于充电中。
   *
   * 协议字段 charging 的取值见 CHARGING_LABELS：
   * 1 = 充电中，6 = 智能充电。这两种都算正在充电。
   */
  private isCharging(): boolean {
    return this.charging === '充电中' || this.charging === '智能充电';
  }

  /**
   * 统一的充电阶段。
   *
   * 判定规则集中在 ChargeStageResolver，主应用与桌面卡片共用同一套，
   * 避免两边显示的充电状态不一致。
   */
  private chargeStage(): ChargeStage {
    return ChargeStageResolver.resolve(this.charging, this.chargerConnection);
  }

  /**
   * 车模上是否显示充电标记点。
   *
   * 未充电与放电中都不显示 —— 放电时并没有插着充电枪。
   */
  private chargingMarked(): boolean {
    const stage = this.chargeStage();
    return stage !== ChargeStage.IDLE && stage !== ChargeStage.DISCHARGING;
  }

  /**
   * 车模充电标记点的颜色，随充电阶段变化。
   */
  private chargeMarkerColor(): ResourceColor {
    const stage = this.chargeStage();
    if (stage === ChargeStage.COMPLETED) {
      return $r('app.color.app_ok');
    }
    if (stage === ChargeStage.FAULT) {
      return $r('app.color.app_error');
    }
    return $r('app.color.app_accent');
  }

  /**
   * 车模充电标记点是否呼吸 —— 只有真正在充电时才呼吸。
   *
   * 之前把「已连接」当成充电中，导致充满之后光环还在转。
   */
  private chargeMarkerPulsing(): boolean {
    return this.chargeStage() === ChargeStage.CHARGING;
  }

  /**
   * 充电功率文案。≥1000W 显示 kW，否则显示 W。
   *
   * 还原自原版 MainActivity.m325d0。
   */
  private powerText(): string {
    if (this.powerWatts <= 0) {
      return '';
    }
    if (this.powerWatts >= 1000) {
      return `${(this.powerWatts / 1000).toFixed(1)} kW`;
    }
    return `${this.powerWatts} W`;
  }

  /**
   * 充电电流文案。
   */
  private currentText(): string {
    if (this.currentAmps <= 0) {
      return '';
    }
    return `${Math.round(this.currentAmps)} A`;
  }

  /**
   * 充满剩余时长文案。
   */
  private remainingTimeText(): string {
    if (this.remainingMinutes <= 0) {
      return '';
    }
    if (this.remainingMinutes < 60) {
      return `约 ${this.remainingMinutes} 分钟`;
    }
    const h = Math.floor(this.remainingMinutes / 60);
    const m = this.remainingMinutes % 60;
    if (m === 0) {
      return `约 ${h} 小时`;
    }
    return `约 ${h} 小时 ${m} 分`;
  }

  /**
   * 充电枪已连接时显示在「电量」标题后面的 inline 补充信息。
   *
   * 按充电阶段给出一句话：
   *   充电中 → 功率 · 电流 · 充满剩余时长
   *   已完成 → 已完成
   *   已插枪 → 已连接
   *   已暂停 → 已暂停
   *   故障   → 充电错误 / 连接故障
   *
   * 放在标题后面而非另起一行，行数不变，下方内容不会被顶下去。
   */
  private chargeInlineText(): string {
    const stage = this.chargeStage();
    if (stage === ChargeStage.IDLE) {
      return '';
    }
    if (stage === ChargeStage.DISCHARGING) {
      return '放电中';
    }
    if (stage === ChargeStage.COMPLETED) {
      return '已完成';
    }
    if (stage === ChargeStage.FAULT) {
      return this.chargerConnection === '连接故障' ? '连接故障' : '充电错误';
    }
    if (stage === ChargeStage.PAUSED) {
      return '已暂停';
    }
    if (stage === ChargeStage.PLUGGED) {
      return '已连接';
    }
    // 充电中：功率 · 电流 · 充满剩余时长
    const parts: string[] = [];
    const power = this.powerText();
    if (power.length > 0) {
      parts.push(power);
    }
    const current = this.currentText();
    if (current.length > 0) {
      parts.push(current);
    }
    const remaining = this.remainingTimeText();
    if (remaining.length > 0) {
      parts.push(remaining);
    }
    if (parts.length === 0) {
      return '充电中';
    }
    return parts.join(' · ');
  }

  /**
   * 电量区 inline 文案的颜色，随充电阶段变化。
   */
  private chargeInlineColor(): ResourceColor {
    const stage = this.chargeStage();
    if (stage === ChargeStage.COMPLETED) {
      return $r('app.color.app_ok');
    }
    if (stage === ChargeStage.FAULT) {
      return $r('app.color.app_error');
    }
    if (stage === ChargeStage.DISCHARGING) {
      return $r('app.color.app_secondary_text');
    }
    return $r('app.color.app_accent');
  }

  /**
   * 车型副标题：配置代码 / 电池容量 / 车型兜底。
   */
  private modelSubtitle(): string {
    if (this.contentCodes.length > 0) {
      return `配置 ${this.contentCodes}`;
    }
    if (this.batteryCapacityKwh > 0) {
      return `${this.batteryCapacityKwh.toFixed(0)} kWh`;
    }
    return '极星2';
  }

  /**
   * 当前里程口径的数值与标签。
   */
  private mileageValue(): string {
    let value = this.odometerKm;
    if (this.mileageMode === 1) {
      value = this.tripManualKm;
    } else if (this.mileageMode === 2) {
      value = this.tripAutomaticKm;
    }
    if (value < 0) {
      return '—';
    }
    return Math.round(value).toLocaleString();
  }

  private mileageLabel(): string {
    if (this.mileageMode === 1) {
      return '手动小计';
    }
    if (this.mileageMode === 2) {
      return '自动小计';
    }
    return '总里程';
  }

  /**
   * 当前口径的平均车速（km/h）。
   */
  private mileageAverageSpeed(): number {
    if (this.mileageMode === 1) {
      return this.manualAverageSpeedKph;
    }
    if (this.mileageMode === 2) {
      return this.automaticAverageSpeedKph;
    }
    return -1;
  }

  /**
   * 当前口径的平均能耗（kWh/100km）。
   */
  private mileageAverageEnergy(): number {
    if (this.mileageMode === 1) {
      return this.manualAverageEnergyKwhPer100Km;
    }
    if (this.mileageMode === 2) {
      return this.automaticAverageEnergyKwhPer100Km;
    }
    return -1;
  }

  /**
   * 当前口径的行驶时长。
   *
   * 车端没有单独的时长字段，用「小计里程 ÷ 平均车速」推算；
   * 里程或均速缺失时返回空串，不显示该项。
   */
  private mileageDuration(): string {
    if (this.mileageMode === 0) {
      return '';
    }
    let distance = this.odometerKm;
    if (this.mileageMode === 1) {
      distance = this.tripManualKm;
    } else if (this.mileageMode === 2) {
      distance = this.tripAutomaticKm;
    }
    const speed = this.mileageAverageSpeed();
    if (distance < 0 || speed <= 0) {
      return '';
    }
    const hours = distance / speed;
    if (!Number.isFinite(hours) || hours <= 0) {
      return '';
    }
    const totalMinutes = Math.round(hours * 60);
    const h = Math.floor(totalMinutes / 60);
    const m = totalMinutes % 60;
    if (h <= 0) {
      return `${m} 分钟`;
    }
    return `${h} 小时 ${m} 分`;
  }

  /**
   * 当前口径的副信息行。
   *
   * 还原自 MainActivity.m320Q0：
   *   - 总里程：三个小计的累计能耗（Wh / 1000 → kWh）
   *   - 手动 / 自动小计：平均能耗（kWh/100km）· 平均时速（km/h）· 行驶时长
   */
  private mileageNote(): string {
    const parts: string[] = [];

    if (this.mileageMode === 0) {
      // 总里程：手动 / 自动 / 充后 三个小计的累计能耗
      const manual = this.manualEnergyWh;
      const automatic = this.automaticEnergyWh;
      const sinceCharge = this.sinceChargeEnergyWh;
      if (manual >= 0) {
        parts.push(`手动 ${(manual / 1000).toFixed(2)}`);
      }
      if (automatic >= 0) {
        parts.push(`自动 ${(automatic / 1000).toFixed(2)}`);
      }
      if (sinceCharge >= 0) {
        parts.push(`充后 ${(sinceCharge / 1000).toFixed(2)}`);
      }
      if (parts.length > 0) {
        parts.push('kWh');
      }
      return parts.join(' · ');
    }

    const energy = this.mileageAverageEnergy();
    if (energy >= 0) {
      parts.push(`${energy.toFixed(1)} kWh/100km`);
    }
    const speed = this.mileageAverageSpeed();
    if (speed >= 0) {
      parts.push(`${speed} km/h`);
    }
    const duration = this.mileageDuration();
    if (duration.length > 0) {
      parts.push(duration);
    }
    return parts.join(' · ');
  }

  /**
   * 切换里程口径。
   */
  private flipMileage(): void {
    this.mileageMode = (this.mileageMode + 1) % 3;
  }

  /**
   * 反查停车坐标对应的地点名。
   *
   * 失败时保持空串，UI 回退显示原始坐标 —— 地点名是补充信息，
   * 不该因为它拖垮整个概览页。
   */
  private async resolveParkedPlace(): Promise<void> {
    const lat = this.parkedLatitude;
    const lon = this.parkedLongitude;
    this.parkedPlace = '';
    const name = await PlaceResolver.resolve(lat, lon);
    // 期间坐标可能已变，丢弃过期结果
    if (lat === this.parkedLatitude && lon === this.parkedLongitude) {
      this.parkedPlace = name;
    }
  }

  /**
   * 点击「最后停车位置」：拉起系统地图定位到停车点。
   */
  private async openParkedMap(): Promise<void> {
    if (this.context === undefined) {
      return;
    }
    if (this.parkedLatitude < 0 || this.parkedLongitude < 0) {
      this.toast('暂无停车位置信息');
      return;
    }
    const opened = await MapLauncher.open(
      this.context, this.parkedLatitude, this.parkedLongitude, this.parkedPlace);
    if (!opened) {
      // 系统没有可响应 geo: 的地图应用，退到内置在线地图
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/Map',
        params: {
          latitude: this.parkedLatitude,
          longitude: this.parkedLongitude,
          name: this.parkedPlace
        }
      });
    }
  }

  /**
   * 驻车空调是否处于占用态（开启中或执行中）。
   *
   * 空调与空气净化互斥：一方占用时另一方置灰。
   */
  private climateActive(): boolean {
    return this.climatePhase !== TogglePhase.OFF;
  }

  /**
   * 空气净化是否处于占用态（开启中或执行中）。
   */
  private airActive(): boolean {
    return this.airPhase !== TogglePhase.OFF;
  }

  /**
   * 车控前置检查：会话就绪。
   */
  private controlPrerequisites(): boolean {
    if (this.repository === undefined || this.context === undefined) {
      this.errorMessage = '会话未就绪，请重试';
      return false;
    }
    return true;
  }

  /**
   * 快捷开关点击：进入执行中态，下发指令，轮询确认车端状态后落定。
   *
   * 对应 Android 端 RunnableC0669rx：指令下发成功后**不是立即刷新**，
   * 而是每 300ms~1200ms 轮询一次车辆状态，直到状态确认或超时。
   * 直接刷新会读到车端尚未生效的旧值（例如空调仍为「关闭」/「处理中」），
   * 把乐观状态覆盖回去。
   */
  private async toggle(kind: ToggleKind): Promise<void> {
    if (!this.controlPrerequisites()) {
      return;
    }

    // 互斥校验：空调与空气净化不能同时运行。
    // UI 已把对方置灰，这里再挡一道，防止状态切换瞬间的竞态。
    if (kind === ToggleKind.CLIMATE && this.airActive()) {
      this.toast('空气净化运行中，无法开启驻车空调');
      return;
    }
    if (kind === ToggleKind.PURIFIER && this.climateActive()) {
      this.toast('驻车空调运行中，无法开启空气净化');
      return;
    }

    // 记录点击前的阶段，失败时回滚
    const prev = this.phaseOf(kind);

    // 目标动作：由当前阶段决定
    const action = this.actionOf(kind, prev);

    // 高安全性操作（整车解锁、开窗）先过指纹门禁，再下发指令。
    // 验证期间用「验证中」态提示用户点了哪个按钮，
    // 但不显示执行动画 —— 指令尚未下发，不能让用户以为已经在执行。
    if (this.requiresFingerprint(kind, action)) {
      this.setPhase(kind, TogglePhase.VERIFYING);
      this.guardByFingerprint(action, () => {
        this.setPhase(kind, TogglePhase.PENDING);
        this.dispatchToggle(kind, action, prev);
      }, () => {
        // 指纹未通过：不发送指令，开关状态保持点击前
        this.setPhase(kind, prev);
      });
      return;
    }

    this.setPhase(kind, TogglePhase.PENDING);
    this.dispatchToggle(kind, action, prev);
  }

  /**
   * 下发开关指令并轮询确认车端状态。
   *
   * @param kind   开关语义类型
   * @param action 已确定的动作
   * @param prev   点击前的阶段，失败时回滚用
   */
  private async dispatchToggle(kind: ToggleKind, action: string, prev: TogglePhase): Promise<void> {
    const ctx = this.context;
    const client = this.repository?.getClient();
    const session = this.repository?.getSession();
    if (ctx === undefined || client === undefined || session === undefined) {
      this.errorMessage = '会话未就绪，请重试';
      this.setPhase(kind, prev);
      return;
    }

    try {
      const coordinator = new ControlCoordinator(ctx, session, client);
      await coordinator.execute(this.vin, action, (success: boolean, message: string) => {
        if (!success) {
          // 失败：回滚到点击前的状态，并把原因告诉用户
          this.setPhase(kind, prev);
          this.toast(message.length > 0 ? message : `${this.toggleLabel(kind)}指令下发失败`);
          Log.warn(`车控执行失败：${message}`);
          return;
        }
        // 指令已下发，状态待确认：由 confirmToggle 轮询车端后落定
        this.confirmToggle(kind, action, prev);
      });
    } catch (err) {
      const e = err as BusinessError;
      this.setPhase(kind, prev);
      Log.error(`车控执行异常: ${e.message}`);
    }
  }

  /**
   * 判断该动作是否需要指纹验证。
   *
   * 只覆盖「打开」方向的动作 —— 解锁、开窗会降低车辆的物理防护，
   * 上锁与关窗是恢复安全状态的方向，不需要额外门禁。
   *
   * @param kind   开关语义类型
   * @param action 已确定的动作
   */
  private requiresFingerprint(kind: ToggleKind, action: string): boolean {
    if (kind === ToggleKind.LOCK) {
      return action === VehicleCommands.ACTION_UNLOCK;
    }
    if (kind === ToggleKind.WINDOW) {
      return action === VehicleCommands.ACTION_WINDOWS_OPEN;
    }
    return false;
  }

  /**
   * 指纹门禁：通过则执行回调；不可用时降级为二次确认框。
   *
   * 降级策略与卡片车控一致（Android 原版 WidgetControlActivity.m485p）：
   * 说明指纹不可用的原因 + 列出将执行的操作，由用户确认后放行。
   *
   * @param action    将要执行的动作
   * @param onProceed 放行后执行
   * @param onReject  指纹未通过 / 用户取消时执行
   */
  private guardByFingerprint(action: string, onProceed: () => void, onReject: () => void): void {
    BiometricGuard.checkAvailable().then((capability: number) => {
      if (capability !== BiometricResult.SUCCESS) {
        this.confirmWithoutFingerprint(action, BiometricGuard.fallbackMessage(capability), onProceed, onReject);
        return;
      }
      BiometricGuard.verify(this.fingerprintTitle(action)).then((result: number) => {
        if (result !== BiometricResult.SUCCESS) {
          this.toast('未通过指纹验证，未发送车辆指令');
          onReject();
          return;
        }
        onProceed();
      });
    });
  }

  /**
   * 指纹验证弹窗标题。
   */
  private fingerprintTitle(action: string): string {
    if (action === VehicleCommands.ACTION_UNLOCK) {
      return '验证以解锁车辆';
    }
    if (action === VehicleCommands.ACTION_UNLOCK_TRUNK) {
      return '验证以解锁尾门';
    }
    return '验证以打开车窗';
  }

  /**
   * 指纹不可用时的降级确认框。
   *
   * @param action    将要执行的动作
   * @param reason    指纹不可用的原因
   * @param onProceed 用户确认后执行
   * @param onReject  用户取消时执行
   */
  private confirmWithoutFingerprint(action: string, reason: string,
    onProceed: () => void, onReject: () => void): void {
    this.getUIContext().showAlertDialog({
      title: '指纹验证不可用',
      message: `${reason}\n\n确认后将执行以下车辆操作：\n${this.actionLabel(action)}`,
      primaryButton: {
        value: '取消',
        action: () => {
          onReject();
        }
      },
      secondaryButton: {
        value: '确认并执行',
        fontColor: $r('app.color.app_polar'),
        action: () => {
          onProceed();
        }
      }
    });
  }

  /**
   * 动作的中文描述，用于确认框文案。
   */
  private actionLabel(action: string): string {
    if (action === VehicleCommands.ACTION_UNLOCK) {
      return '解锁车辆';
    }
    if (action === VehicleCommands.ACTION_UNLOCK_TRUNK) {
      return '解锁尾门';
    }
    if (action === VehicleCommands.ACTION_WINDOWS_OPEN) {
      return '打开全部车窗';
    }
    return action;
  }

  /**
   * 轮询车端状态直到确认指令生效。
   *
   * 对应 Android 端 m319Q 的判定：**按动作判定目标状态**，不是看当前状态。
   *   climate-start      → 状态须为「开启」
   *   climate-stop       → 状态须为「关闭」
   *   air-purification-* → 须为「开启 / 关闭」
   *   lock / unlock      → 须为「已锁 / 未锁」
   *   windows-*          → 须为「车窗已关闭 / 车窗未关闭」
   *
   * 关键：开启空调后车端在真正启动前，状态仍是「关闭」。若把「关闭」当终态
   * 立即落定，UI 就会立刻弹回关闭态 —— 这正是原版按动作判定的原因。
   *
   * 超过预算（12 秒）仍未确认，则按目标状态落定：指令确实已下发成功，
   * 只是车端还没推进到终态，不应把 UI 弹回原状态。
   */
  private async confirmToggle(kind: ToggleKind, action: string, prev: TogglePhase): Promise<void> {
    const budgetMs: number = 12000;
    const startedAt: number = Date.now();
    let interval: number = 300;
    const target: TogglePhase = prev === TogglePhase.ON ? TogglePhase.OFF : TogglePhase.ON;

    while (Date.now() - startedAt < budgetMs) {
      await this.delay(interval);
      interval = Math.min(1200, interval + 250);

      try {
        const current = await this.readToggleState(kind);
        if (current === undefined) {
          // 状态不可判定（如「处理中」），继续等
          continue;
        }
        if (current !== target) {
          // 还没到目标态（例：开启空调后车端仍返回「关闭」），继续等
          continue;
        }
        this.setPhase(kind, target);
        // 整车解锁会连带解锁尾门，但车端两个状态不一定同时推送，
        // 落定后再读一次 exterior 把尾门锁状态补齐。
        if (kind === ToggleKind.LOCK) {
          this.syncTrunkLock();
        } else if (kind === ToggleKind.WINDOW) {
          // 四扇窗可能不是同时落地的，落定时车模可能还停在中间状态。
          this.syncWindowStates();
        } else if (kind === ToggleKind.CLIMATE || kind === ToggleKind.PURIFIER) {
          // 空调 / 净化开启后要持续轮询，等车端到时自动关闭时回落按钮
          this.syncClimateTimer();
        }
        this.toast(`${this.toggleLabel(kind)}已${target === TogglePhase.ON ? '开启' : '关闭'}`);
        return;
      } catch (err) {
        // 单次读取失败不终止轮询
        Log.warn(`确认车控状态失败: ${(err as Error).message}`);
      }
    }

    // 超时未确认：按目标状态落定（指令已成功下发）
    Log.warn(`车控状态未在 ${budgetMs}ms 内确认，按下发结果落定: ${action}`);
    this.setPhase(kind, target);
    if (kind === ToggleKind.LOCK) {
      this.syncTrunkLock();
    } else if (kind === ToggleKind.WINDOW) {
      // 逐扇车窗状态可能已经更新过一轮，再读一次拿最新的。
      this.syncWindowStates();
    } else if (kind === ToggleKind.CLIMATE || kind === ToggleKind.PURIFIER) {
      this.syncClimateTimer();
    }
    this.toast(`${this.toggleLabel(kind)}指令已发送`);
  }

  /**
   * 单独读一次 exterior，把逐扇车窗 / 车门状态同步到车模。
   *
   * 车窗开合是四扇分别落地的，轮询确认到终态时车模可能还停留在
   * 中间状态（只开好后两扇），落定后再补一次读取。
   */
  private async syncWindowStates(): Promise<void> {
    const repository = this.repository;
    if (repository === undefined) {
      return;
    }
    try {
      const state = await repository.readDomain('exterior', this.vin);
      this.windowStates = state.windowStates;
      this.doorStates = state.doorStates;
    } catch (err) {
      Log.warn(`同步车窗状态失败: ${(err as Error).message}`);
    }
  }

  /**
   * 单独读一次 exterior，把尾门锁状态同步到车模标记点。
   *
   * 整车解锁 / 锁定会连带改变尾门锁，但车端不一定同时推送两个状态，
   * 需要额外读一次才能拿到准确的尾门锁状态。
   *
   * 同时同步整车锁：上锁尾门会把整车一并上锁，
   * 若不同步，整车锁快捷按钮会停在「未锁」的旧状态。
   */
  private async syncTrunkLock(): Promise<void> {
    const repository = this.repository;
    if (repository === undefined) {
      return;
    }
    try {
      const state = await repository.readDomain('exterior', this.vin);
      if (state.tailgateLock === '未锁') {
        this.trunkUnlocked = true;
      } else if (state.tailgateLock === '已锁') {
        this.trunkUnlocked = false;
      }
      // 尾门上锁会连带整车上锁，整车锁快捷按钮要跟着落定。
      // 只在状态明确时覆盖 —— 「未知」/「处理中」不改变现有相位。
      if (state.locked === '未锁') {
        this.lockPhase = TogglePhase.ON;
      } else if (state.locked === '已锁') {
        this.lockPhase = TogglePhase.OFF;
      }
      this.windowStates = state.windowStates;
      this.doorStates = state.doorStates;
      // 尾门状态变了，桌面卡片上的锁车文案也要跟着更新
      this.publishCard();
    } catch (err) {
      Log.warn(`同步尾门锁状态失败: ${(err as Error).message}`);
    }
  }

  /**
   * 读取某开关对应的车端当前状态，转成阶段。
   *
   * @returns 阶段；状态不可判定时返回 undefined
   */
  private async readToggleState(kind: ToggleKind): Promise<TogglePhase | undefined> {
    const repository = this.repository;
    if (repository === undefined) {
      return undefined;
    }

    if (kind === ToggleKind.CLIMATE) {
      const state = await repository.readDomain('climate', this.vin);
      // 顺带取回剩余运行分钟数 —— 据此推算预计结束时刻，
      // 把状态检查排在那一刻之前。
      this.climateRemainingMinutes = state.climateRuntimeMinutes ?? -1;
      if (state.climate === '开启') {
        return TogglePhase.ON;
      }
      if (state.climate === '关闭') {
        return TogglePhase.OFF;
      }
      // 「处理中」或「未知」——车端尚未推进到终态
      return undefined;
    }

    if (kind === ToggleKind.PURIFIER) {
      const state = await repository.readDomain('air', this.vin);
      this.airRemainingMinutes = state.airRuntimeMinutes ?? -1;
      if (state.air === '开启') {
        return TogglePhase.ON;
      }
      if (state.air === '关闭') {
        return TogglePhase.OFF;
      }
      return undefined;
    }

    const state = await repository.readDomain('exterior', this.vin);
    // 整车解锁 / 锁定会连带改变尾门锁状态，同步到车模的尾门标记点。
    // 尾门锁与车锁同在 exterior 域，一次读取即可拿到。
    if (state.tailgateLock === '未锁') {
      this.trunkUnlocked = true;
    } else if (state.tailgateLock === '已锁') {
      this.trunkUnlocked = false;
    }
    // 车窗开合后逐扇状态会变，同步到车模
    this.windowStates = state.windowStates;
    this.doorStates = state.doorStates;
    if (kind === ToggleKind.LOCK) {
      if (state.locked === '未锁') {
        return TogglePhase.ON;
      }
      if (state.locked === '已锁') {
        return TogglePhase.OFF;
      }
      return undefined;
    }
    // 车窗：逐扇判定，要求四扇全部到达目标状态才算生效。
    // 不能用 state.windows 汇总值 —— 它只要有一扇未关闭就算「未关闭」，
    // 车端只开好后两扇时就会提前判定成功，前窗随后才补上。
    const windowPhase = Index.windowPhaseOf(state.windowStates);
    if (windowPhase !== undefined) {
      return windowPhase;
    }
    return undefined;
  }

  /**
   * 由逐扇车窗状态推导开关阶段。
   *
   * 四扇全部未关闭 → 开启；四扇全部关闭 → 关闭；其余（部分开启 / 状态未知）
   * 返回 undefined，表示车端尚未推进到终态，继续等待。
   */
  private static windowPhaseOf(states: number[]): TogglePhase | undefined {
    if (states.length === 0) {
      return undefined;
    }
    let opened = 0;
    let closed = 0;
    for (const s of states) {
      if (s === 1 || s === 3) {
        opened++;
      } else if (s === 0) {
        closed++;
      }
    }
    if (opened === states.length) {
      return TogglePhase.ON;
    }
    if (closed === states.length) {
      return TogglePhase.OFF;
    }
    return undefined;
  }

  /**
   * 开关的功能名称，用于结果提示。
   */
  private toggleLabel(kind: ToggleKind): string {
    switch (kind) {
      case ToggleKind.LOCK:
        return '车锁';
      case ToggleKind.CLIMATE:
        return '驻车空调';
      case ToggleKind.PURIFIER:
        return '空气净化';
      case ToggleKind.WINDOW:
        return '车窗';
      default:
        return '车控';
    }
  }

  /**
   * 轻提示。
   */
  private toast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  /**
   * 延时。
   */
  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * 车模尾门热区：未解锁时下发解锁，已解锁时下发锁定。
   */
  private async toggleTrunk(): Promise<void> {
    if (this.trunkBusy || !this.controlPrerequisites()) {
      return;
    }

    const wasUnlocked = this.trunkUnlocked;
    const action = wasUnlocked ? VehicleCommands.ACTION_LOCK_TRUNK : VehicleCommands.ACTION_UNLOCK_TRUNK;

    // 尾门解锁同样是「打开」方向的高安全性操作，先过指纹门禁。
    if (action === VehicleCommands.ACTION_UNLOCK_TRUNK) {
      this.guardByFingerprint(action, () => {
        this.dispatchTrunk(action, wasUnlocked);
      }, () => {
        this.trunkUnlocked = wasUnlocked;
      });
      return;
    }

    this.dispatchTrunk(action, wasUnlocked);
  }

  /**
   * 下发尾门指令。
   *
   * @param action      已确定的动作
   * @param wasUnlocked 点击前的尾门锁状态，失败时回滚用
   */
  private async dispatchTrunk(action: string, wasUnlocked: boolean): Promise<void> {
    const ctx = this.context;
    const client = this.repository?.getClient();
    const session = this.repository?.getSession();
    if (ctx === undefined || client === undefined || session === undefined) {
      this.errorMessage = '会话未就绪，请重试';
      return;
    }
    this.trunkBusy = true;

    try {
      const coordinator = new ControlCoordinator(ctx, session, client);
      await coordinator.execute(this.vin, action, (success: boolean, message: string) => {
        this.trunkBusy = false;
        if (!success) {
          this.trunkUnlocked = wasUnlocked;
          Log.warn(`尾门控制失败：${message}`);
          return;
        }
        this.trunkUnlocked = !wasUnlocked;
        // 只读 exterior 域确认尾门锁状态，不做全量刷新 ——
        // 全量刷新会让右上角出现刷新动画，且多拉 5 个无关域。
        this.syncTrunkLock();
      });
    } catch (err) {
      const e = err as BusinessError;
      this.trunkBusy = false;
      this.trunkUnlocked = wasUnlocked;
      Log.error(`尾门控制异常: ${e.message}`);
    }
  }

  /**
   * 读取某开关的当前阶段。
   */
  private phaseOf(kind: ToggleKind): TogglePhase {
    switch (kind) {
      case ToggleKind.LOCK:
        return this.lockPhase;
      case ToggleKind.CLIMATE:
        return this.climatePhase;
      case ToggleKind.PURIFIER:
        return this.airPhase;
      case ToggleKind.WINDOW:
        return this.windowPhase;
      default:
        return TogglePhase.OFF;
    }
  }

  /**
   * 写入某开关的阶段。
   */
  private setPhase(kind: ToggleKind, phase: TogglePhase): void {
    switch (kind) {
      case ToggleKind.LOCK:
        this.lockPhase = phase;
        break;
      case ToggleKind.CLIMATE:
        this.climatePhase = phase;
        break;
      case ToggleKind.PURIFIER:
        this.airPhase = phase;
        break;
      case ToggleKind.WINDOW:
        this.windowPhase = phase;
        break;
      default:
        break;
    }
  }

  /**
   * 由开关当前阶段推导应当下发的动作。
   */
  private actionOf(kind: ToggleKind, current: TogglePhase): string {
    switch (kind) {
      case ToggleKind.LOCK:
        return current === TogglePhase.ON ? VehicleCommands.ACTION_LOCK : VehicleCommands.ACTION_UNLOCK;
      case ToggleKind.CLIMATE:
        return current === TogglePhase.ON ? VehicleCommands.ACTION_CLIMATE_STOP : VehicleCommands.ACTION_CLIMATE_START;
      case ToggleKind.PURIFIER:
        return current === TogglePhase.ON ? VehicleCommands.ACTION_AIR_STOP : VehicleCommands.ACTION_AIR_START;
      case ToggleKind.WINDOW:
        return current === TogglePhase.ON ? VehicleCommands.ACTION_WINDOWS_CLOSE : VehicleCommands.ACTION_WINDOWS_OPEN;
      default:
        return '';
    }
  }

  /**
   * 分节标签：标题 + 尾部发丝线（Nordic Instrument 的分节方式）。
   */
  @Builder
  sectionLabel(text: string) {
    Row({ space: 10 }) {
      Text(text)
        .fontSize(10)
        .fontColor($r('app.color.app_tertiary_text'))
      Column()
        .layoutWeight(1)
        .height(1)
        .backgroundColor($r('app.color.app_rule'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ top: 26, bottom: 10 })
  }

  /**
   * 底部导航项。
   */
  @Builder
  tabItem(index: number, icon: AppIconName, label: string) {
    Column({ space: 4 }) {
      AppIcon({ name: icon, iconSize: 19, color: this.currentTab === index
        ? $r('app.color.app_accent')
        : $r('app.color.app_tertiary_text') })
        .width(19)
        .height(19)
      Text(label)
        .fontSize(12)
        .fontColor(this.currentTab === index
          ? $r('app.color.app_accent')
          : $r('app.color.app_tertiary_text'))
    }
    .layoutWeight(1)
    .height(58)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.currentTab = index;
    })
  }

  build() {
    Column() {
      // ---------- 内容区：按 Tab 切换 ----------
      if (this.currentTab === 0) {
        Refresh({ refreshing: $$this.refreshing }) {
          Scroll() {
          // 区块间距由各区块的 margin 表达（space 设为 0）。
          // 里程区固定预留副信息行的一行高度，这行高度正好抵消
          // 顶栏到车模之间的间距，切换里程口径时车模位置不变。
          Column({ space: 0 }) {
            // ---------- 顶栏：车型 + 可切换里程 ----------
            Row() {
              Column() {
                Text(this.modelName)
                  .fontSize(23)
                  .fontWeight(FontWeight.Normal)
                  .fontColor($r('app.color.app_primary_text'))
                  .margin({ bottom: 5 })
                Row({ space: 6 }) {
                  Text(this.mileageLabel())
                    .fontSize(11)
                    .fontColor($r('app.color.app_tertiary_text'))
                  Text(this.mileageValue())
                    .fontSize(13)
                    .fontColor($r('app.color.app_primary_text'))
                  Text('km')
                    .fontSize(10.5)
                    .fontColor($r('app.color.app_tertiary_text'))
                }
                .onClick(() => {
                  this.flipMileage();
                })
                // 副信息行固定占一行高度，内容为空时也保留位置。
                // 里程区因此始终是两行的高度，切换口径时车模不会下移。
                // 宽度跟随内容，避免点击文案之外的空白也触发切换。
                Row() {
                  if (this.mileageNote().length > 0) {
                    Text(this.mileageNote())
                      .fontSize(10.5)
                      .fontColor($r('app.color.app_tertiary_text'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                }
                .height(14)
                .alignItems(VerticalAlign.Center)
                .margin({ top: 2 })
                // 副信息行同样可点，切换里程口径
                .onClick(() => {
                  this.flipMileage();
                })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              // 右上角：非下拉触发的刷新显示旋转指示器（无边框）；其余时间显示距上次刷新的时间。
              // 下拉刷新时顶部已有下拉指示器，不重复显示，但时间文案保持原样，
              // 等刷新结束后再更新。
              if (this.loading && !this.refreshing) {
                LoadingProgress()
                  .width(15)
                  .height(15)
                  .color($r('app.color.app_accent'))
              } else if (this.lastRefreshText.length > 0) {
                Text(this.lastRefreshText)
                  .fontSize(11)
                  .fontColor($r('app.color.app_tertiary_text'))
              }
            }
            .width('100%')
            // 顶栏底部不再额外留间距：副信息行（固定 14vp 高 + 2vp 上边距）
            // 已经撑出这一段，切换里程口径时车模位置始终不变。
            .margin({ top: 20, bottom: 0 })

            if (this.errorMessage.length > 0) {
              Text(this.errorMessage)
                .fontSize(13)
                .fontColor($r('app.color.app_error'))
                .width('100%')
                .padding(12)
                .backgroundColor($r('app.color.app_error_soft'))
                .borderRadius(4)
                .margin({ top: 16 })
            }

            // ---------- 车辆图示 + 右侧快捷开关 ----------
            Row({ space: 10 }) {
              VehiclePlan({
                windowStates: this.windowStates,
                doorStates: this.doorStates,
                hoodOpen: this.hoodOpen,
                portOpen: this.portOpen,
                charging: this.chargingMarked(),
                chargeColor: this.chargeMarkerColor(),
                chargePulsing: this.chargeMarkerPulsing(),
                trunkUnlocked: this.trunkUnlocked,
                trunkBusy: this.trunkBusy,
                onTrunkTap: () => {
                  this.toggleTrunk();
                }
              })

              Column({ space: 15 }) {
                StateToggle({
                  kind: ToggleKind.LOCK,
                  phase: this.lockPhase,
                  onTap: (kind: ToggleKind) => {
                    this.toggle(kind);
                  }
                })
                StateToggle({
                  kind: ToggleKind.CLIMATE,
                  phase: this.climatePhase,
                  // 空调与空气净化互斥：对方开启或执行中时本项置灰
                  disabled: this.airActive(),
                  onTap: (kind: ToggleKind) => {
                    this.toggle(kind);
                  }
                })
                StateToggle({
                  kind: ToggleKind.PURIFIER,
                  phase: this.airPhase,
                  // 空气净化与驻车空调互斥：对方开启或执行中时本项置灰
                  disabled: this.climateActive(),
                  onTap: (kind: ToggleKind) => {
                    this.toggle(kind);
                  }
                })
                StateToggle({
                  kind: ToggleKind.WINDOW,
                  phase: this.windowPhase,
                  onTap: (kind: ToggleKind) => {
                    this.toggle(kind);
                  }
                })
              }
              .justifyContent(FlexAlign.Center)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .margin({ top: 16 })

            // ---------- 车型信息 ----------
            Column({ space: 2 }) {
              Text(this.modelName)
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.app_primary_text'))
              Text(this.modelSubtitle())
                .fontSize(10)
                .fontColor($r('app.color.app_tertiary_text'))
            }
            .width('100%')
            .alignItems(HorizontalAlign.Center)
            .margin({ top: 16 })

            // ---------- 电量与续航 ----------
            Row() {
              Column({ space: 0 }) {
                // 「电量」标题行：充电相关时 inline 追加一句状态说明，
                // 放在标题后面而不是另起一行，行数不变，下方内容不会被顶下去。
                Row({ space: 6 }) {
                  Text('电量')
                    .fontSize(12)
                    .fontColor($r('app.color.app_tertiary_text'))
                  if (this.chargingMarked() || this.chargeStage() === ChargeStage.DISCHARGING) {
                    Text(this.chargeInlineText())
                      .fontSize(12)
                      .fontColor(this.chargeInlineColor())
                  }
                }
                .alignItems(VerticalAlign.Bottom)
                Row({ space: 2 }) {
                  Text(this.battery >= 0 ? `${this.battery}` : '—')
                    .fontSize(46)
                    .fontWeight(FontWeight.Normal)
                    .fontColor($r('app.color.app_primary_text'))
                  Text('%')
                    .fontSize(17)
                    .fontColor($r('app.color.app_tertiary_text'))
                }
                .alignItems(VerticalAlign.Bottom)
                .margin({ top: 9 })
                Text(`可用 ${this.usableKwh()}`)
                  .fontSize(12)
                  .fontColor($r('app.color.app_tertiary_text'))
                  .margin({ top: 7 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Column({ space: 0 }) {
                Text('预计续航')
                  .fontSize(12)
                  .fontColor($r('app.color.app_tertiary_text'))
                Row({ space: 2 }) {
                  Text(this.range >= 0 ? `${this.range}` : '—')
                    .fontSize(46)
                    .fontWeight(FontWeight.Normal)
                    .fontColor($r('app.color.app_primary_text'))
                  Text('km')
                    .fontSize(17)
                    .fontColor($r('app.color.app_tertiary_text'))
                }
                .alignItems(VerticalAlign.Bottom)
                .margin({ top: 9 })
                Text(`满电估算 ${this.fullRangeKm()}`)
                  .fontSize(12)
                  .fontColor($r('app.color.app_tertiary_text'))
                  .margin({ top: 7 })
              }
              .alignItems(HorizontalAlign.End)
              .layoutWeight(1)
              .padding({ left: 18 })
              .border({ width: { left: 1 }, color: $r('app.color.app_rule') })
            }
            .width('100%')
            .padding({ top: 16, bottom: 15 })
            .border({ width: { top: 1, bottom: 1 }, color: $r('app.color.app_rule') })
            .margin({ top: 16 })

            // ---------- 最后停车位置 ----------
            StateRow({
              icon: AppIconName.LOCATION,
              label: '最后停车位置',
              value: this.parkedTime,
              detail: this.parkedPlace.length > 0 ? this.parkedPlace : this.parkedCoordinate,
              showChevron: true,
              onTap: () => {
                this.openParkedMap();
              }
            })
            .margin({ top: 8, bottom: 10 })
          }
          .width('100%')
          .padding({ left: 18, right: 18 })
          }
          .width('100%')
          .layoutWeight(1)
        }
        .width('100%')
        .layoutWeight(1)
        .onRefreshing(() => {
          this.onPullRefresh();
        })
      } else if (this.currentTab === 1) {
        Control()
        .width('100%')
        .layoutWeight(1)
      } else {
        Detail()
        .width('100%')
        .layoutWeight(1)
      }

      // ---------- 底部导航 ----------
      Row() {
        this.tabItem(0, AppIconName.TAB_HOME, '概览')
        this.tabItem(1, AppIconName.TAB_CONTROL, '控制')
        this.tabItem(2, AppIconName.TAB_DETAIL, '详情')
      }
      .width('100%')
      .height(58)
      .backgroundColor($r('app.color.app_background'))
      .border({ width: { top: 1 }, color: $r('app.color.app_rule') })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
  }
}
