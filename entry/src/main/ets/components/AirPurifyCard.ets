import { AirQualityRing } from './AirQualityRing';
import { AppIconName } from './Icons';
import { SwitchRow } from './SwitchRow';
import { TogglePhase } from './StateToggle';

/**
 * 空气净化卡片。
 *
 * 对应设计稿 `design/polestar-volvo-ux/index.html` 的第二张 `.ctrl`：
 *   卡片头（空气净化 / 到时自动关闭）
 *   → 空气净化开关行（净化关 / 净化开）
 *   → 空气质量环（AQI 读数 + 等级 + PM2.5）
 *
 * 与露营模式卡片一样是独立组件 —— 父组件的状态经 @Prop 下传，
 * 不用 @Builder 插槽（Builder 按值传递，状态不会刷新）。
 */
@Component
export struct AirPurifyCard {
  /** 空气净化阶段。 */
  @Prop phase: TogglePhase = TogglePhase.OFF;
  /** AQI 指数，-1 表示未知。 */
  @Prop aqi: number = -1;
  /** PM2.5 浓度（μg/m³），-1 表示未知。 */
  @Prop pm25: number = -1;
  /** 是否禁用（驻车空调在跑时置灰 —— 空调与净化互斥）。 */
  @Prop disabled: boolean = false;

  /** 点击开关。 */
  onToggle?: () => void;

  build() {
    Column() {
      // ---------- 卡片头 ----------
      Row() {
        Text('空气净化')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_primary_text'))

        Blank()

        Text('到时自动关闭')
          .fontSize(10)
          .fontColor($r('app.color.app_tertiary_text'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 13 })

      // ---------- 开关行 ----------
      // 保留底边：下方是带边框的空气质量环，两者之间靠这条线分隔。
      SwitchRow({
        icon: AppIconName.AIR_CYCLE,
        label: '空气净化',
        phase: this.phase,
        offText: '净化关',
        onText: '净化开',
        disabled: this.disabled,
        onTap: () => {
          if (this.onToggle !== undefined) {
            this.onToggle();
          }
        }
      })

      // ---------- 空气质量环 ----------
      AirQualityRing({ aqi: this.aqi, pm25: this.pm25 })
        .margin({ top: 11 })
    }
    .width('100%')
    .padding({ top: 15, left: 16, right: 16, bottom: 16 })
    .border({ width: 1, color: $r('app.color.app_rule') })
    .borderRadius(8)
  }
}
