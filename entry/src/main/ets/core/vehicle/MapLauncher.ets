import { common, Want } from '@kit.AbilityKit';
import { BusinessError, Log } from '../../common/Log';

/**
 * 打开系统地图，定位到停车坐标。
 *
 * 对应 Android 端 RunnableC0497n9 的 case 5：
 *   优先用高德 URI（androidamap://viewMap?lat=..&lon=..），
 *   失败则退到系统通用 geo: scheme。
 *
 * HarmonyOS NEXT 上没有高德，改为 geo: scheme + 系统地图应用；
 * 若系统没有能响应 geo: 的应用，调用方应退到内置 Web 地图页。
 */
export class MapLauncher {
  /** 查看数据的 action。 */
  private static readonly ACTION_VIEW: string = 'ohos.want.action.viewData';
  /** 可被浏览器/地图应用处理的实体。 */
  private static readonly ENTITY_BROWSABLE: string = 'entity.system.browsable';

  /**
   * 启动系统地图并标记停车点。
   *
   * @param context   上下文
   * @param latitude  纬度
   * @param longitude 经度
   * @param name      地点名（可为空）
   * @returns 是否成功拉起地图应用
   */
  static async open(context: common.UIAbilityContext, latitude: number,
    longitude: number, name: string): Promise<boolean> {
    const lat = MapLauncher.format(latitude);
    const lon = MapLauncher.format(longitude);
    const label = encodeURIComponent(name.length > 0 ? name : '车辆停放位置');
    const uri = `geo:${lat},${lon}?q=${lat},${lon}(${label})`;

    const want: Want = {
      action: MapLauncher.ACTION_VIEW,
      entities: [MapLauncher.ENTITY_BROWSABLE],
      uri: uri
    };

    try {
      await context.startAbility(want);
      Log.info(`已拉起系统地图: ${uri}`);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`拉起系统地图失败: code=${e.code} ${e.message}`);
      return false;
    }
  }

  /**
   * 坐标格式化 —— 对齐 Android 端 `String.format("%.6f", ...)`。
   */
  private static format(value: number): string {
    return value.toFixed(6);
  }
}
