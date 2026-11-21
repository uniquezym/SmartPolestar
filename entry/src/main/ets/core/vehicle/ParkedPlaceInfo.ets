/**
 * 停车地点的反查结果。
 *
 * 解析层保留全部信息（AOI / POI / 道路 / 地址），供后续功能取用；
 * 展示层目前只取 AOI —— 它描述的是「车停在哪片区域里」
 * （小区、园区、写字楼），最贴合「最后停车位置」这句话的语义。
 */
export class ParkedPlaceInfo {
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
