import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Log } from '../../common/Log';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'VehicleVisualStore';

/**
 * 缓存的车辆视觉信息。
 */
export interface VehicleVisualCache {
  /** 缓存所属的车辆 VIN，空串表示没有缓存。 */
  vin: string;
  /** 车辆配置码串（contentCodes）。 */
  codes: string;
}

/**
 * 车辆视觉信息（车身颜色 / 年款 / 轮毂尺寸）的持久化。
 *
 * 这三项都从 contentCodes 解析而来，而 contentCodes 是车辆静态配置 ——
 * 不会随电量、位置这些动态数据变化，因此没必要每次启动都等网络。
 *
 * 不缓存的话，冷启动时副行会先显示兜底文案（「极星2」），
 * 网络回来后才跳成「月光银 · 2024 款 · 20 寸轮毂」，看着像闪了一下。
 *
 * 按 VIN 分开存 —— 账号里换车时旧车的配置不能套到新车上。
 */
export class VehicleVisualStore {
  /** Preferences 存储名。 */
  static readonly STORE_NAME: string = 'vehicle_visual';

  /** 最近一次使用的 VIN。 */
  static readonly KEY_LAST_VIN: string = 'last_vin';

  private static store: preferences.Preferences | undefined = undefined;

  /**
   * 获取（并缓存）Preferences 实例。
   */
  static async open(context: common.Context): Promise<preferences.Preferences> {
    if (VehicleVisualStore.store !== undefined) {
      return VehicleVisualStore.store;
    }
    VehicleVisualStore.store = await preferences.getPreferences(context, VehicleVisualStore.STORE_NAME);
    return VehicleVisualStore.store;
  }

  /** 按 VIN 存放配置码的键前缀。 */
  private static keyOf(vin: string): string {
    return `codes_${vin}`;
  }

  /**
   * 同步读取最近一次车辆的配置码。
   *
   * 冷启动要在首帧就用上缓存内容，不能 await ——
   * 所以走 Preferences 的同步接口。数据量只有一个字符串，读取很快。
   *
   * @param context 上下文
   * @returns 缓存的配置码与它所属的 VIN；没有缓存时 VIN 与配置码都是空串
   */
  static loadSync(context: common.Context): VehicleVisualCache {
    try {
      const store = preferences.getPreferencesSync(context, { name: VehicleVisualStore.STORE_NAME });
      const vin = store.getSync(VehicleVisualStore.KEY_LAST_VIN, '') as string;
      if (vin.length === 0) {
        return { vin: '', codes: '' };
      }
      const codes = store.getSync(VehicleVisualStore.keyOf(vin), '') as string;
      return { vin: vin, codes: codes };
    } catch (err) {
      Log.warn(TAG, `同步读取车辆视觉信息失败: ${(err as Error).message}`);
      return { vin: '', codes: '' };
    }
  }

  /**
   * 保存配置码。
   *
   * @param context  上下文
   * @param vin      车辆 VIN
   * @param codes    配置码串（contentCodes）
   */
  static async save(context: common.Context, vin: string, codes: string): Promise<void> {
    if (vin.length === 0 || codes.length === 0) {
      return;
    }
    try {
      const store = await VehicleVisualStore.open(context);
      await store.put(VehicleVisualStore.keyOf(vin), codes);
      await store.put(VehicleVisualStore.KEY_LAST_VIN, vin);
      await store.flush();
    } catch (err) {
      Log.warn(TAG, `保存车辆视觉信息失败: ${(err as Error).message}`);
    }
  }
}
