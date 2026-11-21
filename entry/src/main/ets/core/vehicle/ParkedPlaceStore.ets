import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Log } from '../../common/Log';
import { ParkedPlaceInfo, ParkedPlacePlain } from './ParkedPlaceInfo';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'ParkedPlaceStore';

/**
 * 停车地点的持久化。
 *
 * 停车位置通常长时间不变，反查一次就够 —— 每次进应用都重新请求
 * 既是浪费（地理编码有配额），也会让副信息在首屏闪一下才稳定。
 * 这里把「坐标 + 解析结果」一起落盘，下次进来坐标没变就直接复用。
 */
export class ParkedPlaceStore {
  /** Preferences 存储名。 */
  private static readonly STORE_NAME: string = 'parked_place';

  /** 坐标键。 */
  private static readonly KEY_LATITUDE: string = 'latitude';
  private static readonly KEY_LONGITUDE: string = 'longitude';
  /**
   * 解析结果键（JSON 串）。
   *
   * v2：解析结果里新增了行政区划（省 / 市 / 区 / 镇）。
   * 旧缓存没有这些字段，直接复用会导致地址前缀缺失，
   * 所以换键让旧缓存自然失效、重新反查一次。
   */
  private static readonly KEY_INFO: string = 'info_v2';

  private static store: preferences.Preferences | undefined = undefined;

  /**
   * 获取（并缓存）Preferences 实例。
   */
  private static async open(context: common.Context): Promise<preferences.Preferences> {
    if (ParkedPlaceStore.store !== undefined) {
      return ParkedPlaceStore.store;
    }
    ParkedPlaceStore.store = await preferences.getPreferences(context, ParkedPlaceStore.STORE_NAME);
    return ParkedPlaceStore.store;
  }

  /**
   * 读取已缓存的解析结果。
   *
   * 坐标比对走距离容差，不是逐位相等 —— 车辆上报的坐标带 GPS 抖动，
   * 同一个车位每次都可能差几米。
   *
   * @param context   上下文
   * @param latitude  当前纬度
   * @param longitude 当前经度
   * @returns 位置没挪动时返回缓存结果，否则返回 undefined
   */
  static async load(context: common.Context, latitude: number, longitude: number):
    Promise<ParkedPlaceInfo | undefined> {
    try {
      const store = await ParkedPlaceStore.open(context);
      const lat = await store.get(ParkedPlaceStore.KEY_LATITUDE, -1) as number;
      const lon = await store.get(ParkedPlaceStore.KEY_LONGITUDE, -1) as number;
      if (ParkedPlaceInfo.moved(lat, lon, latitude, longitude)) {
        return undefined;
      }
      const raw = await store.get(ParkedPlaceStore.KEY_INFO, '') as string;
      if (raw.length === 0) {
        return undefined;
      }
      const parsed = JSON.parse(raw) as ParkedPlacePlain;
      return ParkedPlaceInfo.fromPlain(parsed);
    } catch (err) {
      Log.warn(TAG, `读取缓存的停车地点失败: ${(err as Error).message}`);
      return undefined;
    }
  }

  /**
   * 写入解析结果。
   */
  static async save(context: common.Context, latitude: number, longitude: number,
    info: ParkedPlaceInfo): Promise<void> {
    try {
      const store = await ParkedPlaceStore.open(context);
      await store.put(ParkedPlaceStore.KEY_LATITUDE, latitude);
      await store.put(ParkedPlaceStore.KEY_LONGITUDE, longitude);
      await store.put(ParkedPlaceStore.KEY_INFO, JSON.stringify(info.toPlain()));
      await store.flush();
    } catch (err) {
      Log.warn(TAG, `缓存停车地点失败: ${(err as Error).message}`);
    }
  }
}
