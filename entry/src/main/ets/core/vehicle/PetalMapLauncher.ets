import { common } from '@kit.AbilityKit';
import { mapCommon, petalMaps } from '@kit.MapKit';
import { BusinessError, Log } from '../../common/Log';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'PetalMapLauncher';

/**
 * 花瓣地图（华为地图）跳转。
 *
 * 「找车」的本质是：从当前位置走到车停的地方。
 * 花瓣地图的路线规划页正好干这件事 —— 起点当前位置，终点停车位，
 * 步行模式。
 *
 * 坐标系：Map Kit 大陆区底图是 GCJ02，车辆坐标直接可用；
 * 系统定位是 WGS84，调用前先转成 GCJ02。
 */
export class PetalMapLauncher {
  /**
   * 打开花瓣地图的路线规划页。
   *
   * @param context   上下文
   * @param latitude  停车位纬度（GCJ02）
   * @param longitude 停车位经度（GCJ02）
   * @param name      地点名，显示在终点
   * @returns 是否成功拉起
   */
  static async openRoutePlan(context: common.Context, latitude: number, longitude: number,
    name: string): Promise<boolean> {
    try {
      const params: petalMaps.RoutePlanParams = {
        destinationPosition: { latitude: latitude, longitude: longitude },
        destinationName: name.length > 0 ? name : '车辆停放位置',
        // 找车是走过去，步行。
        vehicleType: petalMaps.VehicleType.WALKING,
        // 车辆坐标是 GCJ02，明说坐标类型，避免地图按 WGS84 解释。
        coordinateType: mapCommon.CoordinateType.GCJ02
      };
      await petalMaps.openMapRoutePlan(context, params);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      // 1002600014 —— 设备没装花瓣地图；801 —— 设备能力不支持。
      Log.warn(TAG, `打开花瓣地图失败: code=${e.code} ${e.message}`);
      return false;
    }
  }

  /**
   * 打开花瓣地图的地点详情页。
   *
   * 找车路线规划之外的兜底 —— 比如只想定个位、不想走路线。
   */
  static async openPoiDetail(context: common.Context, latitude: number, longitude: number,
    name: string): Promise<boolean> {
    try {
      const params: petalMaps.PoiDetailParams = {
        destinationPosition: { latitude: latitude, longitude: longitude },
        destinationName: name.length > 0 ? name : '车辆停放位置',
        coordinateType: mapCommon.CoordinateType.GCJ02
      };
      await petalMaps.openMapPoiDetail(context, params);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(TAG, `打开花瓣地图地点详情失败: code=${e.code} ${e.message}`);
      return false;
    }
  }
}
