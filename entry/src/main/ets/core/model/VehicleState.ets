/**
 * 车辆聚合状态 —— 对应 Android 端 p000.fa0（74 字段）。
 *
 * 覆盖电池 / 充电 / 空调 / 车锁门窗 / 尾门 / 空气 / 里程能耗 / 健康 / 位置 / OTA 全部域。
 * 字段号到业务含义的映射见 core/proto/schemas 下各服务定义。
 */
export class VehicleState {
  // ---- 标识 ----
  vin: string = '';
  model: string = 'Polestar 2';
  modelName: string = '';
  modelYear: string = '';
  batteryCapacityKwh: number | undefined = undefined;
  contentCodes: string = '';

  // ---- 电池与充电 ----
  battery: number | undefined = undefined;
  range: number | undefined = undefined;
  charging: string = '未知';
  chargerConnection: string = '未知';
  chargingType: string = '未知';
  chargerPowerStatus: string = '未知';
  timeToFullMinutes: number | undefined = undefined;
  powerWatts: number | undefined = undefined;
  currentAmps: number | undefined = undefined;

  // ---- 能耗 ----
  // 命名对齐 Android 端 fa0 的 f1751A..f1756F：
  //   tripManual*    手动统计
  //   tripAutomatic* 自动统计
  //   tripSinceCharge*  自上次充电
  tripManualAverageEnergyKwhPer100Km: number | undefined = undefined;
  tripAutomaticAverageEnergyKwhPer100Km: number | undefined = undefined;
  tripSinceChargeAverageEnergyKwhPer100Km: number | undefined = undefined;
  tripManualEnergyWh: number | undefined = undefined;
  tripAutomaticEnergyWh: number | undefined = undefined;
  tripSinceChargeEnergyWh: number | undefined = undefined;

  // ---- 驻车空调 ----
  climate: string = '未知';
  climateRuntimeMinutes: number | undefined = undefined;
  /** 空调运行模式。field 6：1=制冷 2=制热 其余=送风。对应原版状态卡图标选择。 */
  climateRunMode: string = '未知';
  climateTemperatureC: number | undefined = undefined;
  climateTargetTemperatureC: number | undefined = undefined;

  // ---- 车锁 / 门 / 窗 ----
  locked: string = '未知';
  doorStates: number[] = [];
  windowStates: number[] = [];
  windows: string = '车窗状态未知';
  tailgate: string = '未知';
  tailgateLock: string = '';
  /** 机盖状态。field 11：1 或 3 视为开启（判定对齐原版 g10）。 */
  hoodState: number = -1;
  /** 充电口状态。field 13：1 或 3 视为开启。 */
  chargePortState: number = -1;

  // ---- 空气净化 ----
  air: string = '未知';
  airQualityIndex: number | undefined = undefined;
  pm25UgM3: number | undefined = undefined;
  /**
   * 净化剩余运行分钟数。precleaning field 11。
   *
   * 车端给出的剩余时长是「剩余分钟数」，据此可以推算预计结束时刻，
   * 状态检查只需排在那个时刻前后，不必固定周期轮询。
   */
  airRuntimeMinutes: number | undefined = undefined;

  // ---- 里程 ----
  odometerKm: number | undefined = undefined;
  tripManualKm: number | undefined = undefined;
  tripAutomaticKm: number | undefined = undefined;
  tripSinceChargeKm: number | undefined = undefined;
  /** 手动小计平均车速（km/h）。odometer field 5。 */
  manualAverageSpeedKph: number | undefined = undefined;
  /** 自动小计平均车速（km/h）。odometer field 6。 */
  automaticAverageSpeedKph: number | undefined = undefined;
  /** 自充电小计平均车速（km/h）。odometer field 8。 */
  sinceChargeAverageSpeedKph: number | undefined = undefined;

  // ---- 健康 ----
  healthStatus: string = '未知';
  healthDetails: string = '';
  /**
   * 逐项健康告警文案。
   *
   * 协议里每种告警都是独立字段（胎压 4 条、液位 3 条、12V 电压、保养状态……），
   * 汇总成一句「需关注」看不出到底哪里有问题。
   * 这里逐项解析成可读文案，概览页的状态行直接用它。
   */
  healthWarnings: string[] = [];
  maintenanceStatus: string = '未知';
  serviceRemainingHours: number | undefined = undefined;
  serviceRemainingDays: number | undefined = undefined;
  serviceRemainingKm: number | undefined = undefined;

  // ---- 位置（最后停车位置） ----
  parkedLatitude: number | undefined = undefined;
  parkedLongitude: number | undefined = undefined;
  parkedTimestamp: number | undefined = undefined;
  parkedLocationStale: boolean = false;
  parkedLocationOdometerKm: number | undefined = undefined;

  // ---- 软件 / OTA ----
  softwareVersion: string = '';
  softwareUpdateStatus: string = '';
  softwareUpdateName: string = '';
  softwareUpdateScheduled: boolean = false;

  // ---- 各域最后成功更新时间 ----
  batteryStateAt: number = 0;
  exteriorStateAt: number = 0;
  climateStateAt: number = 0;
  odometerStateAt: number = 0;
  airStateAt: number = 0;
  healthStateAt: number = 0;
  parkedLocationStateAt: number = 0;
  softwareStateAt: number = 0;

  /**
   * 汇总车窗状态。还原自 Android 端 m1379n0。
   *
   * 协议 Exterior.OpenStatus：0=未指定 1=开启 2=关闭 3=未关严。
   * 「未关闭」取 1 或 3，与原版 y9.clitry 的判定一致（Open 或 Ajar 算未关闭）。
   *
   * 任一车窗处于开启侧 → 「车窗未关闭」；
   * 四扇全部关闭 → 「车窗已关闭」；
   * 其余（存在未指定的扇位）→ 「车窗状态未知」，
   * 不把「未指定」当成已关闭 —— 那样会让快捷键误报成关好了。
   */
  static summarizeWindows(states: number[] | undefined): string {
    if (states === undefined || states.length === 0) {
      return '车窗状态未知';
    }
    let closed = 0;
    for (const s of states) {
      if (s === 1 || s === 3) {
        return '车窗未关闭';
      }
      if (s === 2) {
        closed++;
      }
    }
    if (closed === states.length) {
      return '车窗已关闭';
    }
    return '车窗状态未知';
  }

  /**
   * 将枚举索引映射为中文文案，超界返回"未知"。还原自 m1382p。
   */
  static enumLabel(index: number | undefined, labels: string[]): string {
    if (index === undefined || index < 0 || index >= labels.length) {
      return '未知';
    }
    return labels[index];
  }
}

/**
 * 充电状态枚举文案。对应 Android 端 m1403Q 的内联数组。
 */
export const CHARGING_LABELS: string[] = [
  '未指定', '充电中', '空闲', '计划中', '放电中', '错误', '智能充电', '已完成', '智能充电暂停'
];

/**
 * 充电枪连接状态。对应 Android 端 m1403Q。
 */
export const CHARGER_CONNECTION_LABELS: string[] = ['未知', '已连接', '未连接', '连接故障'];

/**
 * 充电类型。对应 Android 端 m1403Q。
 */
export const CHARGING_TYPE_LABELS: string[] = ['未知', '未充电', '交流', '直流', '无线'];

/**
 * 充电桩供电状态。对应 Android 端 m1403Q。
 */
export const CHARGER_POWER_LABELS: string[] = ['未知', '无电源', '初始化中', '可用', '正在供电', '故障'];

/**
 * 统一的充电阶段。
 *
 * 协议里有两组独立的状态：充电枪连接状态（chargerConnection）与
 * 充电状态（charging）。两者组合起来才是用户真正关心的一句话，
 * 因此在这里归一成单一阶段，UI 只认这个枚举。
 *
 * 判定规则见 VehicleState.chargeStageOf()。
 */
export enum ChargeStage {
  /** 未充电：没插枪，也没有充电在进行。 */
  IDLE = 'idle',
  /** 已插枪但未开始充电（计划中 / 空闲）。 */
  PLUGGED = 'plugged',
  /** 正在充电（充电中 / 智能充电）。 */
  CHARGING = 'charging',
  /** 智能充电暂停。 */
  PAUSED = 'paused',
  /** 充电已完成。 */
  COMPLETED = 'completed',
  /** 正在放电（向外供电）。 */
  DISCHARGING = 'discharging',
  /** 故障：充电错误或充电枪连接故障。 */
  FAULT = 'fault'
}

/**
 * 充电阶段判定的辅助方法。
 *
 * 放在模型层是为了让主应用与桌面卡片共用同一套规则 —— 两边显示的
 * 「充电中 / 已完成 / 已连接」必须完全一致，否则会出现卡片说已充满、
 * 应用里还在转圈的情况。
 */
export class ChargeStageResolver {
  /**
   * 由充电状态与充电枪连接状态推出统一的充电阶段。
   *
   * 判定按优先级从上到下，命中即返回：
   *   1. 充电中 / 智能充电   → 充电中
   *   2. 放电中              → 放电中
   *   3. 已完成              → 已完成
   *   4. 充电错误 / 连接故障 → 故障
   *   5. 智能充电暂停        → 已暂停
   *   6. 充电枪已连接        → 已插枪
   *   7. 其余                → 未充电
   *
   * 「已完成」排在「已连接」之前 —— 充满后枪还插着，
   * 这时用户关心的是「已充满」，而不是「插着枪」。
   */
  static resolve(charging: string, chargerConnection: string): ChargeStage {
    if (charging === '充电中' || charging === '智能充电') {
      return ChargeStage.CHARGING;
    }
    if (charging === '放电中') {
      return ChargeStage.DISCHARGING;
    }
    if (charging === '已完成') {
      return ChargeStage.COMPLETED;
    }
    if (charging === '错误' || chargerConnection === '连接故障') {
      return ChargeStage.FAULT;
    }
    if (charging === '智能充电暂停') {
      return ChargeStage.PAUSED;
    }
    if (chargerConnection === '已连接') {
      return ChargeStage.PLUGGED;
    }
    return ChargeStage.IDLE;
  }

  /**
   * 充电阶段的简短文案，用于卡片与电量区的 inline 说明。
   *
   * @param stage        充电阶段
   * @param powerWatts   充电功率（瓦）
   * @param currentAmps  充电电流（安）
   * @param remainingMin 充满剩余时长（分钟）
   */
  static text(stage: ChargeStage, powerWatts: number, currentAmps: number,
    remainingMin: number): string {
    switch (stage) {
      case ChargeStage.IDLE:
        return '';
      case ChargeStage.DISCHARGING:
        return '放电中';
      case ChargeStage.COMPLETED:
        return '已完成';
      case ChargeStage.FAULT:
        return '充电错误';
      case ChargeStage.PAUSED:
        return '已暂停';
      case ChargeStage.PLUGGED:
        return '已连接';
      default:
        break;
    }
    // 充电中：功率 · 电流 · 充满剩余时长
    const parts: string[] = [];
    if (powerWatts >= 1000) {
      parts.push(`${(powerWatts / 1000).toFixed(1)} kW`);
    } else if (powerWatts > 0) {
      parts.push(`${powerWatts} W`);
    }
    if (currentAmps > 0) {
      parts.push(`${Math.round(currentAmps)} A`);
    }
    if (remainingMin > 0) {
      if (remainingMin < 60) {
        parts.push(`约 ${remainingMin} 分钟`);
      } else {
        const h = Math.floor(remainingMin / 60);
        const m = remainingMin % 60;
        parts.push(m === 0 ? `约 ${h} 小时` : `约 ${h} 小时 ${m} 分`);
      }
    }
    if (parts.length === 0) {
      return '充电中';
    }
    return parts.join(' · ');
  }
}

/**
 * 驻车空调状态。对应 Android 端 m1358R。
 */
export const CLIMATE_LABELS: string[] = ['未知', '开启', '关闭', '处理中'];

/**
 * 驻车空调运行模式。对应 Android 端 m1358R 取 field 6。
 *
 * 原版只用该字段选择状态卡图标，不作为文字显示：
 *   1 → ic_climate_cool（雪花）  2 → ic_climate_heat（上升热气）  其余 → ic_climate_airflow（气流）
 *
 * 注意：原版不存在「内循环 / 外循环」这一语义，早期版本误映射为此，已更正。
 */
export const CLIMATE_RUN_MODE_LABELS: string[] = ['送风', '制冷', '制热'];

/**
 * 车锁状态。对应 Android 端外饰读取分支。
 */
export const LOCK_LABELS: string[] = ['未知', '未锁', '已锁'];

/**
 * 尾门状态。对应 Android 端外饰读取分支。
 */
export const TAILGATE_LABELS: string[] = ['未知', '已打开', '已关闭', '未关严'];

/**
 * 空气净化状态。对应 Android 端 m1357O 的内联数组。
 */
export const AIR_LABELS: string[] = ['未知', '开启', '关闭', '处理中'];

/**
 * 车辆健康状态。对应 Android 端 health 分支。
 */
export const HEALTH_LABELS: string[] = ['良好', '未知', '需关注'];

/**
 * 保养状态。对应 Android 端 y90 health 分支的 12 项枚举。
 */
export const MAINTENANCE_LABELS: string[] = [
  '未提供', '正常', '未知警告', '保养将近', '发动机工时将近', '里程将近',
  '需要保养', '发动机工时到期', '里程到期', '保养逾期', '发动机工时逾期', '里程逾期'
];
