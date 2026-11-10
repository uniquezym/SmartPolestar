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
  manualAverageSpeedKph: number | undefined = undefined;

  // ---- 驻车空调 ----
  climate: string = '未知';
  climateRuntimeMinutes: number | undefined = undefined;
  climateVentilationMode: string = '未知';
  climateTemperatureC: number | undefined = undefined;
  climateTargetTemperatureC: number | undefined = undefined;

  // ---- 车锁 / 门 / 窗 ----
  locked: string = '未知';
  doorStates: number[] = [];
  windowStates: number[] = [];
  windows: string = '车窗状态未知';
  tailgate: string = '未知';
  tailgateLock: string = '';
  hoodState: string = '';
  chargePortState: string = '';

  // ---- 空气净化 ----
  air: string = '未知';
  airQualityIndex: number | undefined = undefined;
  pm25UgM3: number | undefined = undefined;

  // ---- 里程 ----
  odometerKm: number | undefined = undefined;
  tripManualKm: number | undefined = undefined;
  tripAutomaticKm: number | undefined = undefined;
  tripSinceChargeKm: number | undefined = undefined;

  // ---- 健康 ----
  healthStatus: string = '未知';
  healthDetails: string = '';
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
   * 任一车窗状态位为 1 或 3 视为"未关闭"；全为 0 且数组非空视为"已关闭"；否则"未知"。
   */
  static summarizeWindows(states: number[] | undefined): string {
    if (states === undefined || states.length === 0) {
      return '车窗状态未知';
    }
    for (const s of states) {
      if (s === 1 || s === 3) {
        return '车窗未关闭';
      }
    }
    return '车窗已关闭';
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
 * 驻车空调状态。对应 Android 端 m1358R。
 */
export const CLIMATE_LABELS: string[] = ['未知', '开启', '关闭', '处理中'];

/**
 * 车锁状态。对应 Android 端外饰读取分支。
 */
export const LOCK_LABELS: string[] = ['未知', '未锁', '已锁'];

/**
 * 尾门状态。对应 Android 端外饰读取分支。
 */
export const TAILGATE_LABELS: string[] = ['已打开', '已关闭', '未关严'];

/**
 * 空气净化状态。对应 Android 端 m1357O。
 */
export const AIR_LABELS: string[] = ['未知', '开启', '关闭'];

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
