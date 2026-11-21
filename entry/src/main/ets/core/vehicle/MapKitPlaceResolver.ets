import { common } from '@kit.AbilityKit';
import { site } from '@kit.MapKit';
import { BusinessError, Log } from '../../common/Log';
import { ParkedPlaceInfo } from './ParkedPlaceInfo';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'MapKitPlaceResolver';

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
      Log.info(TAG, `Map Kit 反查结果: ${info.displayName()} | ${MapKitPlaceResolver.dump(result)}`);
      return info;
    } catch (err) {
      const e = err as BusinessError;
      // 权益未开通 / 鉴权失败时降级到系统逆地理编码，不打断概览页。
      Log.warn(TAG, `Map Kit 反查失败: code=${e.code} ${e.message}`);
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

    MapKitPlaceResolver.pickAdmin(info, result.addressComponent);

    return info;
  }

  /**
   * 从 addressComponent 里取行政区划（省 / 市 / 区 / 镇）。
   *
   * Map Kit 的 adminLevel 层级对中国大陆是：
   *   adminLevel1 = 省 / 自治区 / 直辖市
   *   adminLevel2 = 市 / 地区
   *   adminLevel3 = 区 / 县
   *   adminLevel4 = 街道 / 镇
   * 直辖市的省、市同名（「上海市」「上海市」），重复由 adminPath() 去重。
   *
   * 每一级都有兜底：不同区域版本给的字段并不完全一致，
   * 缺哪一级就用 locality / city.cityName / subLocality1 顶上。
   */
  private static pickAdmin(info: ParkedPlaceInfo, component: site.AddressComponent): void {
    info.province = component.adminLevel1 !== undefined ? component.adminLevel1 : '';

    if (component.adminLevel2 !== undefined && component.adminLevel2.length > 0) {
      info.city = component.adminLevel2;
    } else if (component.city !== undefined && component.city.cityName !== undefined) {
      info.city = component.city.cityName;
    }

    if (component.adminLevel3 !== undefined && component.adminLevel3.length > 0) {
      info.district = component.adminLevel3;
    } else if (component.locality !== undefined) {
      info.district = component.locality;
    }

    if (component.adminLevel4 !== undefined && component.adminLevel4.length > 0) {
      info.town = component.adminLevel4;
    } else if (component.subLocality1 !== undefined) {
      info.town = component.subLocality1;
    }
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
      ` desc=${result.addressDescription}` +
      ` admin=${MapKitPlaceResolver.dumpAdmin(result.addressComponent)}`;
  }

  /**
   * 打印行政区划原始字段。
   *
   * 真机上看这一行就能确认 adminLevel1~4 与省 / 市 / 区 / 镇的对应关系，
   * 对不上时直接调 pickAdmin() 的兜底顺序。
   */
  private static dumpAdmin(component: site.AddressComponent): string {
    return `L1=${component.adminLevel1 ?? ''}|L2=${component.adminLevel2 ?? ''}` +
      `|L3=${component.adminLevel3 ?? ''}|L4=${component.adminLevel4 ?? ''}` +
      `|L5=${component.adminLevel5 ?? ''}|city=${component.city?.cityName ?? ''}` +
      `|locality=${component.locality ?? ''}|sub1=${component.subLocality1 ?? ''}` +
      `|sub2=${component.subLocality2 ?? ''}`;
  }
}
