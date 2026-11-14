import { geoLocationManager } from '@kit.LocationKit';
import { BusinessError, Log } from '../../common/Log';
import { CoordinateTransform } from './CoordinateTransform';

/**
 * 经纬度反查地点名。
 *
 * 使用系统自带的地理编码能力（geoLocationManager），无需 API Key。
 * 结果只用于「最后停车位置」的补充说明，拿不到时降级显示原始坐标。
 *
 * 【坐标系】车辆接口返回的是 GCJ02 坐标，而系统逆地理编码只接受 WGS84。
 * 直接传原始坐标会偏出几百米，导致逆地理编码只返回到区级。
 * 因此这里先把 GCJ02 转成 WGS84 再查询。
 */
export class PlaceResolver {
  /** 缓存键的坐标精度（保留 5 位小数，约 1m 级）。 */
  private static readonly PRECISION: number = 100000;
  /** 坐标 → 地点名 的缓存。 */
  private static readonly cache: Map<string, string> = new Map<string, string>();

  /**
   * 反查坐标对应的地点名称。
   *
   * @param latitude  纬度（GCJ02）
   * @param longitude 经度（GCJ02）
   * @returns 地点名；无法解析时返回空字符串
   */
  static async resolve(latitude: number, longitude: number): Promise<string> {
    const key = PlaceResolver.cacheKey(latitude, longitude);
    const cached = PlaceResolver.cache.get(key);
    if (cached !== undefined) {
      return cached;
    }

    try {
      if (!geoLocationManager.isGeocoderAvailable()) {
        Log.warn('系统地理编码服务不可用');
        return '';
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
        Log.warn('反查地点名没有返回结果');
        return '';
      }

      // 取「详细地址」字段（placeName）。对齐官方示例：只用第一条结果。
      let name = addresses[0].placeName !== undefined ? addresses[0].placeName : '';
      if (name.length === 0) {
        name = PlaceResolver.fallback(addresses[0]);
      }

      Log.info(`反查地点名结果: ${name} | ${PlaceResolver.dump(addresses[0])}`);

      if (name.length > 0) {
        PlaceResolver.cache.set(key, name);
      }
      return name;
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`反查地点名失败: code=${e.code} ${e.message}`);
      return '';
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
