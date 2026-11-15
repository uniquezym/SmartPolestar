import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Log } from '../../common/Log';

/**
 * 桌面卡片的状态快照存储。
 *
 * 卡片进程（FormExtensionAbility）与主应用进程是分离的，无法共享内存态。
 * 主应用刷新状态后把快照写进 Preferences，再调用 formProvider.updateForm
 * 推送给卡片；卡片被系统拉起时从 Preferences 读快照渲染。
 *
 * 存储名与 Android 端 widget_state 对齐，便于对照。
 */
export class WidgetStore {
  /** Preferences 存储名，与 Android 端 widget_state 同名。 */
  static readonly STORE_NAME: string = 'widget_state';

  /** 快照的键名。 */
  static readonly KEY_SNAPSHOT: string = 'snapshot';

  /**
   * 卡片刷新间隔（分钟）。
   *
   * 常态 30 分钟 —— 车辆静止时电量与续航几乎不变。
   * 充电中由调用方临时改成 5 分钟。
   */
  static readonly REFRESH_MINUTES: number = 30;

  /** 充电中的刷新间隔（分钟）。 */
  static readonly REFRESH_MINUTES_CHARGING: number = 5;

  private static store: preferences.Preferences | undefined = undefined;

  /**
   * 获取（并缓存）Preferences 实例。
   *
   * @param context 卡片或主应用的上下文
   */
  static async open(context: common.Context): Promise<preferences.Preferences> {
    if (WidgetStore.store !== undefined) {
      return WidgetStore.store;
    }
    WidgetStore.store = await preferences.getPreferences(context, WidgetStore.STORE_NAME);
    return WidgetStore.store;
  }

  /**
   * 写入状态快照。
   *
   * @param context 上下文
   * @param snapshot 快照对象
   */
  static async save(context: common.Context, snapshot: WidgetSnapshot): Promise<void> {
    try {
      const store = await WidgetStore.open(context);
      await store.put(WidgetStore.KEY_SNAPSHOT, JSON.stringify(snapshot));
      await store.flush();
    } catch (err) {
      Log.warn(`写入卡片快照失败: ${(err as Error).message}`);
    }
  }

  /**
   * 同步读取状态快照。
   *
   * 卡片添加时（onAddForm）必须同步返回数据，不能 await ——
   * 所以这里用 Preferences 的同步接口。数据量只有一个 JSON 字符串，读取很快。
   *
   * @param context 上下文
   * @returns 快照；不存在或损坏时返回 undefined
   */
  static loadSync(context: common.Context): WidgetSnapshot | undefined {
    try {
      const store = preferences.getPreferencesSync(context, { name: WidgetStore.STORE_NAME });
      const raw = store.getSync(WidgetStore.KEY_SNAPSHOT, '') as string;
      if (raw.length === 0) {
        return undefined;
      }
      const parsed = JSON.parse(raw) as WidgetSnapshot;
      if (parsed === undefined || parsed === null) {
        return undefined;
      }
      return parsed;
    } catch (err) {
      Log.warn(`同步读取卡片快照失败: ${(err as Error).message}`);
      return undefined;
    }
  }

  /**
   * 读取状态快照。
   *
   * @returns 快照；不存在或损坏时返回 undefined
   */
  static async load(context: common.Context): Promise<WidgetSnapshot | undefined> {
    try {
      const store = await WidgetStore.open(context);
      const raw = await store.get(WidgetStore.KEY_SNAPSHOT, '') as string;
      if (raw.length === 0) {
        return undefined;
      }
      const parsed = JSON.parse(raw) as WidgetSnapshot;
      if (parsed === undefined || parsed === null) {
        return undefined;
      }
      return parsed;
    } catch (err) {
      Log.warn(`读取卡片快照失败: ${(err as Error).message}`);
      return undefined;
    }
  }

  /**
   * 清除快照。
   */
  static async clear(context: common.Context): Promise<void> {
    try {
      const store = await WidgetStore.open(context);
      await store.delete(WidgetStore.KEY_SNAPSHOT);
      await store.flush();
    } catch (err) {
      Log.warn(`清除卡片快照失败: ${(err as Error).message}`);
    }
  }
}

/**
 * 卡片状态快照。
 *
 * 字段与卡片上要显示的内容一一对应；主应用每次刷新状态后更新。
 */
export interface WidgetSnapshot {
  /** 车辆 VIN。 */
  vin: string;
  /** 车型名，如「极星2」。 */
  modelName: string;
  /** 电量百分比。 */
  battery: number;
  /** 预计续航（公里）。 */
  range: number;
  /** 充电状态文案。 */
  charging: string;
  /** 充电枪连接状态文案。 */
  chargerConnection: string;
  /** 充电功率（瓦）。 */
  powerWatts: number;
  /** 充电电流（安）。 */
  currentAmps: number;
  /** 充满剩余时长（分钟）。 */
  remainingMinutes: number;
  /** 车锁状态文案：未锁 / 已锁。 */
  locked: string;
  /** 驻车空调状态文案：开启 / 关闭。 */
  climate: string;
  /** 快照生成时刻（epoch millis）。 */
  updatedAt: number;
}
