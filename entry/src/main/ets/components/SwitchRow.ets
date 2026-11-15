import { AppIcon, AppIconName } from './Icons';
import { TogglePhase } from './StateToggle';

/**
 * 行内状态开关（一行一个功能）。
 *
 * 对应设计稿 `design/polestar-volvo-ux/index.html` 的 `.swrow`：
 *   图标 + 功能名 ......... 状态文案 ......... 开关本体
 *
 * **为什么不用系统 Toggle**：系统开关只有 on/off 两态，
 * 无法表达「验证中」「执行中」这类中间过程。开关功能下发指令要经过
 * 指纹门禁和车端确认，中间必然有几百毫秒到十几秒的等待期，
 * 这段时间必须让用户知道「我点的是哪个、现在到哪一步了」。
 *
 * **滑块位置在过渡态不动**是这套设计的关键：
 * 开关正要往右滑，滑块却先跳到右边再转圈，用户会以为状态已经生效。
 * 滑块留在原位 + 转圈 = 「正在过去，还没到」，落定后再补位动画过去。
 *
 * 四种形态：
 *   关闭   —— 灰轨道 + 滑块靠左
 *   开启   —— 品牌蓝轨道 + 滑块靠右
 *   验证中 —— 蓝边淡底 + 滑块半透明（指令尚未下发，位置不变）
 *   执行中 —— 轨道半透明 + 滑块转圈（位置不变）
 */
@Component
export struct SwitchRow {
  /** 左侧图标。 */
  @Prop icon: AppIconName = AppIconName.LOCK_CLOSED;
  /** 功能名。 */
  @Prop label: string = '';
  /** 当前阶段。 */
  @Prop @Watch('onPhaseChanged') phase: TogglePhase = TogglePhase.OFF;
  /** 关闭态的文案。 */
  @Prop offText: string = '';
  /** 开启态的文案。 */
  @Prop onText: string = '';
  /** 副说明，放在功能名下方。 */
  @Prop detail: string = '';
  /** 是否禁用（互斥功能：另一项开启时置灰）。 */
  @Prop disabled: boolean = false;
  /** 是否为组内最后一行（最后一行不画底部分隔线）。 */
  @Prop lastRow: boolean = false;
  /** 点击回调。 */
  onTap?: () => void;

  /**
   * 最近一次确认的稳定状态（开启 / 关闭）。
   *
   * 过渡态（验证中 / 执行中）需要用它来决定滑块停在哪 ——
   * 滑块必须留在**点击前**的位置，而不是目标位置。
   */
  @State stable: TogglePhase = TogglePhase.OFF;

  aboutToAppear(): void {
    // 首次渲染若已是开启态，@Watch 不会触发，这里补一次。
    if (this.phase === TogglePhase.ON) {
      this.stable = TogglePhase.ON;
    }
  }

  /**
   * 阶段变化时记录稳定状态。
   *
   * 只有落定到开启 / 关闭才更新 stable；进入过渡态时保留旧值，
   * 这样滑块才知道「该停在哪」。
   */
  private onPhaseChanged(): void {
    if (this.phase === TogglePhase.ON || this.phase === TogglePhase.OFF) {
      this.stable = this.phase;
    }
  }

  /**
   * 行内状态文案。
   *
   * 过渡态优先于开关本身的状态 —— 用户关心的是「现在到哪一步了」，
   * 而不是「现在的状态是什么」。
   */
  private stateText(): string {
    if (this.phase === TogglePhase.VERIFYING) {
      return '验证中';
    }
    if (this.phase === TogglePhase.PENDING) {
      return '执行中';
    }
    return this.phase === TogglePhase.ON ? this.onText : this.offText;
  }

  /**
   * 轨道底色。
   */
  private trackColor(): ResourceColor {
    if (this.phase === TogglePhase.OFF) {
      return $r('app.color.app_surface_sunken');
    }
    // 验证中用淡蓝底 + 蓝边，表示「待执行」；
    // 执行中用实蓝底 + 整体半透明，表示「已在路上」。
    return this.phase === TogglePhase.VERIFYING
      ? $r('app.color.app_accent_soft')
      : $r('app.color.app_accent');
  }

  /**
   * 轨道边框色。关闭态用细发丝线，其余状态用品牌蓝。
   */
  private trackBorder(): ResourceColor {
    return this.phase === TogglePhase.OFF
      ? $r('app.color.app_card_border')
      : $r('app.color.app_accent');
  }

  /**
   * 滑块的水平偏移。
   *
   * 滑块默认居中于 42×24 轨道（上下各留 3vp），这里只负责左右挪动：
   * 关闭态偏左 9vp（离左边缘 3vp），开启态偏右 9vp（离右边缘 3vp），
   * 行程正好 18vp。
   *
   * **验证中与执行中都用 stable** —— 保持点击前的位置，
   * 等状态落定后再由 animation 补位过去。
   */
  private knobOffset(): number {
    if (this.phase === TogglePhase.PENDING || this.phase === TogglePhase.VERIFYING) {
      return this.stable === TogglePhase.ON ? 9 : -9;
    }
    return this.phase === TogglePhase.ON ? 9 : -9;
  }

  build() {
    Row() {
      // 左侧：图标 + 功能名
      Row({ space: 9 }) {
        AppIcon({ name: this.icon, iconSize: 19, color: $r('app.color.app_secondary_text') })
          .width(19)
          .height(19)

        Column({ space: 2 }) {
          Text(this.label)
            .fontSize(13.5)
            .fontColor($r('app.color.app_primary_text'))
          if (this.detail.length > 0) {
            Text(this.detail)
              .fontSize(10.5)
              .fontColor($r('app.color.app_tertiary_text'))
          }
        }
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)

      // 状态文案
      Text(this.stateText())
        .fontSize(10)
        .fontColor(this.phase === TogglePhase.OFF
          ? $r('app.color.app_tertiary_text')
          : $r('app.color.app_accent_text'))
        .margin({ right: 10 })

      // 开关本体：42×24 轨道 + 18×18 滑块
      // 用 Alignment.Center 让滑块在轨道里上下居中（各留 3vp），
      // 左右位置交给 translate —— 不能用 Alignment.Start：
      // ArkUI 的 Start 是「横向贴左 + 纵向居中」，叠上 margin 会把滑块顶下去。
      Stack({ alignContent: Alignment.Center }) {
        // 轨道
        Stack()
          .width(42)
          .height(24)
          .borderRadius(12)
          .backgroundColor(this.trackColor())
          .border({ width: 1, color: this.trackBorder() })
          .opacity(this.phase === TogglePhase.PENDING ? 0.45 : 1)

        // 滑块。执行中换成转圈指示器，位置保持不变。
        Stack({ alignContent: Alignment.Center }) {
          if (this.phase === TogglePhase.PENDING) {
            LoadingProgress()
              .width(16)
              .height(16)
              .color($r('app.color.app_on_accent'))
          } else {
            Stack()
              .width(18)
              .height(18)
              .borderRadius(9)
              .backgroundColor(this.phase === TogglePhase.VERIFYING
                ? $r('app.color.app_surface_muted')
                : $r('app.color.app_surface'))
              .border({ width: 1, color: this.phase === TogglePhase.OFF
                ? $r('app.color.app_card_border')
                : $r('app.color.app_accent') })
              .opacity(this.phase === TogglePhase.VERIFYING ? 0.35 : 1)
          }
        }
        .width(18)
        .height(18)
        .borderRadius(9)
        .translate({ x: this.knobOffset() })
        .animation({ duration: 220, curve: Curve.EaseInOut })
      }
      .width(42)
      .height(24)
      .borderRadius(12)
      // 只有开关本身可点，行内文字（图标 / 功能名 / 状态）不响应
      .onClick(() => {
        if (this.phase === TogglePhase.PENDING ||
          this.phase === TogglePhase.VERIFYING ||
          this.disabled) {
          return;
        }
        if (this.onTap !== undefined) {
          this.onTap();
        }
      })
    }
    .width('100%')
    .padding({ top: 11, bottom: 11 })
    .border({ width: { bottom: this.lastRow ? 0 : 1 }, color: $r('app.color.app_rule') })
    .opacity(this.disabled ? 0.4 : 1)
  }
}
