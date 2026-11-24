import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { VehicleCapability } from './VehicleCapability';
import { Log } from '../../common/Log';

const TAG: string = 'VehicleCapabilityStore';

/**
 * 车辆能力快照持久化 —— 按 VIN 分键存进 Preferences。
 *
 * 与 VehicleVisualStore 同风格：同步读（冷启动用）、异步写。
 * 能力快照体积不大（几百字节），整条 JSON 存一个键即可。
 */
export class VehicleCapabilityStore {
  /** Preferences 存储名。 */
  static readonly STORE_NAME: string = 'vehicle_capability';

  /** 最近一次探测的 VIN。 */
  static readonly KEY_LAST_VIN: string = 'last_vin';

  private static store: preferences.Preferences | undefined = undefined;

  /**
   * 获取（并缓存）Preferences 实例。
   */
  static async open(context: common.Context): Promise<preferences.Preferences> {
    if (VehicleCapabilityStore.store !== undefined) {
      return VehicleCapabilityStore.store;
    }
    VehicleCapabilityStore.store = await preferences.getPreferences(context, VehicleCapabilityStore.STORE_NAME);
    return VehicleCapabilityStore.store;
  }

  /**
   * 能力快照的键名。按 VIN 分键，换车不会串。
   */
  private static keyOf(vin: string): string {
    return `cap_${vin}`;
  }

  /**
   * 同步读取最近一次探测到的能力快照。
   *
   * 冷启动首帧要用，所以必须是同步接口。
   */
  static loadSync(context: common.Context): VehicleCapability | undefined {
    try {
      const store = preferences.getPreferencesSync(context, { name: VehicleCapabilityStore.STORE_NAME });
      const vin = store.getSync(VehicleCapabilityStore.KEY_LAST_VIN, '') as string;
      if (vin.length === 0) {
        return undefined;
      }
      const raw = store.getSync(VehicleCapabilityStore.keyOf(vin), '') as string;
      if (raw.length === 0) {
        return undefined;
      }
      return VehicleCapability.fromJson(raw);
    } catch (err) {
      Log.warn(TAG, `同步读取能力快照失败: ${(err as Error).message}`);
      return undefined;
    }
  }

  /**
   * 读取指定 VIN 的能力快照。
   */
  static async load(context: common.Context, vin: string): Promise<VehicleCapability | undefined> {
    try {
      const store = await VehicleCapabilityStore.open(context);
      const raw = await store.get(VehicleCapabilityStore.keyOf(vin), '') as string;
      if (raw.length === 0) {
        return undefined;
      }
      return VehicleCapability.fromJson(raw);
    } catch (err) {
      Log.warn(TAG, `读取能力快照失败: ${(err as Error).message}`);
      return undefined;
    }
  }

  /**
   * 保存能力快照。
   */
  static async save(context: common.Context, capability: VehicleCapability): Promise<void> {
    if (capability.vin.length === 0) {
      return;
    }
    try {
      const store = await VehicleCapabilityStore.open(context);
      await store.put(VehicleCapabilityStore.keyOf(capability.vin), capability.toJson());
      await store.put(VehicleCapabilityStore.KEY_LAST_VIN, capability.vin);
      await store.flush();
      Log.info(TAG, `已保存能力快照: ${capability.vin}（探测时间 ${capability.detectedAt}）`);
    } catch (err) {
      Log.warn(TAG, `保存能力快照失败: ${(err as Error).message}`);
    }
  }

  /**
   * 删除指定 VIN 的能力快照。
   */
  static async remove(context: common.Context, vin: string): Promise<void> {
    try {
      const store = await VehicleCapabilityStore.open(context);
      await store.delete(VehicleCapabilityStore.keyOf(vin));
      await store.flush();
    } catch (err) {
      Log.warn(TAG, `删除能力快照失败: ${(err as Error).message}`);
    }
  }
}
