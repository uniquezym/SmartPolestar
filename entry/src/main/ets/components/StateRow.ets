import { AppIcon, AppIconName } from './Icons';

/**
 * 状态语义色。
 */
export enum StateTone {
  /** 中性。 */
  NEUTRAL = 0,
  /** 正常 / 良好。 */
  OK = 1,
  /** 需要关注。 */
  WARN = 2,
  /** 异常。 */
  ERROR = 3
}

/**
 * 车辆状态清单中的一行。
 *
 * Nordic Instrument 的列表样式：细发丝线分隔，无卡片阴影；
 * 标题用次级色，数值用主色，右侧状态标签用小号等宽字。
 */
@Component
export struct StateRow {
  /** 左侧图标。 */
  @Prop icon: AppIconName = AppIconName.HEALTH;
  /** 标题。 */
  @Prop label: string = '';
  /** 主数值。 */
  @Prop value: string = '';
  /** 数值后的补充说明。 */
  @Prop detail: string = '';
  /** 右侧标签文案，空字符串则不显示。 */
  @Prop tag: string = '';
  /** 右侧标签语义色。 */
  @Prop tone: StateTone = StateTone.NEUTRAL;
  /** 是否可点击下钻。 */
  @Prop showChevron: boolean = false;
  /** 点击回调。为空则整行不可点。 */
  onTap?: () => void;

  /**
   * 标签底色。
   */
  private tagBg(): ResourceColor {
    switch (this.tone) {
      case StateTone.OK:
        return $r('app.color.app_ok_soft');
      case StateTone.WARN:
        return $r('app.color.app_warn_soft');
      case StateTone.ERROR:
        return $r('app.color.app_error_soft');
      default:
        return $r('app.color.app_surface_muted');
    }
  }

  /**
   * 标签文字色。
   */
  private tagFg(): ResourceColor {
    switch (this.tone) {
      case StateTone.OK:
        return $r('app.color.app_ok');
      case StateTone.WARN:
        return $r('app.color.app_warn');
      case StateTone.ERROR:
        return $r('app.color.app_error');
      default:
        return $r('app.color.app_secondary_text');
    }
  }

  build() {
    Row({ space: 12 }) {
      AppIcon({ name: this.icon, iconSize: 22, color: $r('app.color.app_secondary_text') })
        .width(22)
        .height(22)

      Column({ space: 1 }) {
        Text(this.label)
          .fontSize(12.5)
          .fontColor($r('app.color.app_secondary_text'))
        Row({ space: 7 }) {
          Text(this.value)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_primary_text'))
          if (this.detail.length > 0) {
            Text(this.detail)
              .fontSize(12)
              .fontColor($r('app.color.app_tertiary_text'))
              // 长地址（如详细门牌）允许折行，最多两行，超出省略，
              // 避免溢出压到右侧 chevron 上
              .layoutWeight(1)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(VerticalAlign.Bottom)
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.tag.length > 0) {
        Text(this.tag)
          .fontSize(9.5)
          .fontColor(this.tagFg())
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .backgroundColor(this.tagBg())
          .borderRadius(2)
      }

      if (this.showChevron) {
        AppIcon({ name: AppIconName.CHEVRON_DOWN, iconSize: 14, color: $r('app.color.app_tertiary_text') })
          .width(14)
          .height(14)
          .rotate({ angle: -90 })
      }
    }
    .width('100%')
    .padding({ top: 13, bottom: 13 })
    .border({ width: { bottom: 1 }, color: $r('app.color.app_rule') })
    .onClick(() => {
      if (this.onTap !== undefined) {
        this.onTap();
      }
    })
  }
}
