import { ChargeConfig } from '../core/net/ChargeConfig';

/**
 * 充电配置卡片。
 *
 * 承载四项能力：
 *   电量进度条（带充电上限刻度线）+ 电量数值
 *   充电上限设置
 *   电流上限设置
 *   预约充电开关 + 时段设置
 *
 * **交互选型**：两个上限用**滚轮选择器**（TextPicker），不用下拉菜单。
 * 下拉在手机上要长按展开、列表长时还得滚动，操作成本高；
 * 滚轮是系统级交互，拇指上下滑动即可，而且只能选预设档位 ——
 * 车端只认整数档位，滑块容易误触到非法值。
 *
 * **受控组件**：卡片本身不存编辑态，所有值都由父组件通过 props 下传。
 * 这三项配置来自三个独立的 chronos 服务（TargetSoc / AmpLimit /
 * GlobalChargeTimer），改完点「保存配置」才真正下发给车端 ——
 * 中间过程需要父组件统一管理「编辑值」与「已生效值」。
 */
@Component
export struct ChargeConfigCard {
  /** 当前电量（百分比），-1 表示未知。 */
  @Prop battery: number = -1;
  /** 充电上限（百分比），-1 表示未知。 */
  @Prop targetSoc: number = -1;
  /** 电流上限（安培），-1 表示未知。 */
  @Prop ampLimit: number = -1;
  /** 预约充电是否启用。 */
  @Prop timerActivated: boolean = false;
  /** 预约开始时刻（自 00:00 起的分钟数），-1 表示未设置。 */
  @Prop timerStartMinutes: number = -1;
  /** 预约结束时刻（自 00:00 起的分钟数），-1 表示未设置。 */
  @Prop timerStopMinutes: number = -1;
  /** 保存中（按钮禁用）。 */
  @Prop saving: boolean = false;

  /**
   * 「保存配置」按钮是否处于按压态。
   *
   * 系统 Button 的按压反馈是内建的，但它的高亮发生在**抬手**时才刷新，
   * 手指按住时看不到变化，松手才闪一下 —— 观感上像「延迟响应」。
   * 这里改成自绘按钮，用触摸事件直接驱动背景色，
   * 按下即变色，抬手即还原。
   */
  @State savePressed: boolean = false;

  /**
   * 车端**已生效**的充电上限（百分比），-1 表示未知。
   *
   * 与上面那组编辑值一起才能判断「有没有改动」——
   * 两者一致说明当前配置与车端一致，没有需要保存的内容。
   */
  @Prop savedTargetSoc: number = -1;
  /** 车端已生效的电流上限（安培），-1 表示未知。 */
  @Prop savedAmpLimit: number = -1;
  /** 车端已生效的预约充电开关。 */
  @Prop savedTimerActivated: boolean = false;
  /** 车端已生效的预约开始时刻（分钟数），-1 表示未设置。 */
  @Prop savedTimerStartMinutes: number = -1;
  /** 车端已生效的预约结束时刻（分钟数），-1 表示未设置。 */
  @Prop savedTimerStopMinutes: number = -1;

  /** 修改充电上限。 */
  onTargetSocChange?: (percent: number) => void;
  /** 修改电流上限。 */
  onAmpLimitChange?: (amps: number) => void;
  /** 修改预约充电开关。 */
  onTimerToggle?: (activated: boolean) => void;
  /** 修改预约时段。 */
  onTimerChange?: (startMinutes: number, stopMinutes: number) => void;
  /** 保存配置。 */
  onSave?: () => void;

  /**
   * 滚轮弹窗的通用包装。
   *
   * @param range       档位文案
   * @param selected    当前选中索引
   * @param onAccept    确认回调，参数是选中的索引
   */
  private showWheel(range: string[], selected: number,
    onAccept: (index: number) => void): void {
    this.getUIContext().showTextPickerDialog({
      range: range,
      selected: selected,
      canLoop: false,
      defaultPickerItemHeight: 44,
      alignment: DialogAlignment.Center,
      onAccept: (result: TextPickerResult) => {
        const raw = result.index;
        const index = typeof raw === 'number' ? raw : selected;
        onAccept(index);
      }
    });
  }

  /**
   * 打开充电上限滚轮。
   */
  private pickTargetSoc(): void {
    const levels = ChargeConfig.SOC_LEVELS;
    const labels: string[] = levels.map((level: number) => `${level}%`);
    let selected = levels.indexOf(this.targetSoc);
    if (selected < 0) {
      selected = levels.indexOf(80);
    }
    this.showWheel(labels, selected, (index: number) => {
      if (this.onTargetSocChange !== undefined) {
        this.onTargetSocChange(levels[index]);
      }
    });
  }

  /**
   * 打开电流上限滚轮。
   */
  private pickAmpLimit(): void {
    const levels = ChargeConfig.AMP_LEVELS;
    const labels: string[] = levels.map((level: number) => `${level} A`);
    let selected = levels.indexOf(this.ampLimit);
    if (selected < 0) {
      selected = levels.indexOf(16);
    }
    this.showWheel(labels, selected, (index: number) => {
      if (this.onAmpLimitChange !== undefined) {
        this.onAmpLimitChange(levels[index]);
      }
    });
  }

  /**
   * 打开时间选择弹窗。
   *
   * @param current 当前分钟数
   * @param onPick  选定时回调
   */
  private pickTime(current: number, onPick: (minutes: number) => void): void {
    const base = current >= 0 ? current : 22 * 60;
    const date = new Date();
    date.setHours(Math.floor(base / 60), base % 60, 0, 0);
    this.getUIContext().showTimePickerDialog({
      selected: date,
      useMilitaryTime: true,
      alignment: DialogAlignment.Center,
      onAccept: (result: TimePickerResult) => {
        onPick(result.hour * 60 + result.minute);
      }
    });
  }

  /**
   * 电量文案。
   */
  private batteryText(): string {
    return this.battery >= 0 ? `${Math.round(this.battery)}%` : '—';
  }

  /**
   * 充电上限文案。
   */
  private socText(): string {
    return this.targetSoc >= 0 ? `${this.targetSoc}%` : '—';
  }

  /**
   * 电流上限文案。
   */
  private ampText(): string {
    return this.ampLimit >= 0 ? `${this.ampLimit} A` : '—';
  }

  /**
   * 预约开始时刻文案。
   */
  private startText(): string {
    return this.timerStartMinutes >= 0 ? ChargeConfig.formatMinutes(this.timerStartMinutes) : '—';
  }

  /**
   * 预约结束时刻文案。
   */
  private stopText(): string {
    return this.timerStopMinutes >= 0 ? ChargeConfig.formatMinutes(this.timerStopMinutes) : '—';
  }

  /**
   * 保存按钮的背景色。
   *
   * 按下态用更深的一档颜色，让「按下去」这件事在手指接触的瞬间就可见。
   * 置灰态（与车端一致）不响应触摸，按下态颜色不会出现。
   */
  private saveButtonColor(): ResourceColor {
    if (!this.dirty()) {
      return $r('app.color.app_surface_sunken');
    }
    return this.savePressed
      ? $r('app.color.app_accent_pressed')
      : $r('app.color.app_accent');
  }

  /**
   * 跟踪保存按钮的按压状态。
   *
   * Down 立即置按压态，Up / Cancel 复位。
   * 手指划出按钮范围时上报的是 Cancel —— 一样要复位，
   * 否则按钮会一直停在按下色。
   *
   * 置灰态不参与按压 —— 没有需要保存的内容，按下去也不该有反馈。
   */
  private handleSaveTouch(event: TouchEvent): void {
    if (!this.dirty()) {
      this.savePressed = false;
      return;
    }
    switch (event.type) {
      case TouchType.Down:
        this.savePressed = true;
        break;
      case TouchType.Up:
      case TouchType.Cancel:
        this.savePressed = false;
        break;
      default:
        break;
    }
  }

  /**
   * 当前编辑值与车端已生效值是否有差异。
   *
   * 一致时「保存配置」置灰 —— 没有需要保存的内容，按钮可点只会让用户
   * 白等一次网络往返。
   *
   * 只比较**车端已读到的项**：某个值车端还没读到（-1）时无法判断，
   * 保守地认为它可能有改动，让按钮保持可用。
   */
  private dirty(): boolean {
    if (this.savedTargetSoc >= 0 && this.targetSoc !== this.savedTargetSoc) {
      return true;
    }
    if (this.savedAmpLimit >= 0 && this.ampLimit !== this.savedAmpLimit) {
      return true;
    }
    if (this.timerActivated !== this.savedTimerActivated) {
      return true;
    }
    if (this.savedTimerStartMinutes >= 0 && this.timerStartMinutes !== this.savedTimerStartMinutes) {
      return true;
    }
    if (this.savedTimerStopMinutes >= 0 && this.timerStopMinutes !== this.savedTimerStopMinutes) {
      return true;
    }
    return false;
  }

  build() {
    Column() {
      // ---------- 卡片头 ----------
      Row() {
        Text('充电')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_primary_text'))

        Blank()

        Text(this.batteryText())
          .fontSize(13)
          .fontColor($r('app.color.app_primary_text'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 13 })

      // ---------- 电量进度条 ----------
      // 蓝色填充 = 当前电量，竖线 = 充电上限位置。
      // 上限刻度线画在轨道上，用户一眼看出「还差多少到上限」。
      Stack({ alignContent: Alignment.TopStart }) {
        Stack()
          .width('100%')
          .height(8)
          .borderRadius(4)
          .backgroundColor($r('app.color.app_progress_track'))

        Stack()
          .width(`${Math.min(100, Math.max(0, this.battery))}%`)
          .height(8)
          .borderRadius(4)
          .backgroundColor($r('app.color.app_accent'))

        // 上限刻度线
        Stack()
          .width(2)
          .height(14)
          .backgroundColor($r('app.color.app_primary_text'))
          .borderRadius(1)
          .position({ x: `${this.targetSoc >= 0 ? this.targetSoc : 0}%` })
      }
      .width('100%')
      .height(14)
      .margin({ bottom: 4 })

      // ---------- 充电上限 ----------
      // 数值用「灰底圆角块」包起来，和下面的预约时段保持一致 ——
      // 块状样式本身就暗示「这是可点的」，比加一个 ▴ 箭头更明确，
      // 也不需要额外的视觉符号去解释。
      Row() {
        Text('充电上限')
          .fontSize(13.5)
          .fontColor($r('app.color.app_primary_text'))

        Blank()

        Text(this.socText())
          .fontSize(13.5)
          .fontColor($r('app.color.app_primary_text'))
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor($r('app.color.app_surface_sunken'))
          .borderRadius(4)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 11, bottom: 11 })
      .border({ width: { top: 1 }, color: $r('app.color.app_rule') })
      .onClick(() => {
        this.pickTargetSoc();
      })

      // ---------- 电流上限 ----------
      Row() {
        Text('电流上限')
          .fontSize(13.5)
          .fontColor($r('app.color.app_primary_text'))

        Blank()

        Text(this.ampText())
          .fontSize(13.5)
          .fontColor($r('app.color.app_primary_text'))
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor($r('app.color.app_surface_sunken'))
          .borderRadius(4)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 11, bottom: 11 })
      .border({ width: { top: 1 }, color: $r('app.color.app_rule') })
      .onClick(() => {
        this.pickAmpLimit();
      })

      // ---------- 预约充电 ----------
      Row() {
        Text('预约充电')
          .fontSize(13.5)
          .fontColor($r('app.color.app_primary_text'))

        Blank()

        Toggle({ type: ToggleType.Switch, isOn: this.timerActivated })
          .selectedColor($r('app.color.app_accent'))
          .switchPointColor($r('app.color.app_surface'))
          .width(42)
          .height(24)
          .onChange((isOn: boolean) => {
            if (this.onTimerToggle !== undefined) {
              this.onTimerToggle(isOn);
            }
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 11, bottom: 11 })
      .border({ width: { top: 1 }, color: $r('app.color.app_rule') })

      // ---------- 预约时段 ----------
      // 标题在左，两个时刻块在右 —— 与上方三行的「标签 + 右侧取值」结构一致。
      // 时刻块等宽，开始/结束视觉上对齐，扫一眼就知道这是一对。
      Row() {
        Text('预约时段')
          .fontSize(13.5)
          .fontColor($r('app.color.app_primary_text'))

        Blank()

        Row({ space: 6 }) {
          Text(this.startText())
            .fontSize(13.5)
            .fontColor($r('app.color.app_primary_text'))
            .textAlign(TextAlign.Center)
            .constraintSize({ minWidth: 56 })
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor($r('app.color.app_surface_sunken'))
            .borderRadius(4)
            .onClick(() => {
              this.pickTime(this.timerStartMinutes, (minutes: number) => {
                if (this.onTimerChange !== undefined) {
                  this.onTimerChange(minutes, this.timerStopMinutes);
                }
              });
            })

          Text('→')
            .fontSize(12)
            .fontColor($r('app.color.app_tertiary_text'))

          Text(this.stopText())
            .fontSize(13.5)
            .fontColor($r('app.color.app_primary_text'))
            .textAlign(TextAlign.Center)
            .constraintSize({ minWidth: 56 })
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor($r('app.color.app_surface_sunken'))
            .borderRadius(4)
            .onClick(() => {
              this.pickTime(this.timerStopMinutes, (minutes: number) => {
                if (this.onTimerChange !== undefined) {
                  this.onTimerChange(this.timerStartMinutes, minutes);
                }
              });
            })
        }
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 11, bottom: 11 })
      .border({ width: { top: 1 }, color: $r('app.color.app_rule') })

      // ---------- 保存配置 ----------
      // 与车端一致时置灰 —— 没有需要保存的内容。
      // 自绘而非用 Button：系统 Button 的按压高亮在抬手时才刷新，
      // 按住看不到变化；这里用 onTouch 直接驱动背景色，按下即变色。
      Row() {
        Text('保存配置')
          .fontSize(13.5)
          .fontColor(this.dirty() ? $r('app.color.app_on_accent') : $r('app.color.app_tertiary_text'))
      }
      .width('100%')
      .height(42)
      .justifyContent(FlexAlign.Center)
      .borderRadius(6)
      .backgroundColor(this.saveButtonColor())
      .margin({ top: 14 })
      .opacity(this.saving ? 0.6 : 1)
      .onTouch((event: TouchEvent) => {
        this.handleSaveTouch(event);
      })
      .onClick(() => {
        if (this.saving || !this.dirty()) {
          return;
        }
        if (this.onSave !== undefined) {
          this.onSave();
        }
      })
    }
    .width('100%')
    .padding({ top: 15, left: 16, right: 16, bottom: 16 })
    .border({ width: 1, color: $r('app.color.app_rule') })
    .borderRadius(8)
  }
}
