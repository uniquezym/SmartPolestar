import { AppIconName } from './Icons';
import { DurationSlider } from './DurationSlider';
import { SwitchRow } from './SwitchRow';
import { TogglePhase } from './StateToggle';

/**
 * 露营模式卡片。
 *
 * 对应设计稿 `design/polestar-volvo-ux/index.html` 的第一张 `.ctrl`：
 *   卡片头（露营模式 / 驻车空调定时守护）
 *   → 露营模式开关行（未开启 / 已开启）
 *   → 运行时长滑块（30 分钟 ~ 8 小时，16 档）
 *   → 剩余时间（倒计时 + 4px 进度条）
 *
 * 卡片自身是一个组件而不是父组件里的 @Builder 插槽：
 * ArkUI 的 @Builder 默认按值传递，父组件状态变化不会刷新插槽内的 UI，
 * 开关状态与倒计时会停在旧值上。做成独立组件后，
 * 状态以 @Prop 逐级下传，刷新链路才是通的。
 */
@Component
export struct CampModeCard {
  /** 露营模式阶段。 */
  @Prop phase: TogglePhase = TogglePhase.OFF;
  /** 运行时长（分钟）。 */
  @Prop durationMinutes: number = 60;
  /** 剩余时间（分钟），0 表示未开启。 */
  @Prop remainingMinutes: number = 0;
  /** 剩余时间占全程的比例（0 ~ 1），用于进度条。 */
  @Prop remainingRatio: number = 0;

  /** 点击开关。 */
  onToggle?: () => void;
  /** 调节运行时长。 */
  onDurationChange?: (minutes: number) => void;

  /**
   * 露营模式是否处于占用态（开启中或执行中）。
   *
   * 占用期间滑块置灰 —— 运行中改时长会让已排定的到期时刻失去意义。
   */
  private running(): boolean {
    return this.phase === TogglePhase.ON || this.phase === TogglePhase.PENDING;
  }

  /**
   * 剩余时间文案。未开启时显示「—」。
   */
  private remainingText(): string {
    if (this.remainingMinutes <= 0) {
      return '—';
    }
    const h = Math.floor(this.remainingMinutes / 60);
    const m = this.remainingMinutes % 60;
    if (h === 0) {
      return `${m}分`;
    }
    return m === 0 ? `${h}小时` : `${h}小时${m}分`;
  }

  build() {
    Column() {
      // ---------- 卡片头 ----------
      Row() {
        Text('露营模式')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_primary_text'))

        Blank()

        Text('驻车空调定时守护')
          .fontSize(10)
          .fontColor($r('app.color.app_tertiary_text'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 13 })

      // ---------- 开关行 ----------
      // 不画底边：下面「运行时长」行的顶边就是这条分隔线，
      // 两边都画会出现 2px 的双线。
      SwitchRow({
        icon: AppIconName.CLIMATE_COOL,
        label: '露营模式',
        phase: this.phase,
        offText: '未开启',
        onText: '已开启',
        lastRow: true,
        onTap: () => {
          if (this.onToggle !== undefined) {
            this.onToggle();
          }
        }
      })

      // ---------- 运行时长 ----------
      DurationSlider({
        minutes: this.durationMinutes,
        disabled: this.running(),
        onChange: (minutes: number) => {
          if (this.onDurationChange !== undefined) {
            this.onDurationChange(minutes);
          }
        }
      })

      // ---------- 剩余时间 ----------
      Column() {
        Row() {
          Text('剩余时间')
            .fontSize(12.5)
            .fontColor($r('app.color.app_secondary_text'))

          Blank()

          Text(this.remainingText())
            .fontSize(15)
            .fontColor($r('app.color.app_primary_text'))
        }
        .width('100%')
        .margin({ bottom: 8 })

        // 4px 进度条，蓝色填充表示剩余占比
        // 用 TopStart 而不是 Start：ArkUI 的 Start 是「横向贴左 + 纵向居中」
        Stack({ alignContent: Alignment.TopStart }) {
          Stack()
            .width('100%')
            .height(4)
            .borderRadius(2)
            .backgroundColor($r('app.color.app_surface_sunken'))

          Stack()
            .width(`${Math.round(this.remainingRatio * 100)}%`)
            .height(4)
            .borderRadius(2)
            .backgroundColor($r('app.color.app_accent'))
        }
        .width('100%')
        .height(4)
        .borderRadius(2)
        .backgroundColor($r('app.color.app_surface_sunken'))
      }
      .width('100%')
      .padding({ top: 11, bottom: 2 })
      .border({ width: { top: 1 }, color: $r('app.color.app_rule') })
    }
    .width('100%')
    .padding({ top: 15, left: 16, right: 16, bottom: 16 })
    .border({ width: 1, color: $r('app.color.app_rule') })
    .borderRadius(8)
  }
}
