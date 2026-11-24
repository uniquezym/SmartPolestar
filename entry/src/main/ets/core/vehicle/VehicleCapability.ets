/**
 * 车辆能力模型 —— 描述「这台车支持哪些功能」。
 *
 * 数据来源：`GET {c3Host}/car-information/car`
 *
 * 这个接口返回账号下每辆车的完整档案，其中一组 `supports*` 布尔字段
 * 就是官方的能力探测结果 —— 官方 App 用它们决定某个功能按钮是否出现。
 *
 * 字段清单来自官方 `CarInformationGsonDeserializer`：
 *   46 个 supports* / reports* 开关
 *   12 个限制值（上限、电流范围、温度范围、计时器数量…）
 *   以及车型、驱动位、充电口位置、数字钥匙类型等档案信息
 *
 * 数值型限制的语义：
 *   0  表示服务端没下发这一项（视为不支持）
 *   >0 表示具体限制值
 */

/**
 * 一个能力项的展示信息。
 */
export class CapabilityEntry {
  /** 能力名。 */
  title: string;
  /** 服务端字段名，用作 ForEach 的 key。 */
  key: string;
  /** 说明文字。 */
  desc: string;
  /** 是否支持；null 表示服务端未下发这一项。 */
  supported: boolean | null;
  /**
   * 值文案。
   *
   * 三类来源共用这一个字段：
   *   数值型限制 —— 如「30 分钟」
   *   枚举型档位 —— 如「2 档」
   *   文本型字段 —— 如软件版本号
   * 空串表示这一项没有值，只有「支持 / 不支持」的开关语义。
   */
  value: string;

  constructor(title: string, key: string, supported: boolean | null, desc: string, value: string = '') {
    this.title = title;
    this.key = key;
    this.supported = supported;
    this.desc = desc;
    this.value = value;
  }
}

/**
 * 车辆能力快照。
 */
export class VehicleCapability {
  /** 车辆 VIN。 */
  vin: string = '';
  /** 车型名。 */
  modelName: string = '';
  /** 车型年款。 */
  modelYear: string = '';
  /** 市场。 */
  market: string = '';
  /** 车型代号。 */
  modelCode: string = '';
  /** 车牌号。 */
  registrationPlate: string = '';
  /** 驱动位（左舵 / 右舵）。 */
  driverSide: string = '';
  /** 远控类型（决定 App 侧可用的车控子集）。 */
  remoteControlType: string = '';
  /** 数字钥匙类型（空串表示不支持）。 */
  digitalKeyType: string = '';
  /** 直流充电口位置。 */
  electricInletDcLocation: string = '';
  /** 即插即充的 PCID（空串表示不支持）。 */
  plugAndChargePcid: string = '';
  /** 充电定时器类型。 */
  chargeTimerType: string = '';
  /** 本账号是否为车主。 */
  userIsOwner: boolean = false;
  /** 本账号是否已绑定该车。 */
  userIsLinked: boolean = false;
  /** 生产周次（0 表示服务端未下发）。 */
  structureWeek: number = 0;
  /** 用户端软件版本。 */
  consumerSoftwareVersion: string = '';
  /** 方向盘加热档位。 */
  steeringWheelHeatingLevel: string = '';
  /** 前排座椅加热档位。 */
  frontSeatsHeatingLevel: string = '';
  /** 后排座椅加热档位。 */
  rearSeatsHeatingLevel: string = '';

  /** 探测时间（epoch 毫秒）。 */
  detectedAt: number = 0;
  /** 探测是否成功。 */
  fetched: boolean = false;
  /** 失败时的错误信息。 */
  error: string = '';

  /**
   * 原始字段表 —— 键为服务端字段名，值为 boolean / number / string。
   *
   * 保留原始表而不是逐个转成成员变量，有两个好处：
   *   1. 服务端新增字段时不用改模型，下次探测就能看到
   *   2. 序列化 / 反序列化只需整体存一份
   */
  raw: Record<string, boolean | number | string> = {};

  /**
   * 读一个布尔开关。服务端没下发时返回 null（区别于「明确为 false」）。
   */
  flag(key: string): boolean | null {
    const value = this.raw[key];
    if (typeof value === 'boolean') {
      return value;
    }
    return null;
  }

  /**
   * 读一个数值限制。服务端没下发时返回 0。
   */
  limitOf(key: string): number {
    const value = this.raw[key];
    if (typeof value === 'number') {
      return value;
    }
    return 0;
  }

  /**
   * 读一个文本字段。服务端没下发时返回空串。
   */
  textOf(key: string): string {
    const value = this.raw[key];
    if (typeof value === 'string') {
      return value;
    }
    return '';
  }

  /**
   * 能力项分组。
   *
   * 分组依据是「这个能力管的是哪一块」——
   * 官方 App 是按页面分组决定显隐的，我们照同样的思路分组展示。
   */
  static readonly GROUPS: string[] = [
    '车锁与车身', '寻车', '驻车空调', '空气净化', '充电', '充电地点', '数字钥匙与 OTA',
    '数据上报', '账号与档案'
  ];

  /**
   * 能力项定义表。
   *
   * 每一项对应 car-information 响应里的一个字段。
   * type: 'bool' 表示布尔开关，'int' 表示数值限制。
   */
  private static readonly DEFINITIONS: CapabilityDefinition[] = [
    // ---------- 车锁与车身 ----------
    { key: 'supportsLock', title: '锁车', group: '车锁与车身', desc: '锁定整车' },
    { key: 'supportsUnlock', title: '解锁', group: '车锁与车身', desc: '解锁整车' },
    { key: 'supportsLockReducedGuard', title: '减弱守卫锁', group: '车锁与车身', desc: '锁车但保留车内解锁权限' },
    { key: 'supportsRemoteTrunkControl', title: '尾门控制', group: '车锁与车身', desc: '打开 / 关闭尾门' },
    { key: 'supportsRemoteTrunkUnlock', title: '尾门解锁', group: '车锁与车身', desc: '单独解锁尾门' },
    { key: 'supportsRemoteWindowControl', title: '车窗控制', group: '车锁与车身', desc: '打开 / 关闭车窗' },
    { key: 'supportsAccountLinking', title: '账号关联', group: '车锁与车身', desc: '允许把车辆共享给其他账号' },

    // ---------- 寻车 ----------
    { key: 'supportsHonkAndFlash', title: '鸣笛并闪灯', group: '寻车', desc: '远程寻车（鸣笛 + 闪灯）' },
    { key: 'supportsFlash', title: '仅闪灯', group: '寻车', desc: '只闪灯不鸣笛' },

    // ---------- 驻车空调 ----------
    { key: 'supportsParkingClimatization', title: '驻车空调', group: '驻车空调', desc: '远程开关驻车空调' },
    { key: 'supportsParkingClimatizationDirectStartSettings', title: '直接启动设置', group: '驻车空调', desc: '设置启动温度与时长' },
    { key: 'supportsParkingClimatizationTimerSettings', title: '定时器设置', group: '驻车空调', desc: '创建空调预约' },
    { key: 'supportsParkingClimatizationRepeatedWeekdayTimers', title: '按周重复预约', group: '驻车空调', desc: '每周固定日期自动启动' },
    { key: 'supportsParkingClimatizationUnrepeatedWeekdayTimers', title: '单次预约', group: '驻车空调', desc: '仅一次生效的预约' },
    { key: 'supportsParkingClimatization24hTimers', title: '24 小时预约', group: '驻车空调', desc: '跨零点的预约时段' },
    { key: 'supportsParkingClimatizationCompartmentTemperatureSettings', title: '舱内温度设置', group: '驻车空调', desc: '设置目标温度' },
    { key: 'supportsParkingClimatizationFrontSeatsSettings', title: '前排座椅设置', group: '驻车空调', desc: '前排座椅加热 / 通风' },
    { key: 'supportsParkingClimatizationRearSeatsSettings', title: '后排座椅设置', group: '驻车空调', desc: '后排座椅加热 / 通风' },
    { key: 'supportsParkingClimatizationSteeringWheelSettings', title: '方向盘加热设置', group: '驻车空调', desc: '方向盘加热档位' },
    { key: 'parkingClimatizationMaxRuntime', title: '最长运行时间', group: '驻车空调', desc: '单次可运行的分钟数上限', type: 'int', unit: ' 分钟' },
    { key: 'parkingClimatizationMaxNumberOfTimers', title: '预约数量上限', group: '驻车空调', desc: '最多可创建多少条预约', type: 'int', unit: ' 条' },
    { key: 'parkingClimatizationCompartmentTemperatureMinLimit', title: '舱内温度下限', group: '驻车空调', desc: '可设置的最低温度', type: 'int', unit: ' °C' },
    { key: 'parkingClimatizationCompartmentTemperatureMaxLimit', title: '舱内温度上限', group: '驻车空调', desc: '可设置的最高温度', type: 'int', unit: ' °C' },

    // ---------- 空气净化 ----------
    { key: 'supportsAirPurification', title: '空气净化', group: '空气净化', desc: '远程开关空气净化' },
    { key: 'supportsAirPurificationInternalMeasurement', title: '内部空气质量测量', group: '空气净化', desc: '读取舱内 PM2.5' },
    { key: 'supportsAirPurificationExternalMeasurement', title: '外部空气质量测量', group: '空气净化', desc: '读取车外 PM2.5' },
    { key: 'hasAirPurificationFixedRuntime', title: '固定净化时长', group: '空气净化', desc: '净化时长固定不可调' },
    { key: 'airPurificationFixedRuntimeMinutes', title: '净化时长', group: '空气净化', desc: '每次净化的分钟数', type: 'int', unit: ' 分钟' },

    // ---------- 充电 ----------
    { key: 'supportsChargingFunctions', title: '充电功能', group: '充电', desc: '充电相关功能总开关' },
    { key: 'supportsTargetChargeLevelSetting', title: '充电上限设置', group: '充电', desc: '设置目标电量' },
    { key: 'supportsGlobalChargeAmperageLimitSetting', title: '电流上限设置', group: '充电', desc: '设置充电电流上限' },
    { key: 'supportsGlobalChargeTimer', title: '预约充电', group: '充电', desc: '设置全局充电时段' },
    { key: 'supportsChargeNowTimerOverride', title: '立即充电覆盖', group: '充电', desc: '临时跳过预约立即充电' },
    { key: 'supportsMinChargeLevelSetting', title: '最低电量设置', group: '充电', desc: '设置保留电量下限' },
    { key: 'supportsBatteryOptimisedCharging', title: '优化充电', group: '充电', desc: '按目标时间智能安排充电' },
    { key: 'supportsPlugAndCharge', title: '即插即充', group: '充电', desc: '免刷卡自动充电' },
    { key: 'supportsPlugAndChargeRemoteToggle', title: '即插即充远程开关', group: '充电', desc: '远程启用即插即充' },
    { key: 'chargeAmperageMinLimit', title: '电流下限', group: '充电', desc: '可设置的最小电流', type: 'int', unit: ' A' },
    { key: 'chargeAmperageMaxLimit', title: '电流上限', group: '充电', desc: '可设置的最大电流', type: 'int', unit: ' A' },
    { key: 'targetChargeLevelPercentageMinLimit', title: '充电上限下限', group: '充电', desc: '目标电量可设置的最小值', type: 'int', unit: ' %' },

    // ---------- 充电地点 ----------
    { key: 'supportsChargeLocationsChargeAmperageLimitSetting', title: '地点电流上限', group: '充电地点', desc: '每个充电地点可单独设电流' },
    { key: 'supportsChargeLocationsChargeTimerMinChargeLevelSetting', title: '地点定时与最低电量', group: '充电地点', desc: '地点级定时器 + 保留电量' },
    { key: 'supportsChargeLocationsDepartureTime', title: '地点出发时间', group: '充电地点', desc: '按出发时间安排充电' },
    { key: 'supportsChargeLocationsDepartureTimeMinChargeLevelSetting', title: '地点出发时间与最低电量', group: '充电地点', desc: '出发时间 + 保留电量' },
    { key: 'supportsChargeLocationsDepartureTimeWeekdaysSelection', title: '地点出发时间星期选择', group: '充电地点', desc: '出发时间可按星期重复' },
    { key: 'supportsChargeLocationWeekdayTimersDaySelection', title: '地点定时器按天选择', group: '充电地点', desc: '定时器可按天设置' },
    { key: 'chargingMaxNumberOfLocations', title: '充电地点数量上限', group: '充电地点', desc: '最多可保存多少个地点', type: 'int', unit: ' 个' },
    { key: 'chargingMaxNumberOfTimersPerLocation', title: '单地点定时器上限', group: '充电地点', desc: '每个地点最多多少条定时器', type: 'int', unit: ' 条' },
    { key: 'chargingMaxNumberOfDepartureTimesPerLocation', title: '单地点出发时间上限', group: '充电地点', desc: '每个地点最多多少个出发时间', type: 'int', unit: ' 个' },

    // ---------- 数字钥匙与 OTA ----------
    { key: 'supportsFullOtaUpdates', title: '完整 OTA 升级', group: '数字钥匙与 OTA', desc: '支持整车 OTA' },
    { key: 'supportsRemoteOtaInstallSchedule', title: 'OTA 预约安装', group: '数字钥匙与 OTA', desc: '远程预约 OTA 安装时间' },
    { key: 'supportsRemoteInternetActivation', title: '远程联网激活', group: '数字钥匙与 OTA', desc: '远程激活车联网' },

    // ---------- 数据上报 ----------
    { key: 'reportsAvgSpeed', title: '上报平均车速', group: '数据上报', desc: '车端会上报平均车速' },
    { key: 'reportsAvgSpeedLastTrip', title: '上报单次平均车速', group: '数据上报', desc: '车端会上报本次行程均速' },
    { key: 'reportsAvgElectricConsumption', title: '上报平均能耗', group: '数据上报', desc: '车端会上报平均能耗' },
    { key: 'reportsAvgElectricConsumptionLastTrip', title: '上报单次平均能耗', group: '数据上报', desc: '车端会上报本次行程均耗' },
    { key: 'reportsAvgElectricConsumptionLastCharge', title: '上报自充电平均能耗', group: '数据上报', desc: '车端会上报自充电周期均耗' },
    { key: 'reportsTyrePressure', title: '上报胎压', group: '数据上报', desc: '车端会上报胎压状态' },
    { key: 'reportsAbsoluteTyrePressure', title: '上报胎压绝对值', group: '数据上报', desc: '上报具体 kPa 数值而非仅告警' },

    // ---------- 账号与档案 ----------
    { key: 'userIsOwner', title: '本账号为车主', group: '账号与档案', desc: '当前账号是这辆车的车主' },
    { key: 'userIsLinked', title: '本账号已绑定', group: '账号与档案', desc: '当前账号已绑定这辆车' },
    { key: 'structureWeek', title: '生产周次', group: '账号与档案', desc: '车辆下线生产周次', type: 'int', unit: ' 周' },
    { key: 'consumerSoftwareVersion', title: '用户端软件版本', group: '账号与档案', desc: '车机用户端软件版本号', type: 'text' },
    { key: 'parkingClimatizationSteeringWheelSettingLevels', title: '方向盘加热档位', group: '账号与档案', desc: '方向盘加热可调档位', type: 'text' },
    { key: 'parkingClimatizationFrontSeatsSettingLevels', title: '前排座椅加热档位', group: '账号与档案', desc: '前排座椅加热可调档位', type: 'text' },
    { key: 'parkingClimatizationRearSeatsSettingLevels', title: '后排座椅加热档位', group: '账号与档案', desc: '后排座椅加热可调档位', type: 'text' }
  ];

  /**
   * 按分组列出能力项。
   */
  static entries(cap: VehicleCapability): CapabilityEntry[] {
    const result: CapabilityEntry[] = [];
    for (const def of VehicleCapability.DEFINITIONS) {
      if (def.type === 'int') {
        const value = cap.limitOf(def.key);
        result.push(new CapabilityEntry(def.title, def.key, null, def.desc,
          value > 0 ? `${value}${def.unit ?? ''}` : ''));
      } else if (def.type === 'text') {
        const value = cap.textOf(def.key);
        result.push(new CapabilityEntry(def.title, def.key, null, def.desc, value));
      } else {
        result.push(new CapabilityEntry(def.title, def.key, cap.flag(def.key), def.desc));
      }
    }
    return result;
  }

  /**
   * 取某个分组的能力项。
   */
  static entriesOfGroup(cap: VehicleCapability, group: string): CapabilityEntry[] {
    const result: CapabilityEntry[] = [];
    for (const entry of VehicleCapability.entries(cap)) {
      for (const def of VehicleCapability.DEFINITIONS) {
        if (def.key === entry.key && def.group === group) {
          result.push(entry);
          break;
        }
      }
    }
    return result;
  }

  /**
   * 某组里为 true 的能力名。
   */
  static enabledInGroup(cap: VehicleCapability, group: string): string[] {
    const names: string[] = [];
    for (const entry of VehicleCapability.entriesOfGroup(cap, group)) {
      if (entry.supported === true) {
        names.push(entry.title);
      }
    }
    return names;
  }

  /**
   * 序列化为可持久化的 JSON 字符串。
   */
  toJson(): string {
    return JSON.stringify({
      vin: this.vin,
      modelName: this.modelName,
      modelYear: this.modelYear,
      market: this.market,
      modelCode: this.modelCode,
      registrationPlate: this.registrationPlate,
      driverSide: this.driverSide,
      remoteControlType: this.remoteControlType,
      digitalKeyType: this.digitalKeyType,
      electricInletDcLocation: this.electricInletDcLocation,
      plugAndChargePcid: this.plugAndChargePcid,
      chargeTimerType: this.chargeTimerType,
      userIsOwner: this.userIsOwner,
      userIsLinked: this.userIsLinked,
      structureWeek: this.structureWeek,
      consumerSoftwareVersion: this.consumerSoftwareVersion,
      steeringWheelHeatingLevel: this.steeringWheelHeatingLevel,
      frontSeatsHeatingLevel: this.frontSeatsHeatingLevel,
      rearSeatsHeatingLevel: this.rearSeatsHeatingLevel,
      detectedAt: this.detectedAt,
      fetched: this.fetched,
      error: this.error,
      raw: this.raw
    });
  }

  /**
   * 从持久化的 JSON 字符串还原。
   */
  static fromJson(text: string): VehicleCapability | undefined {
    if (text.length === 0) {
      return undefined;
    }
    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(text) as Record<string, Object>;
    } catch (err) {
      return undefined;
    }
    const cap = new VehicleCapability();
    cap.vin = (parsed['vin'] as string) ?? '';
    cap.modelName = (parsed['modelName'] as string) ?? '';
    cap.modelYear = (parsed['modelYear'] as string) ?? '';
    cap.market = (parsed['market'] as string) ?? '';
    cap.modelCode = (parsed['modelCode'] as string) ?? '';
    cap.registrationPlate = (parsed['registrationPlate'] as string) ?? '';
    cap.driverSide = (parsed['driverSide'] as string) ?? '';
    cap.remoteControlType = (parsed['remoteControlType'] as string) ?? '';
    cap.digitalKeyType = (parsed['digitalKeyType'] as string) ?? '';
    cap.electricInletDcLocation = (parsed['electricInletDcLocation'] as string) ?? '';
    cap.plugAndChargePcid = (parsed['plugAndChargePcid'] as string) ?? '';
    cap.chargeTimerType = (parsed['chargeTimerType'] as string) ?? '';
    cap.userIsOwner = (parsed['userIsOwner'] as boolean) ?? false;
    cap.userIsLinked = (parsed['userIsLinked'] as boolean) ?? false;
    cap.structureWeek = (parsed['structureWeek'] as number) ?? 0;
    cap.consumerSoftwareVersion = (parsed['consumerSoftwareVersion'] as string) ?? '';
    cap.steeringWheelHeatingLevel = (parsed['steeringWheelHeatingLevel'] as string) ?? '';
    cap.frontSeatsHeatingLevel = (parsed['frontSeatsHeatingLevel'] as string) ?? '';
    cap.rearSeatsHeatingLevel = (parsed['rearSeatsHeatingLevel'] as string) ?? '';
    cap.detectedAt = (parsed['detectedAt'] as number) ?? 0;
    cap.fetched = (parsed['fetched'] as boolean) ?? false;
    cap.error = (parsed['error'] as string) ?? '';
    const raw = parsed['raw'] as Record<string, boolean | number | string> | undefined;
    if (raw !== undefined) {
      cap.raw = raw;
    }
    return cap;
  }
}

/**
 * 能力项定义。
 */
interface CapabilityDefinition {
  /** 服务端字段名。 */
  key: string;
  /** 展示名。 */
  title: string;
  /** 所属分组。 */
  group: string;
  /** 说明。 */
  desc: string;
  /** 类型：bool（默认）/ int / text。 */
  type?: string;
  /** 数值单位的展示后缀。 */
  unit?: string;
}
