import { AppIcon, AppIconName } from './Icons';

/**
 * 运行时长滑块。
 *
 * 对应设计稿 `design/polestar-volvo-ux/index.html` 的 `.durrow` + `.durslider`：
 *   一行「时钟图标 + 运行时长 + 数值」
 *   下方是滑杆与四个刻度标签
 *
 * 档位共 16 档（30 分钟 ~ 8 小时，步进 30 分钟）：
 *   索引 0 → 30 分，索引 1 → 1 小时（默认），索引 15 → 8 小时。
 *
 * 刻度标签按档位百分比绝对定位（0% / 20% / 46.67% / 100%），
 * 不能用等分 —— 16 档并非线性均分到 4 个标签上。
 */
@Component
export struct DurationSlider {
  /** 当前时长（分钟）。 */
  @Prop @Watch('onMinutesChanged') minutes: number = 60;
  /** 是否禁用（露营模式运行中不可调）。 */
  @Prop disabled: boolean = false;
  /** 时长变化回调。 */
  onChange?: (minutes: number) => void;

  /** 滑杆索引（0 ~ 15）。 */
  @State private index: number = 1;
  /** 刻度容器宽度，用于按百分比定位标签。 */
  @State private trackWidth: number = 0;

  aboutToAppear(): void {
    this.index = DurationSlider.minutesToIndex(this.minutes);
  }

  /**
   * 外部时长变化时同步滑杆位置。
   */
  private onMinutesChanged(): void {
    const next = DurationSlider.minutesToIndex(this.minutes);
    if (next !== this.index) {
      this.index = next;
    }
  }

  /**
   * 分钟数 → 档位索引。
   */
  static minutesToIndex(minutes: number): number {
    const index = Math.round(minutes / 30) - 1;
    if (index < 0) {
      return 0;
    }
    if (index > 15) {
      return 15;
    }
    return index;
  }

  /**
   * 档位索引 → 分钟数。
   */
  static indexToMinutes(index: number): number {
    return (index + 1) * 30;
  }

  /**
   * 时长文案：不足一小时写「N 分钟」，整小时只写「N 小时」，否则「N 小时 M 分」。
   *
   * 与设计稿 `fmtDur` 一致。
   */
  static format(minutes: number): string {
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    if (h <= 0) {
      return `${m}分钟`;
    }
    return m === 0 ? `${h}小时` : `${h}小时${m}分`;
  }

  /**
   * 刻度标签：文案 + 档位百分比。
   */
  private tick(index: number): string {
    if (index === 0) {
      return '30分';
    }
    if (index === 3) {
      return '2小时';
    }
    if (index === 7) {
      return '4小时';
    }
    return '8小时';
  }

  /**
   * 刻度标签的水平偏移（vp），相对刻度容器左边缘。
   *
   * 滑块直径 18px，轨道实际行程 = 宽度 - 18px，左右各留半个滑块（9px），
   * 刻度才能与滑块真实位置对齐。标签宽 40 且居中，再减去半个标签宽。
   */
  private tickOffset(index: number): number {
    const ratio = index / 15;
    return 9 + (this.trackWidth - 18) * ratio - 20;
  }

  build() {
    Column() {
      // 数值行
      Row() {
        Row({ space: 9 }) {
          AppIcon({ name: AppIconName.CLOCK, iconSize: 19, color: $r('app.color.app_secondary_text') })
            .width(19)
            .height(19)

          Text('运行时长')
            .fontSize(13.5)
            .fontColor($r('app.color.app_primary_text'))
        }
        .alignItems(VerticalAlign.Center)

        Blank()

        Text(DurationSlider.format(this.minutes))
          .fontSize(13)
          .fontColor($r('app.color.app_primary_text'))
      }
      .width('100%')
      .padding({ top: 11, bottom: 4 })
      .border({ width: { top: 1 }, color: $r('app.color.app_rule') })

      // 滑杆
      // $$ 双向绑定：外部改 index（恢复持久化的时长）时滑块跟着走，
      // 用户拖动时 index 也会同步回外部，省掉手写回写逻辑。
      Slider({
        value: $$this.index,
        min: 0,
        max: 15,
        step: 1
      })
        .width('100%')
        .height(22)
        .selectedColor($r('app.color.app_surface_sunken'))
        .trackColor($r('app.color.app_surface_sunken'))
        .blockColor($r('app.color.app_accent'))
        .blockSize({ width: 18, height: 18 })
        .enabled(!this.disabled)
        .onChange((value: number) => {
          const minutes = DurationSlider.indexToMinutes(value);
          if (this.onChange !== undefined) {
            this.onChange(minutes);
          }
        })

      // 刻度标签：按档位百分比定位
      Stack({ alignContent: Alignment.TopStart }) {
        ForEach([0, 3, 7, 15], (index: number) => {
          Text(this.tick(index))
            .width(40)
            .textAlign(TextAlign.Center)
            .fontSize(9)
            .fontColor($r('app.color.app_tertiary_text'))
            .offset({ x: this.tickOffset(index) })
        }, (index: number) => index.toString())
      }
      .width('100%')
      .height(12)
      .margin({ top: 2 })
      .onAreaChange((oldArea: Area, newArea: Area) => {
        this.trackWidth = Number(newArea.width);
      })
    }
    .width('100%')
    .opacity(this.disabled ? 0.4 : 1)
  }
}
