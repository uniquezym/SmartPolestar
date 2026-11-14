import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import { VehicleRepository } from '../core/vehicle/VehicleRepository';
import { ControlCoordinator } from '../core/vehicle/ControlCoordinator';
import { VehicleCommands } from '../core/net/VehicleCommands';
import { VehicleState } from '../core/model/VehicleState';
import { AppIcon, AppIconName } from '../components/Icons';
import { StateToggle, ToggleKind, TogglePhase } from '../components/StateToggle';
import { VehiclePlan } from '../components/VehiclePlan';
import { StateRow } from '../components/StateRow';
import { Control } from './Control';
import { Detail } from './Detail';
import { PlaceResolver } from '../core/vehicle/PlaceResolver';
import { MapLauncher } from '../core/vehicle/MapLauncher';
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
   * 不打接口。这样「5 分钟前」会自己跳到「10 分钟前」。
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
   * 重算「距上次刷新」文案。
   */
  private refreshText(): void {
    if (this.lastRefreshAt > 0) {
      this.lastRefreshText = Index.formatElapsed(this.lastRefreshAt, Date.now());
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
  }

  /**
   * 页面销毁时清理定时器。
   */
  aboutToDisappear(): void {
    this.stopTextTimer();
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

    this.locked = state.locked;
    this.windows = state.windows;

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
   * 是否已连接充电线。
   */
  private chargingConnected(): boolean {
    return this.chargerConnection === '已连接' ||
      this.charging === '充电中' || this.charging === '智能充电';
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

    const ctx = this.context;
    const client = this.repository?.getClient();
    const session = this.repository?.getSession();
    if (ctx === undefined || client === undefined || session === undefined) {
      this.errorMessage = '会话未就绪，请重试';
      return;
    }

    // 记录点击前的阶段，失败时回滚
    const prev = this.phaseOf(kind);
    this.setPhase(kind, TogglePhase.PENDING);

    // 目标动作：由当前阶段决定
    const action = this.actionOf(kind, prev);

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
    }
    this.toast(`${this.toggleLabel(kind)}指令已发送`);
  }

  /**
   * 单独读一次 exterior，把尾门锁状态同步到车模标记点。
   *
   * 整车解锁 / 锁定会连带改变尾门锁，但车端不一定同时推送两个状态，
   * 需要额外读一次才能拿到准确的尾门锁状态。
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
      this.windowStates = state.windowStates;
      this.doorStates = state.doorStates;
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
    // 车窗：任一车窗未关闭即视为开启
    if (state.windows === '车窗已关闭') {
      return TogglePhase.OFF;
    }
    if (state.windows === '车窗未关闭') {
      return TogglePhase.ON;
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

    const ctx = this.context;
    const client = this.repository?.getClient();
    const session = this.repository?.getSession();
    if (ctx === undefined || client === undefined || session === undefined) {
      this.errorMessage = '会话未就绪，请重试';
      return;
    }

    const wasUnlocked = this.trunkUnlocked;
    const action = wasUnlocked ? VehicleCommands.ACTION_LOCK_TRUNK : VehicleCommands.ACTION_UNLOCK_TRUNK;
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
        this.refresh();
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
