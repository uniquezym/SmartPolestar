import { AppIcon, AppIconName } from './Icons';

/**
 * 充电状态卡。
 *
 * 按 Nordic Instrument 设计规范：仅在**已连接充电线**时出现。
 * 未插枪时整块隐藏，不占任何空间 —— 充电不是常驻信息。
 */
@Component
export struct ChargingCard {
  /** 充电状态文案（充电中 / 已完成 / 智能充电暂停 …）。 */
  @Prop statusText: string = '—';
  /** 是否正在充电（决定卡片是否用强调色底）。 */
  @Prop live: boolean = false;
  /** 充电功率，瓦。 */
  @Prop powerWatts: number = 0;
  /** 充电枪类型（交流 / 直流 / 无线）。 */
  @Prop chargerType: string = '';
  /** 充电电流，安。 */
  @Prop currentAmps: number = 0;
  /** 充满剩余时长，分钟。 */
  @Prop remainingMinutes: number = 0;

  /**
   * 功率文案：满 1000W 按 kW 显示，与原版 m325d0 一致。
   */
  private powerText(): string {
    if (this.powerWatts <= 0) {
      return '—';
    }
    if (this.powerWatts >= 1000) {
      return `${(this.powerWatts / 1000).toFixed(1)} kW`;
    }
    return `${this.powerWatts} W`;
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text('充电状态')
          .fontSize(9.5)
          .fontColor($r('app.color.app_tertiary_text'))
        Blank()
        Text(this.statusText)
          .fontSize(9.5)
          .fontColor(this.live ? $r('app.color.app_accent_text') : $r('app.color.app_secondary_text'))
          .padding({ left: 7, right: 7, top: 3, bottom: 3 })
          .backgroundColor(this.live
            ? $r('app.color.app_accent_soft')
            : $r('app.color.app_surface_muted'))
          .borderRadius(2)
      }
      .width('100%')

      // 功率大数字
      Row({ space: 5 }) {
        Text(this.powerText().split(' ')[0])
          .fontSize(34)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.app_primary_text'))
        Text(this.powerText().split(' ')[1] ?? '')
          .fontSize(13)
          .fontColor($r('app.color.app_secondary_text'))
      }
      .alignItems(VerticalAlign.Bottom)

      // 明细行
      Row({ space: 14 }) {
        if (this.chargerType.length > 0) {
          Row({ space: 5 }) {
            Text('枪型').fontSize(10).fontColor($r('app.color.app_tertiary_text'))
            Text(this.chargerType).fontSize(10).fontColor($r('app.color.app_secondary_text'))
          }
        }
        if (this.currentAmps > 0) {
          Row({ space: 5 }) {
            Text('电流').fontSize(10).fontColor($r('app.color.app_tertiary_text'))
            Text(`${Math.round(this.currentAmps)} A`).fontSize(10)
              .fontColor($r('app.color.app_secondary_text'))
          }
        }
        if (this.remainingMinutes > 0) {
          Row({ space: 5 }) {
            Text('充满').fontSize(10).fontColor($r('app.color.app_tertiary_text'))
            Text(`约 ${this.remainingMinutes} 分钟`).fontSize(10)
              .fontColor($r('app.color.app_secondary_text'))
          }
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 14 })
    .backgroundColor(this.live ? $r('app.color.app_accent_soft') : $r('app.color.app_surface'))
    .border({ width: 1, color: this.live ? $r('app.color.app_accent') : $r('app.color.app_card_border') })
    .borderRadius(8)
  }
}
