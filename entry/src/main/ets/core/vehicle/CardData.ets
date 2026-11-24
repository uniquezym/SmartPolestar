import { WidgetSnapshot } from './WidgetStore';
import { CARD_OP_TTL_MS } from './CardConstants';
import { ChargeStage, ChargeStageResolver } from '../model/VehicleState';

/**
 * 桌面卡片的数据键名。
 *
 * 卡片页面用 `@LocalStorageProp('cardXxx')` 接收 updateForm 推送的数据，
 * **键名必须与 CardBinding 的字段名完全一致**，否则推送不会生效。
 *
 * 说明：ArkTS 的对象字面量不支持计算属性名，因此 CardBinding 的字段
 * 直接写成字面量标识符，此处常量仅作为键名的说明与对照。
 */
export class CardKeys {
  /** 车型名。 */
  static readonly MODEL_NAME: string = 'cardModelName';
  /** 电量百分比。 */
  static readonly BATTERY: string = 'cardBattery';
  /** 预计续航（公里）。 */
  static readonly RANGE: string = 'cardRange';
  /** 充电信息行文案。 */
  static readonly CHARGE_TEXT: string = 'cardChargeText';
  /** 充电信息行是否显示。 */
  static readonly CHARGE_VISIBLE: string = 'cardChargeVisible';
  /** 车锁状态文案。 */
  static readonly LOCK_TEXT: string = 'cardLockText';
  /** 驻车空调状态文案。 */
  static readonly CLIMATE_TEXT: string = 'cardClimateText';
  /** 操作结果文案。 */
  static readonly OP_TEXT: string = 'cardOpText';
  /** 操作结果是否显示。 */
  static readonly OP_VISIBLE: string = 'cardOpVisible';
  /** 操作结果产生时刻。 */
  static readonly OP_AT: string = 'cardOpAt';
  /** 快照时刻（epoch millis）。 */
  static readonly UPDATED_AT: string = 'cardUpdatedAt';
}

/**
 * 推送给卡片页面的绑定数据。
 *
 * 字段名即卡片页 `@LocalStorageProp('xxx')` 的键名，两边必须完全一致。
 */
export class CardBinding {
  /** 车型名，如「极星2」。 */
  cardModelName: string;
  /** 电量百分比，-1 表示未知。 */
  cardBattery: number;
  /** 预计续航（公里），-1 表示未知。 */
  cardRange: number;
  /** 充电信息行文案。 */
  cardChargeText: string;
  /** 充电信息行是否显示。 */
  cardChargeVisible: boolean;
  /** 车锁状态文案。 */
  cardLockText: string;
  /** 驻车空调状态文案。 */
  cardClimateText: string;
  /** 操作结果文案。 */
  cardOpText: string;
  /** 操作结果是否显示。 */
  cardOpVisible: boolean;
  /** 操作结果产生时刻（epoch millis）。 */
  cardOpAt: number;
  /** 快照时刻（epoch millis）。 */
  cardUpdatedAt: number;

  constructor(modelName: string, battery: number, range: number, chargeText: string,
    chargeVisible: boolean, lockText: string, climateText: string,
    opText: string, opVisible: boolean, opAt: number, updatedAt: number) {
    this.cardModelName = modelName;
    this.cardBattery = battery;
    this.cardRange = range;
    this.cardChargeText = chargeText;
    this.cardChargeVisible = chargeVisible;
    this.cardLockText = lockText;
    this.cardClimateText = climateText;
    this.cardOpText = opText;
    this.cardOpVisible = opVisible;
    this.cardOpAt = opAt;
    this.cardUpdatedAt = updatedAt;
  }
}

/**
 * 卡片上显示的一组数据。
 *
 * 全部是**已格式化的字符串 / 数值**，卡片页面只负责呈现，
 * 不做任何协议解析 —— 避免卡片与主应用两套判定逻辑产生分歧。
 */
export interface CardDisplay {
  /** 车型名，如「极星2」。 */
  modelName: string;
  /** 电量百分比，-1 表示未知。 */
  battery: number;
  /** 预计续航（公里），-1 表示未知。 */
  range: number;
  /** 充电信息行文案，空串表示无内容。 */
  chargeText: string;
  /** 充电信息行是否显示（未充电时隐藏但保留占位）。 */
  chargeVisible: boolean;
  /** 车锁状态文案：已锁 / 未锁 / —。 */
  lockText: string;
  /** 驻车空调状态文案：空调开 / 空调关 / —。 */
  climateText: string;
  /** 操作结果文案，空串表示没有待展示的结果。 */
  opText: string;
  /** 操作结果是否显示。 */
  opVisible: boolean;
  /** 操作结果产生时刻（epoch millis），0 表示没有结果。 */
  opAt: number;
  /** 快照时刻（epoch millis），0 表示尚未同步。 */
  updatedAt: number;
}

/**
 * 卡片数据转换。
 *
 * 把原始状态快照转成卡片要显示的内容，规则与主应用共用
 * ChargeStageResolver，保证两边显示的充电状态一致。
 */
export class CardData {
  /**
   * 由原始快照生成显示数据。
   *
   * @param snapshot 主应用写入的状态快照
   */
  static display(snapshot: WidgetSnapshot): CardDisplay {
    const stage = ChargeStageResolver.resolve(snapshot.charging, snapshot.chargerConnection);
    const detail = ChargeStageResolver.text(stage, snapshot.powerWatts, snapshot.currentAmps,
      snapshot.remainingMinutes);

    // 放电中没有插着充电枪，不占充电信息行。
    // 其余阶段（充电中 / 已插枪 / 已暂停 / 已完成 / 故障）都算「充电相关」，
    // 与主应用电量区的 inline 提示保持同一套判定。
    const visible = stage !== ChargeStage.IDLE && stage !== ChargeStage.DISCHARGING;

    let chargeText = '';
    if (visible) {
      // 充电中时 detail 是「功率 · 电流 · 剩余时长」，前面补上阶段名。
      chargeText = (stage === ChargeStage.CHARGING && detail.length > 0)
        ? `充电中 · ${detail}`
        : detail;
    }

    // 操作结果只在卡片上停留一小段时间，过期后自动隐去。
    const opAlive = snapshot.opVisible && snapshot.opAt > 0 &&
      (Date.now() - snapshot.opAt) < CARD_OP_TTL_MS;

    return {
      modelName: snapshot.modelName.length > 0 ? snapshot.modelName : '极星2',
      battery: snapshot.battery,
      range: snapshot.range,
      chargeText: chargeText,
      chargeVisible: visible,
      lockText: CardData.lockText(snapshot.locked),
      climateText: CardData.climateText(snapshot.climate),
      opText: opAlive ? snapshot.opText : '',
      opVisible: opAlive,
      opAt: snapshot.opAt,
      updatedAt: snapshot.updatedAt
    };
  }

  /**
   * 车锁状态文案。
   */
  private static lockText(locked: string): string {
    if (locked === '未锁') {
      return '未锁';
    }
    if (locked === '已锁') {
      return '已锁';
    }
    return '—';
  }

  /**
   * 驻车空调状态文案。
   */
  private static climateText(climate: string): string {
    if (climate === '开启') {
      return '空调开';
    }
    if (climate === '关闭') {
      return '空调关';
    }
    return '—';
  }

  /**
   * 生成 updateForm 推送的数据。
   *
   * 顶层键与卡片页面的 @LocalStorageProp 入参一一对应。
   */
  static binding(display: CardDisplay): CardBinding {
    return new CardBinding(
      display.modelName,
      display.battery,
      display.range,
      display.chargeText,
      display.chargeVisible,
      display.lockText,
      display.climateText,
      display.opText,
      display.opVisible,
      display.opAt,
      display.updatedAt
    );
  }

  /**
   * 空数据。卡片刚被添加、尚未收到任何状态时使用。
   */
  static empty(): CardDisplay {
    return {
      modelName: '极星2',
      battery: -1,
      range: -1,
      chargeText: '',
      chargeVisible: false,
      lockText: '—',
      climateText: '—',
      opText: '',
      opVisible: false,
      opAt: 0,
      updatedAt: 0
    };
  }
}
