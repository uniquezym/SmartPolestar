/**
 * 温度档位快捷按钮。
 *
 * 露营模式卡片里的一行：图标 + 「目标温度」+ 三个档位按钮。
 *
 * 为什么是三个固定档位而不是滑块：
 * 车端只认整度，露营场景下用户要的是「冷一点 / 标准 / 暖一点」，
 * 三个离散档位比连续滑块更好按，也避免调出 21.5 这种车端会四舍五入的值。
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
    Row() {
      Text('目标温度')
        .fontSize(13.5)
        .fontColor($r('app.color.app_primary_text'))

      Blank()

      Row({ space: 8 }) {
        ForEach(this.levels(), (level: number) => {
          Button(`${level}°`, { type: ButtonType.Normal })
            .width(48)
            .height(28)
            .fontSize(12.5)
            .fontColor(level === this.celsius
              ? $r('app.color.app_on_accent')
              : $r('app.color.app_secondary_text'))
            .backgroundColor(level === this.celsius
              ? $r('app.color.app_accent')
              : $r('app.color.app_surface_sunken'))
            .border({ width: 1, color: level === this.celsius
              ? $r('app.color.app_accent')
              : $r('app.color.app_card_border') })
            .borderRadius(6)
            .enabled(!this.disabled)
            .onClick(() => {
              this.select(level);
            })
        }, (level: number) => level.toString())
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 11, bottom: 11 })
    .border({ width: { top: 1 }, color: $r('app.color.app_rule') })
    .opacity(this.disabled ? 0.4 : 1)
  }
}
