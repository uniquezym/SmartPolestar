/**
 * 空气质量环。
 *
 * 对应设计稿 `design/polestar-volvo-ux/index.html` 的 `.ring`：
 *   76×76 圆环（6px 描边，蓝色 = 当前 AQI 占比，灰色 = 轨道）
 *   → 环心读数（AQI 数值 + 单位）
 *   → 右侧「空气质量 X」与「PM2.5 x μg/m³」
 *
 * 环的比例按 AQI 0~100 线性映射到 0~100%，超出后满格。
 */
@Component
export struct AirQualityRing {
  /** AQI 指数，-1 表示未知。 */
  @Prop aqi: number = -1;
  /** PM2.5 浓度（μg/m³），-1 表示未知。 */
  @Prop pm25: number = -1;

  /**
   * 环上的填充比例。
   */
  private ratio(): number {
    if (this.aqi < 0) {
      return 0;
    }
    return Math.min(this.aqi / 100, 1);
  }

  /**
   * AQI 等级文案。分级按国标：0~50 优、51~100 良、101~150 轻度污染、
   * 151~200 中度污染、201~300 重度污染、300 以上严重污染。
   */
  private qualityText(): string {
    if (this.aqi < 0) {
      return '—';
    }
    if (this.aqi <= 50) {
      return '优';
    }
    if (this.aqi <= 100) {
      return '良';
    }
    if (this.aqi <= 150) {
      return '轻度污染';
    }
    if (this.aqi <= 200) {
      return '中度污染';
    }
    if (this.aqi <= 300) {
      return '重度污染';
    }
    return '严重污染';
  }

  /**
   * PM2.5 文案。
   */
  private pm25Text(): string {
    if (this.pm25 < 0) {
      return 'PM2.5 — μg/m³';
    }
    return `PM2.5 ${this.pm25.toFixed(1)} μg/m³`;
  }

  build() {
    Row({ space: 16 }) {
      // ---------- 圆环 ----------
      // 外框 76×76（与设计稿一致），环本身 70×70：
      // 描边 6px 居中于半径 32 处，正好落在设计稿 r=32 的位置。
      Stack({ alignContent: Alignment.Center }) {
        Progress({ value: Math.round(this.ratio() * 100), total: 100, type: ProgressType.Ring })
          .width(70)
          .height(70)
          .style({ strokeWidth: 6 })
          .color($r('app.color.app_accent'))
          .backgroundColor($r('app.color.app_surface_sunken'))

        Column({ space: 2 }) {
          Text(this.aqi < 0 ? '—' : `${this.aqi}`)
            .fontSize(20)
            .fontFamily('HarmonyOS Sans Mono')
            .fontColor($r('app.color.app_primary_text'))

          Text('AQI')
            .fontSize(8)
            .fontFamily('HarmonyOS Sans Mono')
            .fontColor($r('app.color.app_tertiary_text'))
        }
        .alignItems(HorizontalAlign.Center)
      }
      .width(76)
      .height(76)

      // ---------- 右侧说明 ----------
      Column() {
        Text(`空气质量 ${this.qualityText()}`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_primary_text'))

        Text(this.pm25Text())
          .fontSize(10)
          .fontFamily('HarmonyOS Sans Mono')
          .fontColor($r('app.color.app_tertiary_text'))
          .margin({ top: 4 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 14, bottom: 14, left: 16, right: 16 })
    .border({ width: 1, color: $r('app.color.app_rule') })
    .borderRadius(8)
  }
}
