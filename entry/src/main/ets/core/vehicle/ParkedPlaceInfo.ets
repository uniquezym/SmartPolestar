/**
 * 停车地点的结构化反查结果。
 *
 * 地图服务能同时给出 AOI（住宅小区、园区、写字楼这类「地块」）、
 * POI（停车场、商场、便利店这类「兴趣点」）与道路名，
 * 三者层级不同，展示时需要按优先级挑一个。
 */
export class ParkedPlaceInfo {
  /** AOI 名 —— 优先级最高，通常是小区 / 园区 / 写字楼名称。 */
  aoiName: string = '';
  /** POI 名 —— 例如「XX 地下停车场」。 */
  poiName: string = '';
  /** POI 分类，例如「停车场」「商场」。 */
  poiType: string = '';
  /** POI 详细地址。 */
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
   * 最终展示名。
   *
   * 优先级：AOI → POI → 道路名 → 详细地址。
   * AOI 描述的是「车停在哪片区域里」，POI 描述的是「车停在哪个点」，
   * 前者更符合「最后停车位置」这句话的语义，所以放前面。
   */
  displayName(): string {
    if (this.aoiName.length > 0) {
      return this.aoiName;
    }
    if (this.poiName.length > 0) {
      return this.poiName;
    }
    if (this.roadName.length > 0) {
      return this.roadName;
    }
    return this.address;
  }

  /**
   * 副信息 —— 展示名之外还想补充的一项。
   *
   * AOI 与 POI 同时存在时，把 POI 名并上来（两者通常是「小区」+「地下停车场」的关系）；
   * 否则用 POI 分类或距离补位。空串表示没有可补充的内容。
   */
  secondaryName(): string {
    if (this.aoiName.length > 0 && this.poiName.length > 0 &&
      this.poiName !== this.aoiName) {
      return this.poiName;
    }
    return '';
  }

  /**
   * 右侧标签 —— POI 分类 + 距离。
   */
  tagText(): string {
    const parts: string[] = [];
    if (this.poiType.length > 0) {
      parts.push(this.poiType);
    }
    if (this.distance >= 0 && this.distance < 1000) {
      parts.push(`${Math.round(this.distance)}m`);
    }
    return parts.join(' · ');
  }
}
