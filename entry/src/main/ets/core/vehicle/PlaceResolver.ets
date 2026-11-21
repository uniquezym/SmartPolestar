import { common } from '@kit.AbilityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { BusinessError, Log } from '../../common/Log';
import { CoordinateTransform } from './CoordinateTransform';
import { MapKitPlaceResolver } from './MapKitPlaceResolver';
import { ParkedPlaceInfo } from './ParkedPlaceInfo';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'PlaceResolver';

/**
 * 经纬度反查地点信息。
 *
 * 两条数据源，Map Kit 优先，系统逆地理编码兜底：
 *   ① Map Kit 逆地理编码 —— 能拿到 AOI（小区 / 园区）、POI（停车场 / 商场）与道路名，
 *      精度最高。权益未开通或调用失败时自动降级。
 *   ② 系统 geoLocationManager 逆地理编码 —— 无需任何授权，但只能到路名级。
 *   ③ 都失败 → 返回 undefined，UI 回退显示原始坐标。
 *
 * 【坐标系】
 *   - 系统逆地理编码只接受 WGS84，所以这条路径要先 GCJ02 → WGS84。
 *     不转换的话查询点会偏出去几百米，结果退化成只返回到区级。
 *   - Map Kit 大陆区底图就是 GCJ02，直接传原始坐标，不转换。
 */
export class PlaceResolver {
  /** 缓存键的坐标精度（保留 5 位小数，约 1m 级）。 */
  private static readonly PRECISION: number = 100000;
  /** 坐标 → 地点信息 的缓存。 */
  private static readonly cache: Map<string, ParkedPlaceInfo> = new Map<string, ParkedPlaceInfo>();

  /**
   * 反查坐标对应的地点信息。
   *
   * @param context   上下文（Map Kit 需要）
   * @param latitude  纬度（GCJ02）
   * @param longitude 经度（GCJ02）
   * @returns 地点信息；无法解析时返回 undefined
   */
  static async resolve(context: common.Context, latitude: number, longitude: number):
    Promise<ParkedPlaceInfo | undefined> {
    const key = PlaceResolver.cacheKey(latitude, longitude);
    const cached = PlaceResolver.cache.get(key);
    if (cached !== undefined) {
      return cached;
    }

    // ① Map Kit
    const mapKit = await MapKitPlaceResolver.resolve(context, latitude, longitude);
    if (mapKit !== undefined && !mapKit.isEmpty()) {
      PlaceResolver.cache.set(key, mapKit);
      return mapKit;
    }

    // ② 系统逆地理编码兜底
    const system = await PlaceResolver.resolveBySystem(latitude, longitude);
    if (system !== undefined) {
      PlaceResolver.cache.set(key, system);
      return system;
    }

    return undefined;
  }

  /**
   * 系统逆地理编码兜底。只拿得到路名级信息，没有 AOI / POI 概念。
   */
  private static async resolveBySystem(latitude: number, longitude: number):
    Promise<ParkedPlaceInfo | undefined> {
    try {
      if (!geoLocationManager.isGeocoderAvailable()) {
        Log.warn(TAG, '系统地理编码服务不可用');
        return undefined;
      }
      // GCJ02 → WGS84：不转换的话查询点会偏出去几百米，
      // 系统只能反查到区级（placeName 形如「中国上海市青浦区」）。
      const wgs = CoordinateTransform.gcj2Wgs(latitude, longitude);

      const request: geoLocationManager.ReverseGeoCodeRequest = {
        locale: 'zh',
        latitude: wgs[0],
        longitude: wgs[1],
        maxItems: 1
      };
      const addresses = await geoLocationManager.getAddressesFromLocation(request);
      if (addresses.length === 0) {
        Log.warn(TAG, '反查地点名没有返回结果');
        return undefined;
      }

      // 取「详细地址」字段（placeName）。对齐官方示例：只用第一条结果。
      let name = addresses[0].placeName !== undefined ? addresses[0].placeName : '';
      if (name.length === 0) {
        name = PlaceResolver.fallback(addresses[0]);
      }

      Log.info(TAG, `系统反查地点名结果: ${name} | ${PlaceResolver.dump(addresses[0])}`);
      if (name.length === 0) {
        return undefined;
      }

      const info = new ParkedPlaceInfo();
      info.address = name;
      if (addresses[0].roadName !== undefined) {
        info.roadName = addresses[0].roadName;
      }
      // 系统逆地理编码也给行政区划：administrativeArea 是省，
      // locality 是市，subAdministrativeArea 是区县，subLocality 是街道。
      info.province = addresses[0].administrativeArea ?? '';
      info.city = addresses[0].locality ?? '';
      info.district = addresses[0].subAdministrativeArea ?? '';
      info.town = addresses[0].subLocality ?? '';
      return info;
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(TAG, `系统反查地点名失败: code=${e.code} ${e.message}`);
      return undefined;
    }
  }

  /**
   * 兜底：descriptions 的首项。
   */
  private static fallback(address: geoLocationManager.GeoAddress): string {
    if (address.descriptions !== undefined && address.descriptions.length > 0) {
      return address.descriptions[0];
    }
    if (address.placeName !== undefined) {
      return address.placeName;
    }
    return '';
  }

  /**
   * 打印地理编码返回的原始字段，便于诊断地址精度。
   */
  private static dump(address: geoLocationManager.GeoAddress): string {
    return `province=${address.administrativeArea ?? ''}` +
      ` city=${address.locality ?? ''}` +
      ` district=${address.subAdministrativeArea ?? ''}` +
      ` street=${address.subLocality ?? ''}` +
      ` road=${address.roadName ?? ''}` +
      ` subRoad=${address.subRoadName ?? ''}` +
      ` premises=${address.premises ?? ''}` +
      ` placeName=${address.placeName ?? ''}` +
      ` desc=${address.descriptions !== undefined ? address.descriptions.join('|') : ''}`;
  }

  /**
   * 缓存键。
   */
  private static cacheKey(latitude: number, longitude: number): string {
    const lat = Math.round(latitude * PlaceResolver.PRECISION) / PlaceResolver.PRECISION;
    const lon = Math.round(longitude * PlaceResolver.PRECISION) / PlaceResolver.PRECISION;
    return `${lat},${lon}`;
  }
}
