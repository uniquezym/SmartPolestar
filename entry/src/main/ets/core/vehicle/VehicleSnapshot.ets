import {
  VehicleState, OPEN_STATUS_LABELS, ALARM_STATUS_LABELS,
  AVAILABILITY_STATUS_LABELS, UNAVAILABLE_REASON_LABELS, USAGE_MODE_LABELS,
  ENGINE_REMOTE_START_LABELS
} from '../model/VehicleState';

/**
 * 只读状态快照的一条记录。
 */
export interface SnapshotItem {
  /** 字段名，用作 ForEach 的 key。 */
  key: string;
  /** 展示名。 */
  title: string;
  /** 当前值文案；空串表示未上报。 */
  value: string;
}

/**
 * 只读状态快照的一组记录。
 */
export interface SnapshotGroup {
  /** 组名，用作 ForEach 的 key。 */
  title: string;
  /** 该组的记录。 */
  items: SnapshotItem[];
}

/**
 * 只读状态快照 —— 把车辆各状态域的当前值整理成可展示的分组列表。
 *
 * 与能力探测是两回事：
 *   能力探测回答「这台车支持哪些功能」
 *   状态快照回答「这台车现在是什么状态」
 *
 * 数据来自 gRPC 的 vehiclestates 各域（外饰 / 电池 / 里程 / 空调 / 净化 / 健康 /
 * 可用性 / 远程启动），由 VehicleStateReader.readSnapshot 一次性读取。
 */
export class VehicleSnapshot {
  /**
   * 分组标题。与能力分组的顺序保持一致 —— 便于对照阅读。
   */
  static readonly GROUP_TITLES: string[] = [
    '车身与门窗', '电池与充电', '里程与能耗', '驻车空调', '空气净化', '健康与保养', '车辆可用性'
  ];

  /**
   * 把状态对象整理成分组列表。
   *
   * @param state 状态快照；undefined 时返回空分组
   */
  static groups(state: VehicleState | undefined): SnapshotGroup[] {
    if (state === undefined) {
      return [];
    }
    return [
      { title: '车身与门窗', items: VehicleSnapshot.exteriorItems(state) },
      { title: '电池与充电', items: VehicleSnapshot.batteryItems(state) },
      { title: '里程与能耗', items: VehicleSnapshot.odometerItems(state) },
      { title: '驻车空调', items: VehicleSnapshot.climateItems(state) },
      { title: '空气净化', items: VehicleSnapshot.airItems(state) },
      { title: '健康与保养', items: VehicleSnapshot.healthItems(state) },
      { title: '车辆可用性', items: VehicleSnapshot.availabilityItems(state) }
    ];
  }

  /**
   * 车身与门窗。
   *
   * 机盖（hood）就是极星 2 的前备箱盖 —— 协议里没有独立的 frunk 字段，
   * 车端只上报这一项。
   */
  private static exteriorItems(state: VehicleState): SnapshotItem[] {
    const items: SnapshotItem[] = [];
    items.push(VehicleSnapshot.item('locked', '中控锁', state.locked));
    items.push(VehicleSnapshot.item('tailgate', '尾门', state.tailgate));
    items.push(VehicleSnapshot.item('tailgateLock', '尾门锁', state.tailgateLock));
    items.push(VehicleSnapshot.item('hoodState', '前备箱盖（机盖）',
      VehicleSnapshot.openText(state.hoodState)));
    items.push(VehicleSnapshot.item('chargePortState', '充电口盖',
      VehicleSnapshot.openText(state.chargePortState)));
    items.push(VehicleSnapshot.item('sunroofState', '天窗',
      VehicleSnapshot.openText(state.sunroofState)));
    items.push(VehicleSnapshot.item('alarmState', '报警状态',
      VehicleSnapshot.label(state.alarmState, ALARM_STATUS_LABELS)));
    items.push(VehicleSnapshot.item('doors', '四门', VehicleSnapshot.doorText(state.doorStates)));
    items.push(VehicleSnapshot.item('windows', '四窗', VehicleSnapshot.windowText(state.windowStates)));
    return items;
  }

  /**
   * 电池与充电。
   */
  private static batteryItems(state: VehicleState): SnapshotItem[] {
    const items: SnapshotItem[] = [];
    items.push(VehicleSnapshot.percent('battery', '电量', state.battery));
    items.push(VehicleSnapshot.percent('range', '续航', state.range));
    items.push(VehicleSnapshot.item('charging', '充电状态', state.charging));
    items.push(VehicleSnapshot.item('chargerConnection', '充电枪', state.chargerConnection));
    items.push(VehicleSnapshot.item('chargingType', '充电类型', state.chargingType));
    items.push(VehicleSnapshot.item('chargerPowerStatus', '充电桩供电', state.chargerPowerStatus));
    items.push(VehicleSnapshot.number('powerWatts', '充电功率', state.powerWatts, ' W'));
    items.push(VehicleSnapshot.number('currentAmps', '充电电流', state.currentAmps, ' A'));
    items.push(VehicleSnapshot.number('timeToFullMinutes', '充满剩余', state.timeToFullMinutes, ' 分钟'));
    items.push(VehicleSnapshot.number('targetSoc', '充电上限', state.targetSoc > 0 ? state.targetSoc : undefined, ' %'));
    items.push(VehicleSnapshot.number('ampLimit', '电流上限', state.ampLimit > 0 ? state.ampLimit : undefined, ' A'));
    items.push(VehicleSnapshot.item('chargeTimer', '预约充电时段',
      VehicleSnapshot.timerText(state.chargeTimerActivated,
        state.chargeTimerStartMinutes, state.chargeTimerStopMinutes)));
    return items;
  }

  /**
   * 里程与能耗。
   */
  private static odometerItems(state: VehicleState): SnapshotItem[] {
    const items: SnapshotItem[] = [];
    items.push(VehicleSnapshot.number('odometerKm', '总里程', state.odometerKm, ' km'));
    items.push(VehicleSnapshot.number('tripManualKm', '手动小计', state.tripManualKm, ' km'));
    items.push(VehicleSnapshot.number('tripAutomaticKm', '自动小计', state.tripAutomaticKm, ' km'));
    items.push(VehicleSnapshot.number('tripSinceChargeKm', '自充电小计', state.tripSinceChargeKm, ' km'));
    items.push(VehicleSnapshot.number('manualAverageSpeedKph', '手动均速', state.manualAverageSpeedKph, ' km/h'));
    items.push(VehicleSnapshot.number('automaticAverageSpeedKph', '自动均速', state.automaticAverageSpeedKph, ' km/h'));
    items.push(VehicleSnapshot.number('sinceChargeAverageSpeedKph', '自充电均速',
      state.sinceChargeAverageSpeedKph, ' km/h'));
    items.push(VehicleSnapshot.number('tripManualEnergyWh', '手动能耗', state.tripManualEnergyWh, ' Wh'));
    items.push(VehicleSnapshot.number('tripAutomaticEnergyWh', '自动能耗', state.tripAutomaticEnergyWh, ' Wh'));
    items.push(VehicleSnapshot.number('tripSinceChargeEnergyWh', '自充电能耗',
      state.tripSinceChargeEnergyWh, ' Wh'));
    items.push(VehicleSnapshot.number('tripManualAverageEnergyKwhPer100Km', '手动平均能耗',
      state.tripManualAverageEnergyKwhPer100Km, ' kWh/100km'));
    items.push(VehicleSnapshot.number('tripAutomaticAverageEnergyKwhPer100Km', '自动平均能耗',
      state.tripAutomaticAverageEnergyKwhPer100Km, ' kWh/100km'));
    items.push(VehicleSnapshot.number('tripSinceChargeAverageEnergyKwhPer100Km', '自充电平均能耗',
      state.tripSinceChargeAverageEnergyKwhPer100Km, ' kWh/100km'));
    return items;
  }

  /**
   * 驻车空调。
   */
  private static climateItems(state: VehicleState): SnapshotItem[] {
    const items: SnapshotItem[] = [];
    items.push(VehicleSnapshot.item('climate', '空调状态', state.climate));
    items.push(VehicleSnapshot.item('climateRunMode', '运行模式', state.climateRunMode));
    items.push(VehicleSnapshot.number('climateRuntimeMinutes', '剩余时间', state.climateRuntimeMinutes, ' 分钟'));
    items.push(VehicleSnapshot.number('climateTemperatureC', '当前温度', state.climateTemperatureC, ' °C'));
    items.push(VehicleSnapshot.number('climateTargetTemperatureC', '目标温度', state.climateTargetTemperatureC, ' °C'));
    items.push(VehicleSnapshot.item('climateStartReason', '启动原因',
      VehicleSnapshot.climateReason(state.climateStartReason)));
    items.push(VehicleSnapshot.item('climateEndingAt', '结束时刻',
      VehicleSnapshot.timeText(state.climateEndingAt)));
    items.push(VehicleSnapshot.item('climateErrors', '空调错误',
      VehicleSnapshot.climateErrorText(state.climateErrors)));
    return items;
  }

  /**
   * 空气净化。
   */
  private static airItems(state: VehicleState): SnapshotItem[] {
    const items: SnapshotItem[] = [];
    items.push(VehicleSnapshot.item('air', '净化状态', state.air));
    items.push(VehicleSnapshot.number('airQualityIndex', '舱内 AQI', state.airQualityIndex, ''));
    items.push(VehicleSnapshot.number('pm25UgM3', '舱内 PM2.5', state.pm25UgM3, ' μg/m³'));
    items.push(VehicleSnapshot.number('airRuntimeMinutes', '剩余时间', state.airRuntimeMinutes, ' 分钟'));
    return items;
  }

  /**
   * 健康与保养。
   */
  private static healthItems(state: VehicleState): SnapshotItem[] {
    const items: SnapshotItem[] = [];
    items.push(VehicleSnapshot.item('healthStatus', '健康总评', state.healthStatus));
    items.push(VehicleSnapshot.item('maintenanceStatus', '保养状态', state.maintenanceStatus));
    items.push(VehicleSnapshot.number('serviceRemainingDays', '保养剩余天数', state.serviceRemainingDays, ' 天'));
    items.push(VehicleSnapshot.number('serviceRemainingKm', '保养剩余里程', state.serviceRemainingKm, ' km'));
    items.push(VehicleSnapshot.number('serviceRemainingHours', '保养剩余工时', state.serviceRemainingHours, ' 小时'));
    items.push(VehicleSnapshot.item('healthWarnings', '告警明细',
      state.healthWarnings.length > 0 ? state.healthWarnings.join('、') : '无'));
    return items;
  }

  /**
   * 车辆可用性。
   */
  private static availabilityItems(state: VehicleState): SnapshotItem[] {
    const items: SnapshotItem[] = [];
    items.push(VehicleSnapshot.item('availabilityStatus', '可用状态',
      VehicleSnapshot.label(state.availabilityStatus, AVAILABILITY_STATUS_LABELS)));
    items.push(VehicleSnapshot.item('unavailableReason', '不可用原因',
      state.availabilityStatus === 2
        ? VehicleSnapshot.label(state.unavailableReason, UNAVAILABLE_REASON_LABELS)
        : ''));
    items.push(VehicleSnapshot.item('usageMode', '使用模式',
      VehicleSnapshot.label(state.usageMode, USAGE_MODE_LABELS)));
    items.push(VehicleSnapshot.item('engineRemoteStartStatus', '远程启动',
      VehicleSnapshot.label(state.engineRemoteStartStatus, ENGINE_REMOTE_START_LABELS)));
    items.push(VehicleSnapshot.item('engineRemoteStartEndingAt', '远程启动结束',
      VehicleSnapshot.timeText(state.engineRemoteStartEndingAt)));
    items.push(VehicleSnapshot.item('parkedLocation', '最后停车位置',
      VehicleSnapshot.parkedText(state)));
    return items;
  }

  // ---------- 取值辅助 ----------

  /**
   * 一条文本记录。
   */
  private static item(key: string, title: string, value: string): SnapshotItem {
    return { key: key, title: title, value: value };
  }

  /**
   * 一条数值记录。值为 undefined 表示车端未上报。
   */
  private static number(key: string, title: string, value: number | undefined, unit: string): SnapshotItem {
    if (value === undefined || value === null) {
      return { key: key, title: title, value: '' };
    }
    return { key: key, title: title, value: `${value}${unit}` };
  }

  /**
   * 一条百分比记录。
   */
  private static percent(key: string, title: string, value: number | undefined): SnapshotItem {
    if (value === undefined || value === null) {
      return { key: key, title: title, value: '' };
    }
    return { key: key, title: title, value: `${Math.round(value)} %` };
  }

  /**
   * 枚举值转文案。
   */
  private static label(value: number, labels: string[]): string {
    if (value < 0) {
      return '';
    }
    return VehicleState.enumLabel(value, labels);
  }

  /**
   * 开合状态转文案。
   *
   * 协议 Exterior.OpenStatus：0=未指定 1=开启 2=关闭 3=未关严。
   */
  private static openText(value: number): string {
    if (value < 0) {
      return '';
    }
    return VehicleState.enumLabel(value, OPEN_STATUS_LABELS);
  }

  /**
   * 四个车门的状态摘要。
   */
  private static doorText(states: number[]): string {
    const names: string[] = ['左前', '右前', '左后', '右后'];
    const parts: string[] = [];
    for (let i = 0; i < states.length && i < names.length; i++) {
      const text = VehicleSnapshot.openText(states[i]);
      if (text.length > 0 && text !== '未知') {
        parts.push(`${names[i]}${text}`);
      }
    }
    return parts.join(' · ');
  }

  /**
   * 四扇车窗的状态摘要。
   */
  private static windowText(states: number[]): string {
    const names: string[] = ['左前', '右前', '左后', '右后'];
    const parts: string[] = [];
    for (let i = 0; i < states.length && i < names.length; i++) {
      const text = VehicleSnapshot.openText(states[i]);
      if (text.length > 0 && text !== '未知') {
        parts.push(`${names[i]}${text}`);
      }
    }
    return parts.join(' · ');
  }

  /**
   * 预约充电时段文案。
   */
  private static timerText(activated: boolean, startMinutes: number, stopMinutes: number): string {
    if (!activated) {
      return '未启用';
    }
    if (startMinutes < 0 || stopMinutes < 0) {
      return '已启用';
    }
    return `${VehicleSnapshot.clock(startMinutes)} - ${VehicleSnapshot.clock(stopMinutes)}`;
  }

  /**
   * 分钟数转 HH:mm。
   */
  private static clock(minutes: number): string {
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${pad(h)}:${pad(m)}`;
  }

  /**
   * 空调启动原因文案。
   * 协议 ParkingClimatization field 15：0=未指定 1=车内手动 2=远程 3=定时 4=保持空调。
   */
  private static climateReason(reason: number): string {
    if (reason < 0) {
      return '';
    }
    if (reason === 1) {
      return '车内手动';
    }
    if (reason === 2) {
      return '远程启动';
    }
    if (reason === 3) {
      return '定时任务';
    }
    if (reason === 4) {
      return '保持空调';
    }
    return '';
  }

  /**
   * 空调错误文案。
   * 协议里 8 = REACHED_MAX_RUNTIME（撞到车端单次运行时长上限而停机）。
   */
  private static climateErrorText(errors: number[]): string {
    if (errors.length === 0) {
      return '无';
    }
    const parts: string[] = [];
    for (const code of errors) {
      if (code === 8) {
        parts.push('已达单次运行时长上限');
      } else {
        parts.push(`错误码 ${code}`);
      }
    }
    return parts.join('、');
  }

  /**
   * 时刻文案。
   */
  private static timeText(millis: number): string {
    if (millis <= 0) {
      return '';
    }
    const date = new Date(millis);
    const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
      `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  /**
   * 最后停车位置文案。
   */
  private static parkedText(state: VehicleState): string {
    if (state.parkedLatitude === undefined || state.parkedLongitude === undefined) {
      return '';
    }
    const coord = `${state.parkedLatitude.toFixed(5)}, ${state.parkedLongitude.toFixed(5)}`;
    const time = state.parkedTimestamp !== undefined
      ? VehicleSnapshot.timeText(state.parkedTimestamp) : '';
    return time.length > 0 ? `${coord} · ${time}` : coord;
  }
}
