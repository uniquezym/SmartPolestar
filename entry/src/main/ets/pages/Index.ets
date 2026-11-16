import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { VehicleRepository } from '../core/vehicle/VehicleRepository';
import { ControlCoordinator } from '../core/vehicle/ControlCoordinator';
import { CampModeController } from '../core/vehicle/CampModeController';
import { BackgroundKeeper } from '../service/BackgroundKeeper';
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
import { StateDomain } from '../core/vehicle/VehicleStateStream';
import { BusinessError, Log } from '../common/Log';

/**
 * 状态行的片段类型，决定该片段的排版层级。
 *
 * 状态行原本是一整条同色同号的文本，用户必须逐字读才知道哪段是
 * 「什么状态」、哪段是「具体数据」。拆成片段后按层级分别排版：
 *
 *   label —— 状态词。13fp Medium，唯一用主题蓝的片段，一眼扫到。
 *   data  —— 辅助数据（功率、电流、AQI 等）。11fp 三级灰，退到背景。
 *   key   —— 关键数值（剩余时长等）。13fp 等宽主色，与顶部总里程同一套语言。
 *   sep   —— 分隔符。11fp 三级灰，弱化不抢视线。
 */
type StatusSegKind = 'label' | 'data' | 'key' | 'sep';

/**
 * 状态行的一个片段。
 */
interface StatusSegment {
  text: string;
  kind: StatusSegKind;
}

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
   * 车模下方信息区的固定高度（vp）。
   *
   * 这一块有两种形态：两行静态信息（车型名 + 副文本）与一行状态行。
   * 两者高度不同，按内容自适应的话，状态行出现 / 消失时整页会上下跳。
   * 取两行形态的高度作为固定值（16fp 主标题 + 10fp 副标题 + 2vp 间距 ≈ 40vp，
   * 留一点余量避免文字被裁），内容垂直居中，切换就看不出跳变。
   */
  private static readonly STATUS_AREA_HEIGHT: number = 42;

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
  /** 尾门开合阶段（已打开 / 已关闭）。 */
  @State trunkPhase: TogglePhase = TogglePhase.OFF;
  /** 尾门锁阶段（已锁 / 未锁）。 */
  @State trunkLockPhase: TogglePhase = TogglePhase.OFF;

  /** 露营模式阶段。 */
  @State campPhase: TogglePhase = TogglePhase.OFF;
  /** 露营模式运行时长（分钟）。 */
  @State campDurationMinutes: number = 60;
  /** 露营模式剩余时间（分钟），0 表示未开启。 */
  @State campRemainingMinutes: number = 0;
  /** 露营模式剩余时间占全程的比例（0 ~ 1）。 */
  @State campRemainingRatio: number = 0;
  /** AQI 指数，-1 表示未知。控制页空气净化卡片用。 */
  @State airQualityIndex: number = -1;
  /** PM2.5 浓度（μg/m³），-1 表示未知。控制页空气净化卡片用。 */
  @State pm25UgM3: number = -1;
  /** 逐项健康告警文案，为空表示没有异常。 */
  @State healthWarnings: string[] = [];
  /**
   * 驻车空调剩余分钟数（本地倒计时）。
   *
   * 车端只在状态推送里给剩余时长，推送间隔不固定，状态行的倒计时
   * 因此会「卡住」不往下走。这里按预计结束时刻本地推算，
   * 每 30 秒刷新一次，不依赖车端推送频率。
   * -1 表示不适用（没开或拿不到剩余时长）。
   */
  @State climateCountdownMinutes: number = -1;
  /** 空气净化剩余分钟数（本地倒计时），语义同climateCountdownMinutes。 */
  @State airCountdownMinutes: number = -1;
  /**
   * 露营模式是否正在关闭。
   *
   * 关闭过程中状态行不能先消失 —— 用户点了关闭、按钮已经在转圈，
   * 但「露营模式已开启 · 剩余 X」立刻不见，会让人以为已经关掉了。
   * 真正该消失的时机是车端确认关闭成功之后。
   */
  @State campClosing: boolean = false;
  /**
   * 驻车空调是否正在关闭。
   *
   * 与 campClosing 同理 —— 关闭过程中状态行要保留，
   * 等车端确认关闭后再撤掉。
   */
  @State climateClosing: boolean = false;
  /** 空气净化是否正在关闭。语义同 climateClosing。 */
  @State airClosing: boolean = false;

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

  /** 里程口径：0=总里程 1=自动小计 2=手动小计。切换顺序：总里程 → 自动小计 → 手动小计。 */
  @State mileageMode: number = 0;

  /** 当前 Tab：0=概览 1=控制 2=详情。 */
  @State currentTab: number = 0;

  private context: common.UIAbilityContext | undefined = undefined;
  private repository: VehicleRepository | undefined = undefined;
  /** 露营模式控制器 —— 负责时长档位、到期时刻与倒计时心跳。 */
  private campController: CampModeController | undefined = undefined;
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
  /** 连续多少次状态检查失败。失败时要退避，不能一直高频重试。 */
  private climateFailCount: number = 0;

  /**
   * 状态流是否已建立订阅。
   *
   * 为 true 表示长连接已挂上；各域是否已经能收到推送看下面的 primed 标记。
   */
  private streamActive: boolean = false;
  /**
   * 各域是否已收到过首帧。
   *
   * 收到首帧说明该域的整条链路（建连 → 鉴权 → 协议解析 → 推送）都通了，
   * 此时该域才可以停掉定时轮询。
   *
   * 必须按域分别记 —— 只收到里程推送不代表空调也会推，
   * 不能因此把空调的轮询也停掉。
   */
  private batteryPrimed: boolean = false;
  private climatePrimed: boolean = false;
  private airPrimed: boolean = false;
  private exteriorPrimed: boolean = false;
  /** 正在订阅的 VIN，用于判断是否需要重订阅。 */
  private streamVin: string = '';
  /**
   * 等待流式推送确认的开关。
   *
   * 非 undefined 表示有一个指令正在等推送确认，
   * 此时对应的开关相位不能被推送覆盖。
   */
  private pendingConfirmKind: ToggleKind | undefined = undefined;
  /** 等待确认的目标状态。 */
  private pendingConfirmTarget: TogglePhase = TogglePhase.OFF;

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.repository = new VehicleRepository(this.context);
    this.requestLocationPermission();
    // 露营模式状态从本地持久化恢复，不依赖网络
    this.initCampMode();
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
    // 状态行的空调 / 净化倒计时也跟着这个心跳走 ——
    // 车端推送间隔不固定，指望推送来递减会看到「倒计时卡住」。
    this.tickCountdowns();
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
    // 长连接在后台会被系统回收，切回前台要重新订阅
    this.stopVehicleStream();
  }

  /**
   * 页面销毁时清理定时器。
   */
  aboutToDisappear(): void {
    this.stopTextTimer();
    this.stopChargeTimer();
    this.stopClimateTimer();
    this.stopVehicleStream();
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
   *
   * 状态流可用时不轮询 —— 服务端会主动推电量变化。
   */
  private syncChargeTimer(): void {
    if (this.batteryPrimed) {
      this.stopChargeTimer();
      return;
    }
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

    // 锚点与倒计时先更新 —— 即使不再安排状态检查，
    // 状态行的倒计时也要跟着车端推送走。
    this.syncCountdownAnchors();
    this.tickCountdowns();

    if (!climateOn && !airOn) {
      this.stopClimateTimer();
      return;
    }

    // 空调与净化各自独立：某个域的流已通就不再查那个域。
    // 车端到时停机时服务端会主动推一帧，按钮自然回落。
    if ((!climateOn || this.climatePrimed) && (!airOn || this.airPrimed)) {
      this.clearClimateSchedule();
      return;
    }

    const now = Date.now();

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
    // 连续失败时退避 —— 鉴权失败或断网时若还按 15 秒一轮重试，
    // 等于对着故障接口高频空打，白白浪费请求也拖慢恢复。
    if (this.climateFailCount > 0) {
      const backoff = Math.min(
        Index.CLIMATE_CHECK_MAX_INTERVAL_MS,
        Index.CLIMATE_CHECK_OVERDUE_MS * Math.pow(2, this.climateFailCount - 1)
      );
      delay = Math.max(delay, backoff);
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
    // 只打印在跑的那一项 —— 车端在功能关闭时仍会返回上一次的剩余时长
    // （残留值），一起打印会让人误以为两项都在运行。
    const running = climateOn
      ? `空调=开启 剩余 ${this.climateRemainingMinutes} 分钟`
      : `净化=开启 剩余 ${this.airRemainingMinutes} 分钟`;
    Log.info(`空调/净化运行中：安排状态检查，${delay}ms 后（${running}）`);
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
    this.climateFailCount = 0;
    this.climateExpectedEnd = 0;
    this.airExpectedEnd = 0;
  }

  /**
   * 静默拉一次空调与空气净化状态。
   *
   * 只读**在跑的那一项**（空调与净化互斥），不触发整页刷新动效。
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
      // 空调与净化互斥运行，一次只可能有一项在跑 ——
      // 只读在跑的那一项，每次检查省掉一个请求。
      // 万一车端同时报两项在跑，也各自读一次，不能漏掉。
      if (this.climatePhase === TogglePhase.ON) {
        const climateState = await this.repository.readDomain('climate', this.vin);
        if (climateState.climate === '开启') {
          this.climatePhase = TogglePhase.ON;
        } else if (climateState.climate === '关闭') {
          this.climatePhase = TogglePhase.OFF;
          this.publishCard();
        }
        this.climateRemainingMinutes = climateState.climateRuntimeMinutes ?? -1;
        this.climate = climateState.climate;
      }
      if (this.airPhase === TogglePhase.ON) {
        const airState = await this.repository.readDomain('air', this.vin);
        if (airState.air === '开启') {
          this.airPhase = TogglePhase.ON;
        } else if (airState.air === '关闭') {
          this.airPhase = TogglePhase.OFF;
          this.publishCard();
        }
        this.airRemainingMinutes = airState.airRuntimeMinutes ?? -1;
        // 测量值缺失时沿用旧值，不清成未知
        if (airState.airQualityIndex !== undefined) {
          this.airQualityIndex = airState.airQualityIndex;
        }
        if (airState.pm25UgM3 !== undefined) {
          this.pm25UgM3 = airState.pm25UgM3;
        }
      }

      const now = Date.now();
      const stillOn = this.climatePhase === TogglePhase.ON || this.airPhase === TogglePhase.ON;

      // 读到了 —— 失败计数清零
      this.climateFailCount = 0;

      // 到了预计结束时刻仍报「开启」——车端没在倒计时（或用户手动续时），
      // 连续几次之后改用兜底间隔，避免高频空转。
      const pastDeadline = (this.climateExpectedEnd > 0 && this.climateExpectedEnd <= now) ||
        (this.airExpectedEnd > 0 && this.airExpectedEnd <= now);
      if (stillOn && pastDeadline) {
        this.climateEndgameCount++;
      } else {
        this.climateEndgameCount = 0;
      }
    } catch (err) {
      const e = err as BusinessError;
      this.climateFailCount++;
      Log.warn(`空调/净化状态检查失败（第 ${this.climateFailCount} 次）: code=${e.code} ${e.message}`);
    } finally {
      this.climatePolling = false;
      // 状态可能已变为关闭，据此重排下一次检查
      this.syncClimateTimer();
    }
  }

  /**
   * 更新空调 / 净化的预计结束时刻锚点。
   *
   * 锚点只在两种情况下重算：
   *   1. 刚刚转为开启 —— 建立锚点
   *   2. 剩余时长变长了 —— 用户在车端续了时
   * 其余情况一律沿用旧锚点。若每轮都用「当前剩余」重算，
   * 车端剩余值不递减时结束时刻会一直往后漂，永远等不到收尾。
   */
  private syncCountdownAnchors(): void {
    const now = Date.now();
    const climateOn = this.climatePhase === TogglePhase.ON;
    const airOn = this.airPhase === TogglePhase.ON;

    this.climateExpectedEnd = Index.refreshExpectedEnd(
      this.climateExpectedEnd, this.climateObservedRemaining,
      this.climateRemainingMinutes, climateOn, now);
    this.climateObservedRemaining = climateOn ? this.climateRemainingMinutes : -1;

    this.airExpectedEnd = Index.refreshExpectedEnd(
      this.airExpectedEnd, this.airObservedRemaining,
      this.airRemainingMinutes, airOn, now);
    this.airObservedRemaining = airOn ? this.airRemainingMinutes : -1;
  }

  /**
   * 按预计结束时刻本地推算剩余分钟数。
   *
   * 车端只在状态推送里给剩余时长，推送间隔不固定（有时几分钟才一帧），
   * 直接显示车端值会出现「倒计时卡住不动」。
   * 这里按锚点实时推算，30 秒刷新一次。
   *
   * 推不出锚点（车端没给剩余时长）时回落到车端值。
   */
  private tickCountdowns(): void {
    const now = Date.now();
    this.climateCountdownMinutes = this.countdownOf(
      this.climateExpectedEnd, this.climateRemainingMinutes,
      this.climatePhase === TogglePhase.ON, now);
    this.airCountdownMinutes = this.countdownOf(
      this.airExpectedEnd, this.airRemainingMinutes,
      this.airPhase === TogglePhase.ON, now);
  }

  /**
   * 计算一项的剩余分钟数。
   *
   * @param expectedEnd 预计结束时刻（epoch millis），0 表示未知
   * @param fallback   车端给的剩余分钟数，-1 表示未知
   * @param running   当前是否在运行
   * @param now       当前时刻
   * @returns 剩余分钟数，-1 表示拿不到
   */
  private countdownOf(expectedEnd: number, fallback: number,
    running: boolean, now: number): number {
    if (!running) {
      return -1;
    }
    if (expectedEnd > 0) {
      const left = expectedEnd - now;
      return left <= 0 ? 0 : Math.ceil(left / 60000);
    }
    return fallback;
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
   * 三件事：
   *   1. 重新读取会话（后台期间令牌可能过期）
   *   2. 重新订阅状态流（长连接在后台被回收）
   *   3. 距上次刷新超过阈值时才拉一次状态
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

    // 恢复订阅：页面隐藏时流已断开，这里重新挂上
    if (this.vin.length > 0) {
      await this.startVehicleStream(this.vin);
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
      // 快照拿到了就订阅状态流：之后车端变化由服务端主动推送
      await this.startVehicleStream(states[0].vin);
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

  // ---------- 服务端流式状态 ----------

  /**
   * 订阅车辆状态的流式推送。
   *
   * 对应原版 Android：每个状态服务挂一条 SERVER_STREAMING 长连接，
   * 服务端在车端状态变化时主动推一帧，页面立刻能感知。
   *
   * 订阅失败不影响页面 —— 快照已经拿到了，轮询兜底仍在。
   */
  private async startVehicleStream(vin: string): Promise<void> {
    const repository = this.repository;
    if (repository === undefined || vin.length === 0) {
      return;
    }
    if (this.streamActive && this.streamVin === vin) {
      return;
    }

    this.stopVehicleStream();

    try {
      await repository.startStream(vin, (domain: StateDomain, state: VehicleState) => {
        this.onStreamUpdate(domain, state);
      });
      this.streamActive = true;
      this.streamVin = vin;
      repository.onStreamBroken = (fullMethod: string, message: string): void => {
        Log.error(`状态流整体不可用，退回定时轮询: ${message}`);
        this.streamActive = false;
        // 推送链路已断，各域的首帧标记要一并清掉，
        // 否则轮询会因为「已就绪」而不启动。
        this.batteryPrimed = false;
        this.climatePrimed = false;
        this.airPrimed = false;
        this.exteriorPrimed = false;
        // 退回轮询兜底：空调 / 净化的状态检查要立刻恢复
        this.syncClimateTimer();
        this.syncChargeTimer();
      };
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`订阅状态流失败，继续用轮询兜底: ${e.message}`);
      this.streamActive = false;
    }
  }

  /**
   * 停止状态流订阅。
   */
  private stopVehicleStream(): void {
    const repository = this.repository;
    if (repository === undefined) {
      return;
    }
    repository.stopStream();
    repository.onStreamBroken = undefined;
    this.streamActive = false;
    this.batteryPrimed = false;
    this.climatePrimed = false;
    this.airPrimed = false;
    this.exteriorPrimed = false;
    this.streamVin = '';
  }

  /**
   * 收到一帧流式状态。
   *
   * RCP 的 IncomingDataCallback 不在 UI 线程，
   * 因此这里只把数据攒起来，切回 UI 线程后再更新 @State。
   */
  private onStreamUpdate(domain: StateDomain, state: VehicleState): void {
    const snapshot: VehicleState = this.copyState(state);
    setTimeout(() => {
      this.markStreamPrimed(domain);
      this.applyStreamState(domain, snapshot);
    }, 0);
  }

  /**
   * 标记某域已收到过首帧。
   *
   * 首帧到达即说明该域的推送链路已通，可以停掉该域的定时轮询。
   */
  private markStreamPrimed(domain: StateDomain): void {
    switch (domain) {
      case 'battery':
        this.batteryPrimed = true;
        this.syncChargeTimer();
        break;
      case 'climate':
        this.climatePrimed = true;
        this.syncClimateTimer();
        break;
      case 'air':
        this.airPrimed = true;
        this.syncClimateTimer();
        break;
      case 'exterior':
        this.exteriorPrimed = true;
        break;
      default:
        break;
    }
  }

  /**
   * 复制状态对象。
   *
   * 流式回调是异步触发的，直接读共享对象可能读到后续帧的内容，
   * 因此先做一份快照再切回 UI 线程。
   */
  private copyState(state: VehicleState): VehicleState {
    const copy = new VehicleState();
    copy.vin = state.vin;
    copy.modelName = state.modelName;
    copy.contentCodes = state.contentCodes;
    copy.batteryCapacityKwh = state.batteryCapacityKwh;
    copy.battery = state.battery;
    copy.range = state.range;
    copy.charging = state.charging;
    copy.chargerConnection = state.chargerConnection;
    copy.chargingType = state.chargingType;
    copy.powerWatts = state.powerWatts;
    copy.currentAmps = state.currentAmps;
    copy.timeToFullMinutes = state.timeToFullMinutes;
    copy.tripManualAverageEnergyKwhPer100Km = state.tripManualAverageEnergyKwhPer100Km;
    copy.tripAutomaticAverageEnergyKwhPer100Km = state.tripAutomaticAverageEnergyKwhPer100Km;
    copy.tripSinceChargeAverageEnergyKwhPer100Km = state.tripSinceChargeAverageEnergyKwhPer100Km;
    copy.tripManualEnergyWh = state.tripManualEnergyWh;
    copy.tripAutomaticEnergyWh = state.tripAutomaticEnergyWh;
    copy.tripSinceChargeEnergyWh = state.tripSinceChargeEnergyWh;
    copy.climate = state.climate;
    copy.climateRuntimeMinutes = state.climateRuntimeMinutes;
    copy.air = state.air;
    copy.airQualityIndex = state.airQualityIndex;
    copy.pm25UgM3 = state.pm25UgM3;
    copy.airRuntimeMinutes = state.airRuntimeMinutes;
    copy.locked = state.locked;
    copy.windows = state.windows;
    copy.tailgate = state.tailgate;
    copy.tailgateLock = state.tailgateLock;
    copy.hoodState = state.hoodState;
    copy.chargePortState = state.chargePortState;
    copy.doorStates = state.doorStates.slice();
    copy.windowStates = state.windowStates.slice();
    copy.odometerKm = state.odometerKm;
    copy.tripManualKm = state.tripManualKm;
    copy.tripAutomaticKm = state.tripAutomaticKm;
    copy.tripSinceChargeKm = state.tripSinceChargeKm;
    copy.manualAverageSpeedKph = state.manualAverageSpeedKph;
    copy.automaticAverageSpeedKph = state.automaticAverageSpeedKph;
    copy.sinceChargeAverageSpeedKph = state.sinceChargeAverageSpeedKph;
    copy.healthWarnings = state.healthWarnings.slice();
    return copy;
  }

  /**
   * 在 UI 线程上应用一帧流式状态。
   *
   * 按域只更新该域涉及的字段 —— 其余域的推送不该把别的域覆盖成旧值。
   */
  private applyStreamState(domain: StateDomain, state: VehicleState): void {
    switch (domain) {
      case 'battery':
        this.battery = state.battery ?? -1;
        this.range = state.range ?? -1;
        this.charging = state.charging;
        this.chargerConnection = state.chargerConnection;
        this.chargingType = state.chargingType;
        this.powerWatts = state.powerWatts ?? 0;
        this.currentAmps = state.currentAmps ?? 0;
        this.remainingMinutes = state.timeToFullMinutes ?? 0;
        this.manualAverageEnergyKwhPer100Km = state.tripManualAverageEnergyKwhPer100Km ?? -1;
        this.automaticAverageEnergyKwhPer100Km = state.tripAutomaticAverageEnergyKwhPer100Km ?? -1;
        this.sinceChargeAverageEnergyKwhPer100Km = state.tripSinceChargeAverageEnergyKwhPer100Km ?? -1;
        this.manualEnergyWh = state.tripManualEnergyWh ?? -1;
        this.automaticEnergyWh = state.tripAutomaticEnergyWh ?? -1;
        this.sinceChargeEnergyWh = state.tripSinceChargeEnergyWh ?? -1;
        this.syncChargeTimer();
        this.publishCard();
        break;
      case 'climate':
        this.climate = state.climate;
        this.climateRemainingMinutes = state.climateRuntimeMinutes ?? -1;
        this.applyStreamPhase(ToggleKind.CLIMATE, state.climate, '开启', '关闭');
        // 露营模式是靠驻车空调支撑的。空调在车端被关掉（用户手动关、
        // 或车端到时停机）后，露营模式的倒计时已经没有意义，
        // 这里只清本地状态，不再下发关闭指令。
        if (this.campPhase === TogglePhase.ON && state.climate === '关闭') {
          this.stopCampMode();
        }
        this.syncClimateTimer();
        this.publishCard();
        break;
      case 'air':
        // AQI / PM2.5 是测量值，车端可能某帧不带 —— 不带就沿用旧值，
        // 不能清成未知，否则空气质量信息会凭空消失。
        if (state.airQualityIndex !== undefined) {
          this.airQualityIndex = state.airQualityIndex;
        }
        if (state.pm25UgM3 !== undefined) {
          this.pm25UgM3 = state.pm25UgM3;
        }
        this.airRemainingMinutes = state.airRuntimeMinutes ?? -1;
        this.applyStreamPhase(ToggleKind.PURIFIER, state.air, '开启', '关闭');
        this.syncClimateTimer();
        break;
      case 'exterior':
        this.locked = state.locked;
        this.windows = state.windows;
        this.windowStates = state.windowStates;
        this.doorStates = state.doorStates;
        this.hoodOpen = state.hoodState === 1 || state.hoodState === 3;
        this.portOpen = state.chargePortState === 1 || state.chargePortState === 3;
        this.applyStreamPhase(ToggleKind.LOCK, state.locked, '未锁', '已锁');
        this.applyStreamWindowPhase(state.windowStates, state.windows);
        if (state.tailgateLock === '未锁') {
          this.trunkUnlocked = true;
        } else if (state.tailgateLock === '已锁') {
          this.trunkUnlocked = false;
        }
        this.applyStreamPhase(ToggleKind.TRUNK_LOCK, state.tailgateLock, '未锁', '已锁');
        this.applyStreamPhase(ToggleKind.TRUNK, state.tailgate, '已打开', '已关闭');
        this.publishCard();
        break;
      case 'odometer':
        this.odometerKm = state.odometerKm ?? -1;
        this.tripManualKm = state.tripManualKm ?? -1;
        this.tripAutomaticKm = state.tripAutomaticKm ?? -1;
        this.tripSinceChargeKm = state.tripSinceChargeKm ?? -1;
        this.manualAverageSpeedKph = state.manualAverageSpeedKph ?? -1;
        this.automaticAverageSpeedKph = state.automaticAverageSpeedKph ?? -1;
        this.sinceChargeAverageSpeedKph = state.sinceChargeAverageSpeedKph ?? -1;
        break;
      case 'health':
        this.healthWarnings = state.healthWarnings.slice();
        break;
      default:
        break;
    }
  }

  /**
   * 用逐扇车窗状态更新车窗快捷键的相位。
   *
   * 两种情形分开处理：
   *
   *   用户点了车窗快捷键 → 要求四扇状态一致才落定。
   *     车端是逐扇推进的（后窗先到位、前窗后到位），
   *     只到两扇就落定会让快捷键比实际状态早一步，
   *     与用户「四扇都开好了」的预期不符。
   *
   *   被动收到推送（用户在车端手动开了一扇窗）→ 沿用聚合值，
   *     有一扇没关严就显示「车窗开」，让用户立刻看到变化。
   *
   * @param states  逐扇车窗状态，顺序：0=左前 1=右前 2=左后 3=右后
   * @param summary 聚合状态文案（车窗未关闭 / 车窗已关闭）
   */
  private applyStreamWindowPhase(states: number[], summary: string): void {
    // 用户点了车窗快捷键：等四扇一致
    if (this.pendingConfirmKind === ToggleKind.WINDOW) {
      const phase = Index.windowPhaseOf(states);
      if (phase === undefined) {
        // 四扇还没到齐 —— 保持现状，等下一帧
        return;
      }
      this.applyStreamPhase(ToggleKind.WINDOW,
        phase === TogglePhase.ON ? '车窗未关闭' : '车窗已关闭',
        '车窗未关闭', '车窗已关闭');
      return;
    }

    // 被动推送：沿用聚合值
    this.applyStreamPhase(ToggleKind.WINDOW, summary, '车窗未关闭', '车窗已关闭');
  }

  /**
   * 用流式推送的车端状态更新开关相位。
   *
   * 验证中不覆盖 —— 指纹还没过，指令尚未下发，此时推来的必然是旧值。
   *
   * **执行中要专门处理**：执行中正是「等推送确认」的状态，
   * 推送到达说明车端已经推进到终态，这时恰恰要落定。
   * 若在这里按「执行中一律不覆盖」短路，推送会被丢掉，
   * 按钮只能等预算耗尽才强行落定 —— 表现就是车模已经变了、
   * 快捷键却还在转圈好几秒。
   *
   * @param kind    开关语义类型
   * @param actual  车端当前状态文案
   * @param onText  「开启」对应的状态文案
   * @param offText 「关闭」对应的状态文案
   */
  private applyStreamPhase(kind: ToggleKind, actual: string,
    onText: string, offText: string): void {
    const current = this.phaseOf(kind);
    if (current === TogglePhase.VERIFYING) {
      return;
    }

    const reached: boolean = actual === onText
      ? this.pendingConfirmTarget === TogglePhase.ON
      : (actual === offText && this.pendingConfirmTarget === TogglePhase.OFF);

    // 正在等这个开关的推送确认
    if (this.pendingConfirmKind === kind) {
      if (reached) {
        this.pendingConfirmKind = undefined;
        this.settleToggle(kind, this.pendingConfirmTarget);
        this.toast(`${this.toggleLabel(kind)}已${this.pendingConfirmTarget === TogglePhase.ON ? '开启' : '关闭'}`);
      }
      return;
    }

    // 执行中但没有在等确认 —— 指令执行中推送来的多半还是旧值，忽略。
    if (current === TogglePhase.PENDING) {
      return;
    }

    if (actual === onText) {
      this.setPhase(kind, TogglePhase.ON);
    } else if (actual === offText) {
      this.setPhase(kind, TogglePhase.OFF);
      // 被动收到「已关闭」的推送（用户在车端手动关）——
      // 这时也要撤掉「正在关闭」标记，否则状态行会一直挂着。
      this.clearClosing(kind);
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
    // 车窗：逐扇判定，与流式路径同一套规则 ——
    // 四扇一致才给结论，避免部分开启时快捷键提前跳变。
    const windowPhase = Index.windowPhaseOf(state.windowStates);
    if (windowPhase !== undefined) {
      this.windowPhase = windowPhase;
    }

    // 车模标记点：尾门锁、机盖、充电口。判定对齐原版 g10（1 或 3 视为开启）。
    if (state.tailgateLock === '未锁') {
      this.trunkUnlocked = true;
      this.trunkLockPhase = TogglePhase.ON;
    } else if (state.tailgateLock === '已锁') {
      this.trunkUnlocked = false;
      this.trunkLockPhase = TogglePhase.OFF;
    }
    // 尾门开合：field 12 枚举，'已打开' 表示尾门处于打开状态。
    if (state.tailgate === '已打开') {
      this.trunkPhase = TogglePhase.ON;
    } else if (state.tailgate === '已关闭') {
      this.trunkPhase = TogglePhase.OFF;
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
    // AQI / PM2.5 缺失时沿用旧值（快照路径也可能是残缺响应）
    if (state.airQualityIndex !== undefined) {
      this.airQualityIndex = state.airQualityIndex;
    }
    if (state.pm25UgM3 !== undefined) {
      this.pm25UgM3 = state.pm25UgM3;
    }
    this.syncClimateTimer();

    // 健康告警：状态行最高优先级。
    this.healthWarnings = state.healthWarnings.slice();
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
      return `${this.remainingMinutes} 分钟`;
    }
    const h = Math.floor(this.remainingMinutes / 60);
    const m = this.remainingMinutes % 60;
    if (m === 0) {
      return `${h} 小时`;
    }
    return `${h} 小时 ${m} 分`;
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

  // ---------- 车模下方状态行 ----------

  /**
   * 状态行的级别，决定配色。
   *
   * 0 = 无状态（回落车型副文本）
   * 1 = 正常运行中（充电 / 露营 / 空调 / 净化）—— 品牌蓝
   * 2 = 需要关注（充电故障）—— 错误色
   * 3 = 车辆异常（健康告警）—— 警示色
   */
  private statusLevel(): number {
    // 异常优先级最高 —— 异常需要用户立即处理，不能被充电信息盖住。
    if (this.healthWarnings.length > 0) {
      return 3;
    }
    const stage = this.chargeStage();
    if (stage === ChargeStage.FAULT) {
      return 2;
    }
    if (stage !== ChargeStage.IDLE && stage !== ChargeStage.DISCHARGING) {
      return 1;
    }
    if (this.sessionSegments().length > 0) {
      return 1;
    }
    return 0;
  }

  /**
   * 状态行片段。
   *
   * 空数组表示没有需要显示的状态 —— 此时回落到车型副文本。
   */
  private statusSegments(): StatusSegment[] {
    const level = this.statusLevel();
    if (level === 3) {
      return this.healthSegments();
    }
    if (level === 2) {
      return [{
        text: this.chargerConnection === '连接故障' ? '充电连接故障' : '充电错误',
        kind: 'label'
      }];
    }
    if (level === 1) {
      const stage = this.chargeStage();
      if (stage !== ChargeStage.IDLE && stage !== ChargeStage.DISCHARGING) {
        return this.chargeSegments();
      }
      return this.sessionSegments();
    }
    return [];
  }

  /**
   * 拼接片段，中间插入分隔符。
   *
   * 分隔符本身也是一个片段（kind = sep），这样它能跟其它片段一样
   * 被 Row 依次渲染，不必在布局里做特殊判断。
   */
  private joinSegments(parts: StatusSegment[]): StatusSegment[] {
    const result: StatusSegment[] = [];
    for (const part of parts) {
      if (part.text.length === 0) {
        continue;
      }
      if (result.length > 0) {
        result.push({ text: '·', kind: 'sep' });
      }
      result.push(part);
    }
    return result;
  }

  /**
   * 充电状态的片段。
   *
   * 充电中给完整的功率 / 电流 / 剩余时间，
   * 其余阶段给一句话概括。
   */
  private chargeSegments(): StatusSegment[] {
    const stage = this.chargeStage();
    if (stage === ChargeStage.COMPLETED) {
      return [{ text: '充电已完成', kind: 'label' }];
    }
    if (stage === ChargeStage.PAUSED) {
      return [{ text: '充电已暂停', kind: 'label' }];
    }
    if (stage === ChargeStage.PLUGGED) {
      return [{ text: '充电枪已连接', kind: 'label' }];
    }
    // 充电中：功率 · 电流 · 充满剩余时间
    const parts: StatusSegment[] = [{ text: '充电中', kind: 'label' }];
    const power = this.powerText();
    if (power.length > 0) {
      parts.push({ text: power, kind: 'data' });
    }
    const current = this.currentText();
    if (current.length > 0) {
      parts.push({ text: current, kind: 'data' });
    }
    const remaining = this.remainingTimeText();
    if (remaining.length > 0) {
      parts.push({ text: '剩余', kind: 'data' });
      parts.push({ text: remaining, kind: 'key' });
    }
    return this.joinSegments(parts);
  }

  /**
   * 会话中功能的状态片段。
   *
   * 露营模式与驻车空调本质是同一件事 —— 露营模式开着时空调必然在跑，
   * 所以两者合并成一条，露营模式优先（它多了倒计时信息）。
   * 空调与空气净化互斥，不会同时出现。
   *
   * 关闭过程中（closing 标记为 true）保留原有文案，
   * 只是把措辞改成「正在关闭」——
   * 状态行在指令执行完之前不能消失，否则用户会以为已经关掉了。
   */
  private sessionSegments(): StatusSegment[] {
    if (this.campPhase === TogglePhase.ON || this.campClosing) {
      if (this.campClosing) {
        return [{ text: '露营模式正在关闭…', kind: 'label' }];
      }
      const parts: StatusSegment[] = [{ text: '露营模式已开启', kind: 'label' }];
      const remaining = this.campRemainingMinutes;
      if (remaining > 0) {
        parts.push({ text: '剩余', kind: 'data' });
        parts.push({ text: this.campDurationText(remaining), kind: 'key' });
      }
      return this.joinSegments(parts);
    }
    if (this.climatePhase === TogglePhase.ON || this.climateClosing) {
      if (this.climateClosing) {
        return [{ text: '驻车空调正在关闭…', kind: 'label' }];
      }
      const parts: StatusSegment[] = [{ text: '驻车空调运行中', kind: 'label' }];
      const remaining = this.climateCountdownMinutes;
      if (remaining > 0) {
        parts.push({ text: '剩余', kind: 'data' });
        parts.push({ text: this.campDurationText(remaining), kind: 'key' });
      }
      return this.joinSegments(parts);
    }
    if (this.airPhase === TogglePhase.ON || this.airClosing) {
      if (this.airClosing) {
        return [{ text: '空气净化正在关闭…', kind: 'label' }];
      }
      const parts: StatusSegment[] = [{ text: '空气净化运行中', kind: 'label' }];
      const remaining = this.airCountdownMinutes;
      if (remaining > 0) {
        parts.push({ text: '剩余', kind: 'data' });
        parts.push({ text: this.campDurationText(remaining), kind: 'key' });
      }
      if (this.airQualityIndex >= 0) {
        parts.push({ text: 'AQI', kind: 'data' });
        parts.push({ text: `${this.airQualityIndex}`, kind: 'key' });
      }
      if (this.pm25UgM3 >= 0) {
        parts.push({ text: 'PM2.5', kind: 'data' });
        parts.push({ text: this.pm25UgM3.toFixed(1), kind: 'key' });
      }
      return this.joinSegments(parts);
    }
    return [];
  }

  /**
   * 分钟数转成「X 小时 Y 分」文案。
   */
  private campDurationText(minutes: number): string {
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    if (h === 0) {
      return `${m} 分钟`;
    }
    return m === 0 ? `${h} 小时` : `${h} 小时 ${m} 分`;
  }

  /**
   * 健康告警的片段。
   *
   * 只显示第一条 + 其余项计数 —— 平铺会让这一行变成一堵墙，
   * 用户反而看不出重点。告警列表已按安全性排序，第一条即最需要处理的。
   */
  private healthSegments(): StatusSegment[] {
    if (this.healthWarnings.length === 0) {
      return [];
    }
    const first = this.healthWarnings[0];
    const rest = this.healthWarnings.length - 1;
    const parts: StatusSegment[] = [{ text: first, kind: 'label' }];
    if (rest > 0) {
      parts.push({ text: `另有 ${rest} 项异常`, kind: 'data' });
    }
    return this.joinSegments(parts);
  }

  /**
   * 状态词的颜色。
   */
  private statusLabelColor(): ResourceColor {
    const level = this.statusLevel();
    if (level === 3) {
      return $r('app.color.app_warn');
    }
    if (level === 2) {
      return $r('app.color.app_error');
    }
    if (level === 1) {
      return $r('app.color.app_accent_text');
    }
    return $r('app.color.app_tertiary_text');
  }

  /**
   * 是否需要显示异常前置图标。
   */
  private statusShowWarningIcon(): boolean {
    return this.statusLevel() === 3;
  }

  /**
   * 当前里程口径的数值与标签。
   */
  private mileageValue(): string {
    let value = this.odometerKm;
    if (this.mileageMode === 1) {
      value = this.tripAutomaticKm;
    } else if (this.mileageMode === 2) {
      value = this.tripManualKm;
    }
    if (value < 0) {
      return '—';
    }
    return Math.round(value).toLocaleString();
  }

  private mileageLabel(): string {
    if (this.mileageMode === 1) {
      return '自动小计';
    }
    if (this.mileageMode === 2) {
      return '手动小计';
    }
    return '总里程';
  }

  /**
   * 当前口径的平均车速（km/h）。
   */
  private mileageAverageSpeed(): number {
    if (this.mileageMode === 1) {
      return this.automaticAverageSpeedKph;
    }
    if (this.mileageMode === 2) {
      return this.manualAverageSpeedKph;
    }
    return -1;
  }

  /**
   * 当前口径的平均能耗（kWh/100km）。
   */
  private mileageAverageEnergy(): number {
    if (this.mileageMode === 1) {
      return this.automaticAverageEnergyKwhPer100Km;
    }
    if (this.mileageMode === 2) {
      return this.manualAverageEnergyKwhPer100Km;
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
      distance = this.tripAutomaticKm;
    } else if (this.mileageMode === 2) {
      distance = this.tripManualKm;
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

  // ---------- 露营模式 ----------

  /**
   * 初始化露营模式：恢复持久化的时长与到期时刻。
   *
   * 应用被杀掉重开后，若到期时刻仍在未来，认为露营模式仍在运行，
   * 重新排程到期定时器并继续倒计时。
   */
  private async initCampMode(): Promise<void> {
    const ctx = this.context;
    if (ctx === undefined) {
      return;
    }
    const controller = new CampModeController(
      () => {
        this.onCampExpired();
      },
      () => {
        this.refreshCampRemaining();
      }
    );
    this.campController = controller;
    const duration = await controller.attach(ctx);
    this.campDurationMinutes = duration;
    if (controller.isActive()) {
      this.campPhase = TogglePhase.ON;
      controller.resume();
      this.refreshCampRemaining();
    }
  }

  /**
   * 刷新剩余时间与进度条比例。
   */
  private refreshCampRemaining(): void {
    const controller = this.campController;
    if (controller === undefined) {
      return;
    }
    this.campRemainingMinutes = controller.remainingMinutes();
    this.campRemainingRatio = controller.remainingRatio();
  }

  /**
   * 下发一条车控指令。
   *
   * @returns 是否下发成功
   */
  private async executeAction(action: string): Promise<boolean> {
    const ctx = this.context;
    const client = this.repository?.getClient();
    const session = this.repository?.getSession();
    if (ctx === undefined || client === undefined || session === undefined) {
      this.errorMessage = '会话未就绪，请重试';
      return false;
    }
    return await new Promise<boolean>((resolve: (result: boolean) => void) => {
      const coordinator = new ControlCoordinator(ctx, session, client);
      coordinator.execute(this.vin, action, (success: boolean, message: string) => {
        if (!success) {
          this.toast(message.length > 0 ? message : '指令下发失败');
          resolve(false);
          return;
        }
        resolve(true);
      });
    });
  }

  /**
   * 露营模式开关。
   *
   * 开启 = 下发驻车空调启动 + 记录到期时刻；
   * 关闭 = 下发驻车空调停止 + 清除到期时刻。
   */
  private async toggleCamp(): Promise<void> {
    if (!this.controlPrerequisites()) {
      return;
    }
    const controller = this.campController;
    if (controller === undefined) {
      this.errorMessage = '会话未就绪，请重试';
      return;
    }

    // 关闭路径
    if (this.campPhase === TogglePhase.ON) {
      this.campPhase = TogglePhase.PENDING;
      // 空调按钮同时进入执行中 —— 概览页的空调快捷键就是关闭露营模式的入口，
      // 不给执行反馈会让人以为没点中。
      this.climatePhase = TogglePhase.PENDING;
      // 状态行在指令确认前保留 —— 相位已经是 PENDING，
      // 若不看这个标记，「露营模式已开启 · 剩余 X」会立刻消失。
      this.campClosing = true;
      this.climateClosing = true;
      const success = await this.executeAction(VehicleCommands.ACTION_CLIMATE_STOP);
      if (!success) {
        this.campPhase = TogglePhase.ON;
        this.climatePhase = TogglePhase.ON;
        this.campClosing = false;
        this.climateClosing = false;
        return;
      }
      await controller.stop();
      this.campPhase = TogglePhase.OFF;
      this.campRemainingMinutes = 0;
      this.campRemainingRatio = 0;
      this.climatePhase = TogglePhase.OFF;
      this.campClosing = false;
      this.climateClosing = false;
      this.toast('露营模式已关闭');
      return;
    }

    // 开启路径：空调与净化互斥，净化在跑时不能开露营模式
    if (this.airActive()) {
      this.toast('空气净化运行中，无法开启露营模式');
      return;
    }

    this.campPhase = TogglePhase.PENDING;
    const success = await this.executeAction(VehicleCommands.ACTION_CLIMATE_START);
    if (!success) {
      this.campPhase = TogglePhase.OFF;
      return;
    }
    await controller.start(this.campDurationMinutes);
    this.campPhase = TogglePhase.ON;
    this.climatePhase = TogglePhase.ON;
    this.refreshCampRemaining();
    // 退到后台仍需到期自动关闭，申请长时任务
    await BackgroundKeeper.start(this.context as common.UIAbilityContext);
    this.toast('露营模式已开启');
  }

  /**
   * 露营模式到期：关闭驻车空调，净化若在跑则一并关闭。
   */
  private async onCampExpired(): Promise<void> {
    this.campPhase = TogglePhase.OFF;
    this.campRemainingMinutes = 0;
    this.campRemainingRatio = 0;
    this.climatePhase = TogglePhase.OFF;
    this.campClosing = false;
    this.climateClosing = false;
    await this.executeAction(VehicleCommands.ACTION_CLIMATE_STOP);
    if (this.airActive()) {
      await this.executeAction(VehicleCommands.ACTION_AIR_STOP);
      this.airPhase = TogglePhase.OFF;
      this.airClosing = false;
    }
    this.toast('露营模式已到时，驻车空调已关闭');
  }

  /**
   * 结束露营模式（只清本地状态，不再下发指令）。
   *
   * 用于「空调被别处关掉」的场景：指令已经下过了，这里只清理倒计时。
   */
  private async stopCampMode(): Promise<void> {
    const controller = this.campController;
    if (controller === undefined) {
      return;
    }
    await controller.stop();
    this.campPhase = TogglePhase.OFF;
    this.campRemainingMinutes = 0;
    this.campRemainingRatio = 0;
    this.campClosing = false;
  }

  /**
   * 概览页空调快捷键的点击处理。
   *
   * 露营模式开着时，空调快捷键直接用来「关闭露营模式」——
   * 露营模式是靠驻车空调支撑的，把空调关掉就等于结束守护，
   * 没有必要再让用户去控制页的露营卡片里关一次。
   *
   * 露营模式没开时，走普通的空调开关逻辑。
   */
  private onClimateShortcutTap(): void {
    if (this.campPhase === TogglePhase.ON) {
      this.toggleCamp();
      return;
    }
    this.toggle(ToggleKind.CLIMATE);
  }

  /**
   * 调节露营模式运行时长。
   *
   * 未运行时只改档位并持久化；运行中滑块已置灰，不会走到这里。
   */
  private async changeCampDuration(minutes: number): Promise<void> {
    this.campDurationMinutes = minutes;
    const controller = this.campController;
    if (controller === undefined) {
      return;
    }
    await controller.saveDuration(minutes);
  }

  /**
   * 下发寻车指令（鸣笛 / 闪灯 / 鸣笛并闪灯）。
   *
   * 这三个动作没有可回读的状态，下发成功即提示用户，不做轮询确认。
   *
   * @param action 动作标识（honk / flash / honk-flash）
   */
  private async honkFlash(action: string): Promise<void> {
    if (!this.controlPrerequisites()) {
      return;
    }
    const success = await this.executeAction(action);
    if (!success) {
      return;
    }
    this.toast(`${VehicleCommands.label(action)}指令已发送`);
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

    // 目标状态：点击前的状态取反
    const target: TogglePhase = prev === TogglePhase.ON ? TogglePhase.OFF : TogglePhase.ON;

    // **先挂起推送确认，再下发指令**。
    //
    // 指令下发是异步的（token 续期 + 指令调用），车端响应完全可能
    // 早于该调用返回。若等到下发成功才挂起确认，推送就会落在
    // 「已下发但还没开始等确认」的窗口里被丢掉 ——
    // 车模已经变了，按钮却要等 12 秒预算耗尽才落定。
    this.pendingConfirmKind = kind;
    this.pendingConfirmTarget = target;

    // 关闭方向：挂「正在关闭」标记。
    //
    // 指令执行期间按钮会进入 PENDING，相位从 ON 变成 PENDING，
    // 状态行若只看 ON 就会立刻消失 —— 用户点了关闭、按钮在转圈，
    // 但「剩余 58 分钟」不见了，看起来像是被清空了。
    // 挂上标记后，状态行在车端确认关闭之前一直保留。
    if (target === TogglePhase.OFF) {
      if (kind === ToggleKind.CLIMATE) {
        this.climateClosing = true;
      } else if (kind === ToggleKind.PURIFIER) {
        this.airClosing = true;
      }
    }

    // 高安全性操作（整车解锁、开窗）先过指纹门禁，再下发指令。
    // 验证期间用「验证中」态提示用户点了哪个按钮，
    // 但不显示执行动画 —— 指令尚未下发，不能让用户以为已经在执行。
    if (this.requiresFingerprint(kind, action)) {
      this.setPhase(kind, TogglePhase.VERIFYING);
      this.guardByFingerprint(action, () => {
        this.setPhase(kind, TogglePhase.PENDING);
        this.dispatchToggle(kind, action, prev, target);
      }, () => {
        // 指纹未通过：不发送指令，开关状态保持点击前
        this.pendingConfirmKind = undefined;
        this.setPhase(kind, prev);
      });
      return;
    }

    this.setPhase(kind, TogglePhase.PENDING);
    this.dispatchToggle(kind, action, prev, target);
  }

  /**
   * 下发开关指令并等车端状态确认后落定。
   *
   * @param kind   开关语义类型
   * @param action 已确定的动作
   * @param prev   点击前的阶段，失败时回滚用
   * @param target 目标状态
   */
  private async dispatchToggle(kind: ToggleKind, action: string, prev: TogglePhase,
    target: TogglePhase): Promise<void> {
    const ctx = this.context;
    const client = this.repository?.getClient();
    const session = this.repository?.getSession();
    if (ctx === undefined || client === undefined || session === undefined) {
      this.errorMessage = '会话未就绪，请重试';
      this.pendingConfirmKind = undefined;
      this.setPhase(kind, prev);
      return;
    }

    try {
      const coordinator = new ControlCoordinator(ctx, session, client);
      await coordinator.execute(this.vin, action, (success: boolean, message: string) => {
        if (!success) {
          // 失败：回滚到点击前的状态，并把原因告诉用户
          this.pendingConfirmKind = undefined;
          this.clearClosing(kind);
          this.setPhase(kind, prev);
          this.toast(message.length > 0 ? message : `${this.toggleLabel(kind)}指令下发失败`);
          Log.warn(`车控执行失败：${message}`);
          return;
        }
        // 指令已下发，状态待确认：由 confirmToggle 等车端状态确认后落定
        this.confirmToggle(kind, target);
        // 从概览页关掉驻车空调，等同于结束露营模式 ——
        // 露营模式是靠空调在跑支撑的，空调没了倒计时就没有意义了。
        if (kind === ToggleKind.CLIMATE && action === VehicleCommands.ACTION_CLIMATE_STOP &&
          this.campPhase === TogglePhase.ON) {
          this.stopCampMode();
        }
      });
    } catch (err) {
      const e = err as BusinessError;
      this.pendingConfirmKind = undefined;
      this.clearClosing(kind);
      this.setPhase(kind, prev);
      Log.error(`车控执行异常: ${e.message}`);
    }
  }

  /**
   * 清掉「正在关闭」标记。
   *
   * 只在明确知道结果时调用：指令下发失败（回滚）或车端确认关闭成功。
   */
  private clearClosing(kind: ToggleKind): void {
    if (kind === ToggleKind.CLIMATE) {
      this.climateClosing = false;
    } else if (kind === ToggleKind.PURIFIER) {
      this.airClosing = false;
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
    // 尾门开合与尾门解锁都是「打开」方向，降低了车辆的物理防护，
    // 与整车解锁同级，需要指纹门禁。
    if (kind === ToggleKind.TRUNK) {
      return action === VehicleCommands.ACTION_TRUNK_OPEN;
    }
    if (kind === ToggleKind.TRUNK_LOCK) {
      return action === VehicleCommands.ACTION_UNLOCK_TRUNK;
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
   * 状态流可用时改用流来确认 —— 服务端会在车端状态变化时推一帧，
   * 比轮询更快，也不会出现「轮询读到的旧值」与「流推来的新值」互相打架。
   *
   * 超过预算（12 秒）仍未确认，则按目标状态落定：指令确实已下发成功，
   * 只是车端还没推进到终态，不应把 UI 弹回原状态。
   */
  private async confirmToggle(kind: ToggleKind, target: TogglePhase): Promise<void> {
    const budgetMs: number = 12000;

    // 流式可用时挂起等待，由推送来确认
    if (this.streamReadyFor(kind)) {
      this.pendingConfirmKind = kind;
      this.pendingConfirmTarget = target;
      await this.waitStreamConfirm(kind, target, budgetMs);
      this.pendingConfirmKind = undefined;
      return;
    }

    await this.confirmToggleByPolling(kind, target, budgetMs);
    this.pendingConfirmKind = undefined;
  }

  /**
   * 该开关对应的状态域是否已收到过推送。
   *
   * 只有收到过推送才说明「服务端会推这个域」，才能靠推送来确认指令生效。
   */
  private streamReadyFor(kind: ToggleKind): boolean {
    if (kind === ToggleKind.CLIMATE) {
      return this.climatePrimed;
    }
    if (kind === ToggleKind.PURIFIER) {
      return this.airPrimed;
    }
    if (kind === ToggleKind.LOCK || kind === ToggleKind.WINDOW ||
      kind === ToggleKind.TRUNK || kind === ToggleKind.TRUNK_LOCK) {
      return this.exteriorPrimed;
    }
    return false;
  }

  /**
   * 等待流式推送确认指令生效。
   *
   * 推送到达时 applyStreamPhase 会比对目标状态，命中就落定并结束等待。
   *
   * @param kind     开关语义类型
   * @param target   目标状态
   * @param budgetMs 最长等待时长
   */
  private async waitStreamConfirm(kind: ToggleKind, target: TogglePhase,
    budgetMs: number): Promise<void> {
    const startedAt: number = Date.now();
    while (Date.now() - startedAt < budgetMs) {
      if (this.pendingConfirmKind !== kind) {
        // 已被推送确认并落定
        return;
      }
      // 流断了就没法再等到推送确认，退回轮询路径继续等
      if (!this.streamReadyFor(kind)) {
        Log.warn('状态流已断开，指令确认改走轮询');
        this.pendingConfirmKind = undefined;
        // 只把剩余预算交给轮询，否则总等待时间会翻倍
        const remaining = budgetMs - (Date.now() - startedAt);
        await this.confirmToggleByPolling(kind, target, Math.max(remaining, 1000));
        return;
      }
      await this.delay(200);
    }
    // 超时未确认：按目标状态落定（指令已成功下发，只是车端还没推进到终态）
    Log.warn(`车控状态未在 ${budgetMs}ms 内被推送确认，按下发结果落定`);
    this.pendingConfirmKind = undefined;
    this.settleToggle(kind, target);
    this.toast(`${this.toggleLabel(kind)}指令已发送`);
  }

  /**
   * 轮询确认指令生效。
   *
   * 与 confirmToggle 的轮询分支同逻辑，单独拆出来是因为
   * 「流式确认中途断流」需要在中途切回这条路径。
   *
   * @param kind     开关语义类型
   * @param target   目标状态
   * @param budgetMs 剩余预算
   */
  private async confirmToggleByPolling(kind: ToggleKind, target: TogglePhase,
    budgetMs: number): Promise<void> {
    const startedAt: number = Date.now();
    let interval: number = 300;
    while (Date.now() - startedAt < budgetMs) {
      await this.delay(interval);
      interval = Math.min(1200, interval + 250);
      try {
        const current = await this.readToggleState(kind);
        if (current === undefined || current !== target) {
          continue;
        }
        this.settleToggle(kind, target);
        this.toast(`${this.toggleLabel(kind)}已${target === TogglePhase.ON ? '开启' : '关闭'}`);
        return;
      } catch (err) {
        Log.warn(`确认车控状态失败: ${(err as Error).message}`);
      }
    }
    this.settleToggle(kind, target);
    this.toast(`${this.toggleLabel(kind)}指令已发送`);
  }

  /**
   * 指令生效后的落定处理。
   *
   * 除了写相位，还要把相关联的展示补齐 ——
   * 整车解锁会连带解锁尾门，但车端两个状态不一定同时推送；
   * 四扇窗也可能是分批落地的。
   *
   * 状态流可用时不做额外读取：推送会自己把尾门锁 / 逐扇车窗带过来，
   * 再读一次反而可能用旧值覆盖新推来的状态。
   */
  private settleToggle(kind: ToggleKind, target: TogglePhase): void {
    this.setPhase(kind, target);
    // 关闭已确认 —— 状态行这时才允许撤掉
    if (target === TogglePhase.OFF) {
      this.clearClosing(kind);
    }
    if (kind === ToggleKind.CLIMATE || kind === ToggleKind.PURIFIER) {
      this.syncClimateTimer();
      return;
    }
    if (this.exteriorPrimed) {
      return;
    }
    if (kind === ToggleKind.LOCK) {
      this.syncTrunkLock();
    } else if (kind === ToggleKind.WINDOW) {
      this.syncWindowStates();
    } else if (kind === ToggleKind.TRUNK || kind === ToggleKind.TRUNK_LOCK) {
      this.syncTrunkLock();
    }
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
        this.trunkLockPhase = TogglePhase.ON;
      } else if (state.tailgateLock === '已锁') {
        this.trunkUnlocked = false;
        this.trunkLockPhase = TogglePhase.OFF;
      }
      // 尾门开合状态也在同一批字段里，一并补齐。
      if (state.tailgate === '已打开') {
        this.trunkPhase = TogglePhase.ON;
      } else if (state.tailgate === '已关闭') {
        this.trunkPhase = TogglePhase.OFF;
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
      // 测量值缺失时沿用旧值，不清成未知
      if (state.airQualityIndex !== undefined) {
        this.airQualityIndex = state.airQualityIndex;
      }
      if (state.pm25UgM3 !== undefined) {
        this.pm25UgM3 = state.pm25UgM3;
      }
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
      this.trunkLockPhase = TogglePhase.ON;
    } else if (state.tailgateLock === '已锁') {
      this.trunkUnlocked = false;
      this.trunkLockPhase = TogglePhase.OFF;
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
    if (kind === ToggleKind.TRUNK) {
      if (state.tailgate === '已打开') {
        return TogglePhase.ON;
      }
      if (state.tailgate === '已关闭') {
        return TogglePhase.OFF;
      }
      return undefined;
    }
    if (kind === ToggleKind.TRUNK_LOCK) {
      if (state.tailgateLock === '未锁') {
        return TogglePhase.ON;
      }
      if (state.tailgateLock === '已锁') {
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
   * 协议 Exterior.OpenStatus：0=未指定 1=开启 2=关闭 3=未关严。
   * 「开启侧」取 1 或 3，与原版 y9.clitry 的判定一致（Open 或 Ajar 算未关闭）。
   *
   * 四扇全部在开启侧 → 开启；四扇全部关闭 → 关闭；
   * 其余（部分开启 / 有扇位未指定）返回 undefined，
   * 表示车端尚未推进到终态，继续等待。
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
      } else if (s === 2) {
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
      case ToggleKind.TRUNK:
        return this.trunkPhase;
      case ToggleKind.TRUNK_LOCK:
        return this.trunkLockPhase;
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
      case ToggleKind.TRUNK:
        this.trunkPhase = phase;
        break;
      case ToggleKind.TRUNK_LOCK:
        this.trunkLockPhase = phase;
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
      case ToggleKind.TRUNK:
        return current === TogglePhase.ON ? VehicleCommands.ACTION_TRUNK_CLOSE : VehicleCommands.ACTION_TRUNK_OPEN;
      case ToggleKind.TRUNK_LOCK:
        return current === TogglePhase.ON ? VehicleCommands.ACTION_LOCK_TRUNK : VehicleCommands.ACTION_UNLOCK_TRUNK;
      default:
        return '';
    }
  }

  /**
   * 渲染状态行的各个片段。
   *
   * 用 Text + Span 而不是 Row 拼多个 Text —— Span 是 Text 内的富文本片段，
   * 排版与截断都交给 Text 自己处理（超长时按 maxLines + 省略号收尾），
   * 用 Row 拼的话溢出时会从两侧被切掉。
   *
   * 每个片段按 kind 走不同的排版层级：
   *   label —— 状态词。13fp Medium，主题蓝 / 警示色 / 错误色，一眼扫到。
   *   data  —— 辅助数据。11fp 等宽三级灰，退到背景不抢注意力。
   *   key   —— 关键数值。13fp 等宽主色，与顶部「总里程」同一套语言。
   *   sep   —— 分隔符。11fp 三级灰，左右各留 5vp。
   */
  @Builder
  StatusSegments() {
    Text() {
      ForEach(this.statusSegments(), (segment: StatusSegment) => {
        Span(segment.text)
          .fontSize(segment.kind === 'label' || segment.kind === 'key' ? 13 : 11)
          .fontWeight(segment.kind === 'label' ? FontWeight.Medium : FontWeight.Normal)
          .fontFamily(segment.kind === 'label' ? '' : 'HarmonyOS Sans Mono')
          .fontColor(this.segmentColor(segment))
          .margin(segment.kind === 'sep' ? { left: 5, right: 5 } : { left: 0, right: 0 })
      })
    }
    .maxLines(1)
    .textOverflow({ overflow: TextOverflow.Ellipsis })
    .width('100%')
    .textAlign(TextAlign.Center)
  }

  /**
   * 片段颜色。
   */
  private segmentColor(segment: StatusSegment): ResourceColor {
    if (segment.kind === 'label') {
      return this.statusLabelColor();
    }
    if (segment.kind === 'key') {
      return $r('app.color.app_primary_text');
    }
    return $r('app.color.app_tertiary_text');
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
                  // 与尾门执行中的转圈一样大（24px），两处动效视觉一致
                  .width(24)
                  .height(24)
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
                    this.onClimateShortcutTap();
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

            // ---------- 车型信息 / 状态行 ----------
            // 有重要信息时，车型名与副文本整体让位给状态行 ——
            // 静态信息在异常或充电时是干扰，状态行才是用户此刻要看的。
            //
            // 容器高度固定：两行文字与一行状态行的高度不同，
            // 若按内容自适应，切换时整页会上下跳一下。
            // 固定高度 + 内容垂直居中，切换就看不出来了。
            Column() {
              if (this.statusSegments().length === 0) {
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
              } else {
                // 异常态前置警示图标：不用底色胶囊，警示色文字 + 图标即可跳出来
                if (this.statusShowWarningIcon()) {
                  Row({ space: 5 }) {
                    AppIcon({
                      name: AppIconName.WARNING,
                      iconSize: 14,
                      color: $r('app.color.app_warn')
                    })
                    .width(14)
                    .height(14)

                    this.StatusSegments()
                  }
                  .alignItems(VerticalAlign.Center)
                } else {
                  this.StatusSegments()
                }
              }
            }
            .width('100%')
            .height(Index.STATUS_AREA_HEIGHT)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
            .margin({ top: 10 })

            // ---------- 电量与续航 ----------
            Row() {
              Column({ space: 0 }) {
                // 充电状态不再在这里重复 —— 车模下方的状态行已经统一显示，
                // 两处都写会出现同样的信息，且两边可能不同步。
                Text('电量')
                  .fontSize(12)
                  .fontColor($r('app.color.app_tertiary_text'))
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
            .margin({ top: 10 })

            // ---------- 最后停车位置 ----------
            StateRow({
              icon: AppIconName.LOCATION,
              label: '最后停车位置',
              value: this.parkedTime,
              detail: this.parkedPlace.length > 0 ? this.parkedPlace : this.parkedCoordinate,
              showChevron: true,
              // 页尾最后一行，下面没有下一项，不需要分隔线
              showDivider: false,
              onTap: () => {
                this.openParkedMap();
              }
            })
            .margin({ top: 6, bottom: 4 })
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
        Control({
          campPhase: this.campPhase,
          campDurationMinutes: this.campDurationMinutes,
          campRemainingMinutes: this.campRemainingMinutes,
          campRemainingRatio: this.campRemainingRatio,
          airPhase: this.airPhase,
          airAqi: this.airQualityIndex,
          airPm25: this.pm25UgM3,
          // 空调与净化互斥：驻车空调在跑时净化开关置灰
          airDisabled: this.climateActive(),
          onCampToggle: () => {
            this.toggleCamp();
          },
          onCampDurationChange: (minutes: number) => {
            this.changeCampDuration(minutes);
          },
          onAirToggle: () => {
            this.toggle(ToggleKind.PURIFIER);
          },
          lockPhase: this.lockPhase,
          trunkLockPhase: this.trunkLockPhase,
          trunkPhase: this.trunkPhase,
          windowPhase: this.windowPhase,
          onLockToggle: () => {
            this.toggle(ToggleKind.LOCK);
          },
          onTrunkLockToggle: () => {
            this.toggle(ToggleKind.TRUNK_LOCK);
          },
          onTrunkToggle: () => {
            this.toggle(ToggleKind.TRUNK);
          },
          onWindowToggle: () => {
            this.toggle(ToggleKind.WINDOW);
          },
          onFindCarAction: (action: string) => {
            this.honkFlash(action);
          }
        })
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
