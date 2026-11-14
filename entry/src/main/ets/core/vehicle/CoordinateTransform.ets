/**
 * 坐标系转换（国测局 GCJ02 加密算法）。
 *
 * 背景：车辆接口返回的停车坐标是 GCJ02（国测局加密坐标），
 * 而 HarmonyOS 的 geoLocationManager 逆地理编码只接受 WGS84。
 * 直接把 GCJ02 当 WGS84 用，坐标会偏出去几百米，
 * 逆地理编码就退化成只返回到区级。
 *
 * 精度说明：这是标准近似算法，GCJ02→WGS84 迭代 3 次收敛到亚米级。
 * 若需要严格精确换算，得用 Map Kit 的 map.convertCoordinate（需 Map Kit 服务密钥）。
 */
export class CoordinateTransform {
  /** 克拉索夫斯基椭球长半轴（米）。 */
  private static readonly A: number = 6378245.0;
  /** 椭球偏心率平方。 */
  private static readonly EE: number = 0.00669342162296594323;

  /**
   * GCJ02 → WGS84。
   *
   * @param latitude  GCJ02 纬度
   * @param longitude GCJ02 经度
   * @returns [WGS84 纬度, WGS84 经度]
   */
  static gcj2Wgs(latitude: number, longitude: number): number[] {
    // 正向算出偏移量，再从原坐标减去。迭代 3 次收敛。
    let wgsLat = latitude;
    let wgsLon = longitude;
    for (let i = 0; i < 3; i++) {
      const gcj = CoordinateTransform.wgs2Gcj(wgsLat, wgsLon);
      wgsLat = wgsLat - (gcj[0] - latitude);
      wgsLon = wgsLon - (gcj[1] - longitude);
    }
    return [wgsLat, wgsLon];
  }

  /**
   * WGS84 → GCJ02。
   *
   * @returns [GCJ02 纬度, GCJ02 经度]
   */
  static wgs2Gcj(latitude: number, longitude: number): number[] {
    const x = longitude - 105.0;
    const y = latitude - 35.0;
    const dLat = CoordinateTransform.transformLat(x, y);
    const dLon = CoordinateTransform.transformLon(x, y);
    const radLat = latitude / 180.0 * Math.PI;
    let magic = Math.sin(radLat);
    magic = 1 - CoordinateTransform.EE * magic * magic;
    const sqrtMagic = Math.sqrt(magic);
    const dLatRad = (dLat * 180.0) /
      (((CoordinateTransform.A * (1 - CoordinateTransform.EE)) / (magic * sqrtMagic)) * Math.PI);
    const dLonRad = (dLon * 180.0) /
      ((CoordinateTransform.A / sqrtMagic * Math.cos(radLat)) * Math.PI);
    return [latitude + dLatRad, longitude + dLonRad];
  }

  private static transformLat(x: number, y: number): number {
    let ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * Math.sqrt(Math.abs(x));
    ret += (20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0 / 3.0;
    ret += (20.0 * Math.sin(y * Math.PI) + 40.0 * Math.sin(y / 3.0 * Math.PI)) * 2.0 / 3.0;
    ret += (160.0 * Math.sin(y / 12.0 * Math.PI) + 320 * Math.sin(y * Math.PI / 30.0)) * 2.0 / 3.0;
    return ret;
  }

  private static transformLon(x: number, y: number): number {
    let ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(Math.abs(x));
    ret += (20.0 * Math.sin(6.0 * x * Math.PI) + 20.0 * Math.sin(2.0 * x * Math.PI)) * 2.0 / 3.0;
    ret += (20.0 * Math.sin(x * Math.PI) + 40.0 * Math.sin(x / 3.0 * Math.PI)) * 2.0 / 3.0;
    ret += (150.0 * Math.sin(x / 12.0 * Math.PI) + 300.0 * Math.sin(x / 30.0 * Math.PI)) * 2.0 / 3.0;
    return ret;
  }
}
