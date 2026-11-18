/**
 * 温度档位快捷按钮。
 *
 * 露营模式卡片里的一行：三个等宽档位按钮平铺。
 *
 * 为什么是三个固定档位而不是滑块：
 * 车端只认整度，露营场景下用户要的是「冷一点 / 标准 / 暖一点」，
 * 三个离散档位比连续滑块更好按，也避免调出 21.5 这种车端会四舍五入的值。
 *
 * **不用 Button 控件**：Button 自带左右内边距，档位文字放不下时
 * 会被截成「…」—— 三个「20°」这样的短文本反而最容易被挤掉。
 * 这里用 Row + Text 自绘按钮，尺寸与文字排版完全可控。
 *
 * 选中态用品牌蓝实心 + 白字，与卡片里的开关本体（蓝底白图标）
 * 是同一套视觉语言。
 */
@Component
export struct TemperaturePicker {
  /** 当前目标温度（摄氏度）。 */
  @Prop celsius: number = 22;
  /** 是否禁用（露营模式运行中不可调）。 */
  @Prop disabled: boolean = false;
  /** 温度变化回调。 */
  onChange?: (celsius: number) => void;

  /**
   * 档位列表。
   */
  private levels(): number[] {
    return [20, 22, 24];
  }

  /**
   * 点击档位按钮。
   */
  private select(celsius: number): void {
    if (this.disabled || celsius === this.celsius) {
      return;
    }
    if (this.onChange !== undefined) {
      this.onChange(celsius);
    }
  }

  build() {
    Row({ space: 10 }) {
      ForEach(this.levels(), (level: number) => {
        Row() {
          Text(`${level}°`)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(level === this.celsius
              ? $r('app.color.app_on_accent')
              : $r('app.color.app_primary_text'))
        }
        .layoutWeight(1)
        .height(42)
        .justifyContent(FlexAlign.Center)
        .borderRadius(8)
        .backgroundColor(level === this.celsius
          ? $r('app.color.app_accent')
          : $r('app.color.app_surface_sunken'))
        .border({ width: 1, color: level === this.celsius
          ? $r('app.color.app_accent')
          : $r('app.color.app_card_border') })
        .onClick(() => {
          this.select(level);
        })
      }, (level: number) => level.toString())
    }
    .width('100%')
    .padding({ top: 11, bottom: 11 })
    .border({ width: { top: 1 }, color: $r('app.color.app_rule') })
    .opacity(this.disabled ? 0.4 : 1)
  }
}
