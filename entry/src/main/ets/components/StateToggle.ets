import { AppIcon, AppIconName } from './Icons';

/**
 * 状态开关（三态按钮）。
 *
 * 对应 Nordic Instrument 设计语言的「状态即按钮」原则：
 * 二态功能（车锁 / 空调 / 净化 / 车窗）用单一按钮表达，按钮本身显示**当前状态**，
 * 而不是「点了会做什么」。
 *
 * 三个阶段：
 *   关闭   —— 透明底 + 灰图标 + 灰标签
 *   执行中 —— 蓝边 + 旋转指示器 + 蓝色「执行中」标签，禁止重复下发
 *   开启   —— 品牌蓝实底 + 白图标 + 蓝色标签 + 呼吸光晕
 *
 * 失败时**静默回滚**到点击前的状态：执行中的动画已经让用户看到「动作发生了」，
 * 状态未变即代表未生效，不再额外弹提示。
 */
export enum TogglePhase {
  /** 稳定关闭态。 */
  OFF = 0,
  /** 执行中，等待车端响应。 */
  PENDING = 1,
  /** 稳定开启态。 */
  ON = 2
}

/**
 * 开关的语义类型，决定图标与文案。
 */
export enum ToggleKind {
  /** 整车锁。 */
  LOCK = 'lock',
  /** 驻车空调。 */
  CLIMATE = 'climate',
  /** 空气净化。 */
  PURIFIER = 'air',
  /** 车窗。 */
  WINDOW = 'window'
}

/**
 * 三态状态开关。
 *
 * 用 @Component + @Prop 而非 @Builder：ArkUI 的 @Builder 按值传递参数，
 * 状态变量的变化不会触发内部 UI 刷新（见 StatusCard 内的说明）。
 */
@Component
export struct StateToggle {
  /** 语义类型。 */
  @Prop kind: ToggleKind = ToggleKind.LOCK;
  /** 当前阶段。 */
  @Prop phase: TogglePhase = TogglePhase.OFF;
  /** 是否禁用（互斥功能：另一项开启时置灰）。 */
  @Prop disabled: boolean = false;
  /** 点击回调，由父组件负责下发指令并回写 phase。 */
  onTap?: (kind: ToggleKind) => void;

  /**
   * 当前状态文案（标签显示的文字）。
   */
  private stateText(): string {
    if (this.phase === TogglePhase.PENDING) {
      return '执行中';
    }
    switch (this.kind) {
      case ToggleKind.LOCK:
        return this.phase === TogglePhase.ON ? '未锁' : '已锁';
      case ToggleKind.CLIMATE:
        return this.phase === TogglePhase.ON ? '空调开' : '空调关';
      case ToggleKind.PURIFIER:
        return this.phase === TogglePhase.ON ? '净化开' : '净化关';
      case ToggleKind.WINDOW:
        return this.phase === TogglePhase.ON ? '车窗开' : '车窗关';
      default:
        return '';
    }
  }

  /**
   * 当前图标。车锁在闭锁 / 开锁之间换图形，与原版一致。
   */
  private iconName(): AppIconName {
    switch (this.kind) {
      case ToggleKind.LOCK:
        return this.phase === TogglePhase.ON ? AppIconName.LOCK_OPEN : AppIconName.LOCK_CLOSED;
      case ToggleKind.CLIMATE:
        return AppIconName.CLIMATE_COOL;
      case ToggleKind.PURIFIER:
        return AppIconName.AIR;
      case ToggleKind.WINDOW:
        return AppIconName.WINDOW;
      default:
        return AppIconName.LOCK_CLOSED;
    }
  }

  build() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.Center }) {
        // 开启态：呼吸光晕
        if (this.phase === TogglePhase.ON) {
          // 呼吸光晕：用 Stack + border 实现（Circle 的 stroke 不支持线宽参数）
          Stack()
            .width(58)
            .height(58)
            .borderRadius(29)
            .border({ width: 1, color: $r('app.color.app_accent') })
            .opacity(0.28)
            .animation({ duration: 2800, curve: Curve.EaseInOut, iterations: -1 })
        }

        // 图标
        AppIcon({
          name: this.iconName(),
          iconSize: 24,
          color: this.phase === TogglePhase.ON
            ? $r('app.color.app_on_accent')
            : (this.phase === TogglePhase.PENDING
              ? $r('app.color.app_accent')
              : $r('app.color.app_secondary_text'))
        })
        .opacity(this.phase === TogglePhase.PENDING ? 0 : 1)
        .animation({ duration: 180, curve: Curve.EaseOut, iterations: 1 })

        // 执行中：旋转指示器
        if (this.phase === TogglePhase.PENDING) {
          LoadingProgress()
            .width(22)
            .height(22)
            .color($r('app.color.app_accent'))
        }
      }
      .width(54)
      .height(54)
      .borderRadius(27)
      .backgroundColor(this.phase === TogglePhase.ON
        ? $r('app.color.app_accent')
        : $r('app.color.app_surface'))
      .border({ width: 1.2, color: this.phase === TogglePhase.OFF
        ? $r('app.color.app_card_border')
        : $r('app.color.app_accent') })
      .opacity(this.disabled ? 0.35 : 1)

      // 状态标签
      Text(this.stateText())
        .fontSize(9)
        .fontColor(this.phase === TogglePhase.OFF
          ? $r('app.color.app_tertiary_text')
          : $r('app.color.app_accent_text'))
        .opacity(this.disabled ? 0.45 : 1)
    }
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      if (this.phase === TogglePhase.PENDING || this.disabled) {
        return;
      }
      if (this.onTap !== undefined) {
        this.onTap(this.kind);
      }
    })
  }
}
