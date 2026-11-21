import { common } from '@kit.AbilityKit';
import { site } from '@kit.MapKit';
import { BusinessError, Log } from '../../common/Log';
import { ParkedPlaceInfo } from './ParkedPlaceInfo';

/**
 * Map Kit 逆地理编码 —— 拿停车点的 AOI / POI / 道路名。
 *
 * 【坐标系】车辆接口返回的是 GCJ02 坐标。Map Kit 大陆区服务的底图就是 GCJ02，
 * 且 reverseGeocode 的 location 参数只有经纬度、没有坐标系标记，
 * 因此这里直接传车辆原始坐标，不做 GCJ02 → WGS84 转换。
 *
 * 【错误码】
 *   401          —— 参数非法
 *   1002600001   —— 系统内部错误
 *   1002600002   —— 连不上 Map Kit 服务器
 *   1002600003   —— 应用鉴权失败（AGC 侧 bundleName 未关联）
 *   1002600004   —— Map 权益未开通
 *   1002603001   —— 零结果
 */
export class MapKitPlaceResolver {
  /** 搜索半径（米）。上限 1000。 */
  private static readonly RADIUS: number = 1000;

  /**
   * 反查坐标对应的 AOI / POI。
   *
   * @param context   上下文（Map Kit 需要）
   * @param latitude  纬度（GCJ02）
   * @param longitude 经度（GCJ02）
   * @returns 结果；失败或零结果时返回 undefined
   */
  static async resolve(context: common.Context, latitude: number, longitude: number):
    Promise<ParkedPlaceInfo | undefined> {
    try {
      const params: site.ReverseGeocodeParams = {
        location: { latitude: latitude, longitude: longitude },
        radius: MapKitPlaceResolver.RADIUS,
        language: 'zh',
        // 不开这个开关只返回地址，不返回 POI / AOI / 道路。
        isExtension: true,
        // 返回附近 AOI（小区、园区这类地块）。
        isNearbyAoi: true,
        sortRule: site.SortRule.DISTANCE
      };

      const result = await site.reverseGeocode(context, params);
      const info = MapKitPlaceResolver.pick(result);
      Log.info(`Map Kit 反查结果: ${info.displayName()} | ${MapKitPlaceResolver.dump(result)}`);
      return info;
    } catch (err) {
      const e = err as BusinessError;
      // 权益未开通 / 鉴权失败时降级到系统逆地理编码，不打断概览页。
      Log.warn(`Map Kit 反查失败: code=${e.code} ${e.message}`);
      return undefined;
    }
  }

  /**
   * 从返回结果里挑最近的 AOI / POI / 道路。
   *
   * 全量保留，展示层再决定取哪一项。
   */
  private static pick(result: site.ReverseGeocodeResult): ParkedPlaceInfo {
    const info = new ParkedPlaceInfo();

    const aois = result.aois !== undefined ? result.aois : [];
    if (aois.length > 0) {
      const aoi = aois[0];
      info.aoiName = aoi.name !== undefined ? aoi.name : '';
      if (aoi.poiType !== undefined) {
        info.aoiType = aoi.poiType;
      }
      if (aoi.distance !== undefined) {
        info.distance = aoi.distance;
      }
    }

    const pois = result.pois !== undefined ? result.pois : [];
    if (pois.length > 0) {
      const poi = pois[0];
      info.poiName = poi.name !== undefined ? poi.name : '';
      if (poi.poiType !== undefined && poi.poiType.length > 0) {
        info.poiType = poi.poiType;
      }
      if (poi.address !== undefined) {
        info.address = poi.address;
      }
      if (info.distance < 0 && poi.distance !== undefined) {
        info.distance = poi.distance;
      }
    }

    const roads = result.roads !== undefined ? result.roads : [];
    if (roads.length > 0 && roads[0].name !== undefined) {
      info.roadName = roads[0].name;
    }

    if (info.address.length === 0 && result.addressDescription.length > 0) {
      info.address = result.addressDescription;
    }

    return info;
  }

  /**
   * 打印原始返回，便于诊断字段缺失。
   */
  private static dump(result: site.ReverseGeocodeResult): string {
    const aois = result.aois !== undefined ? result.aois : [];
    const pois = result.pois !== undefined ? result.pois : [];
    const roads = result.roads !== undefined ? result.roads : [];
    const aoiNames: string[] = [];
    for (const aoi of aois) {
      aoiNames.push(`${aoi.name ?? ''}(${aoi.distance ?? -1})`);
    }
    const poiNames: string[] = [];
    for (const poi of pois) {
      poiNames.push(`${poi.name ?? ''}(${poi.distance ?? -1})`);
    }
    const roadNames: string[] = [];
    for (const road of roads) {
      roadNames.push(road.name ?? '');
    }
    return `aoi=[${aoiNames.join('|')}] poi=[${poiNames.join('|')}] road=[${roadNames.join('|')}]` +
      ` desc=${result.addressDescription}`;
  }
}
