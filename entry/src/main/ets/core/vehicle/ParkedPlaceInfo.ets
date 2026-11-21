/**
 * 停车地点的反查结果。
 *
 * 解析层保留全部信息（AOI / POI / 道路 / 地址），供后续功能取用；
 * 展示层目前只取 AOI —— 它描述的是「车停在哪片区域里」
 * （小区、园区、写字楼），最贴合「最后停车位置」这句话的语义。
 */
export class ParkedPlaceInfo {
  /**
   * 判定挪位的距离容差（米）。
   *
   * GPS 抖动在露天停车场能到十几米，地下车库更差。
   * 30 米足够区分「换了个车位」与「同一车位的坐标漂移」。
   */
  static readonly MOVE_THRESHOLD_METERS: number = 30;

  /** AOI 名，例如「XX 小区」「XX 科技园」。 */
  aoiName: string = '';
  /** AOI 分类，例如「住宅区」「工业园区」。 */
  aoiType: string = '';
  /** POI 名，例如「XX 地下停车场」。 */
  poiName: string = '';
  /** POI 分类，例如「停车场」「商场」。 */
  poiType: string = '';
  /** 详细地址。 */
  address: string = '';
  /** 道路名。 */
  roadName: string = '';
  /** 距停车点的距离（米），-1 表示未知。 */
  distance: number = -1;

  /**
   * 是否拿到了任何可用信息。
   */
  isEmpty(): boolean {
    return this.aoiName.length === 0 && this.poiName.length === 0 &&
      this.address.length === 0 && this.roadName.length === 0;
  }

  /**
   * 展示名 —— 只取 AOI 名。
   *
   * 展示层不显示 POI：POI 是「哪一个点」，AOI 才是「哪一片区域」，
   * 后者更贴合「最后停车位置」的语义。
   *
   * AOI 缺失时退到地址 / 道路名 —— 系统逆地理编码那条兜底路径拿不到 AOI，
   * 只能落到后面几项。
   */
  displayName(): string {
    if (this.aoiName.length > 0) {
      return this.aoiName;
    }
    if (this.address.length > 0) {
      return this.address;
    }
    return this.roadName;
  }

  /**
   * 序列化成纯对象，供持久化。
   */
  toPlain(): ParkedPlacePlain {
    return {
      aoiName: this.aoiName,
      aoiType: this.aoiType,
      poiName: this.poiName,
      poiType: this.poiType,
      address: this.address,
      roadName: this.roadName,
      distance: this.distance
    };
  }

  /**
   * 从纯对象还原。
   */
  static fromPlain(plain: ParkedPlacePlain): ParkedPlaceInfo {
    const info = new ParkedPlaceInfo();
    info.aoiName = plain.aoiName;
    info.aoiType = plain.aoiType;
    info.poiName = plain.poiName;
    info.poiType = plain.poiType;
    info.address = plain.address;
    info.roadName = plain.roadName;
    info.distance = plain.distance;
    return info;
  }

  /**
   * 判定停车位置是否真的挪动了。
   *
   * 车辆上报的坐标带 GPS 抖动 —— 同一个车位每次上报都可能有零点几米的差异。
   * 用「上次收到的坐标」当基准，一有抖动就会被判成挪位，白白重新反查一遍。
   * 所以基准取「上次逆编码时用的坐标」，并留出距离容差。
   *
   * @param lat1 上次逆编码用的纬度
   * @param lon1 上次逆编码用的经度
   * @param lat2 当前纬度
   * @param lon2 当前经度
   * @returns 是否挪动了
   */
  static moved(lat1: number, lon1: number, lat2: number, lon2: number): boolean {
    // 基准无效（还没反查过）→ 视为挪动，需要查一次。
    if (lat1 < 0 || lon1 < 0) {
      return true;
    }
    return ParkedPlaceInfo.distanceMeters(lat1, lon1, lat2, lon2) >
      ParkedPlaceInfo.MOVE_THRESHOLD_METERS;
  }

  /**
   * 两点间的大圆距离（米）。
   */
  static distanceMeters(lat1: number, lon1: number, lat2: number, lon2: number): number {
    const radius = 6371000;
    const rad = Math.PI / 180;
    const dLat = (lat2 - lat1) * rad;
    const dLon = (lon2 - lon1) * rad;
    const a = Math.pow(Math.sin(dLat / 2), 2) +
      Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.pow(Math.sin(dLon / 2), 2);
    return 2 * radius * Math.asin(Math.min(1, Math.sqrt(a)));
  }
}

/**
 * 停车地点的持久化形态。
 */
export interface ParkedPlacePlain {
  aoiName: string;
  aoiType: string;
  poiName: string;
  poiType: string;
  address: string;
  roadName: string;
  distance: number;
}
