import { AirPurifyCard } from '../components/AirPurifyCard';
import { CampModeCard } from '../components/CampModeCard';
import { ChargeConfigCard } from '../components/ChargeConfigCard';
import { FindCarCard } from '../components/FindCarCard';
import { TogglePhase } from '../components/StateToggle';
import { VehicleCard } from '../components/VehicleCard';

/**
 * 车辆控制页。
 *
 * 对应设计稿 `design/polestar-volvo-ux/index.html` 的 `#p-control`：
 *   顶栏只有「控制」标题 → 分组卡片（露营模式 / 空气净化 / 车辆 / 寻车）。
 *
 * 页面是纯展示层：所有状态由 `Index` 持有并以 props 传入，
 * 所有操作通过回调上抛，页面本身不下发任何指令。
 */
@Component
export struct Control {
  /** 露营模式阶段（关闭 / 开启 / 验证中 / 执行中）。 */
  @Prop campPhase: TogglePhase = TogglePhase.OFF;
  /** 露营模式运行时长（分钟）。 */
  @Prop campDurationMinutes: number = 60;
  /** 露营模式剩余时间（分钟），0 表示未开启。 */
  @Prop campRemainingMinutes: number = 0;
  /** 剩余时间占全程的比例（0 ~ 1），用于进度条。 */
  @Prop campRemainingRatio: number = 0;
  /** 露营模式目标温度（摄氏度）。 */
  @Prop campCelsius: number = 22;

  /** 空气净化阶段。 */
  @Prop airPhase: TogglePhase = TogglePhase.OFF;
  /** AQI 指数，-1 表示未知。 */
  @Prop airAqi: number = -1;
  /** PM2.5 浓度（μg/m³），-1 表示未知。 */
  @Prop airPm25: number = -1;
  /** 空气净化是否禁用（驻车空调在跑时置灰）。 */
  @Prop airDisabled: boolean = false;

  // ---- 充电配置 ----
  /** 当前电量（百分比），-1 表示未知。 */
  @Prop battery: number = -1;
  /** 充电上限（百分比），-1 表示未知。 */
  @Prop chargeTargetSoc: number = -1;
  /** 电流上限（安培），-1 表示未知。 */
  @Prop chargeAmpLimit: number = -1;
  /** 预约充电是否启用。 */
  @Prop chargeTimerActivated: boolean = false;
  /** 预约开始时刻（自 00:00 起的分钟数），-1 表示未设置。 */
  @Prop chargeTimerStartMinutes: number = -1;
  /** 预约结束时刻（自 00:00 起的分钟数），-1 表示未设置。 */
  @Prop chargeTimerStopMinutes: number = -1;
  /** 充电配置保存中。 */
  @Prop chargeSaving: boolean = false;
  /** 车端已生效的充电上限（百分比），-1 表示未知。 */
  @Prop savedChargeTargetSoc: number = -1;
  /** 车端已生效的电流上限（安培），-1 表示未知。 */
  @Prop savedChargeAmpLimit: number = -1;
  /** 车端已生效的预约充电开关。 */
  @Prop savedChargeTimerActivated: boolean = false;
  /** 车端已生效的预约开始时刻（分钟数），-1 表示未设置。 */
  @Prop savedChargeTimerStartMinutes: number = -1;
  /** 车端已生效的预约结束时刻（分钟数），-1 表示未设置。 */
  @Prop savedChargeTimerStopMinutes: number = -1;

  /** 整车锁阶段（ON = 未锁）。 */
  @Prop lockPhase: TogglePhase = TogglePhase.OFF;
  /** 尾门锁阶段（ON = 未锁）。 */
  @Prop trunkLockPhase: TogglePhase = TogglePhase.OFF;
  /** 尾门阶段（ON = 已打开）。 */
  @Prop trunkPhase: TogglePhase = TogglePhase.OFF;
  /** 车窗阶段（ON = 车窗开）。 */
  @Prop windowPhase: TogglePhase = TogglePhase.OFF;

  /** 点击露营模式开关。 */
  onCampToggle?: () => void;
  /** 调节运行时长。 */
  onCampDurationChange?: (minutes: number) => void;
  /** 修改露营模式目标温度。 */
  onCampTemperatureChange?: (celsius: number) => void;
  /** 点击空气净化开关。 */
  onAirToggle?: () => void;
  /** 修改充电上限。 */
  onChargeTargetSocChange?: (percent: number) => void;
  /** 修改电流上限。 */
  onChargeAmpLimitChange?: (amps: number) => void;
  /** 修改预约充电开关。 */
  onChargeTimerToggle?: (activated: boolean) => void;
  /** 修改预约时段。 */
  onChargeTimerChange?: (startMinutes: number, stopMinutes: number) => void;
  /** 保存充电配置。 */
  onChargeSave?: () => void;
  /** 点击整车锁开关。 */
  onLockToggle?: () => void;
  /** 点击尾门锁开关。 */
  onTrunkLockToggle?: () => void;
  /** 点击尾门开合开关。 */
  onTrunkToggle?: () => void;
  /** 点击全部车窗开关。 */
  onWindowToggle?: () => void;
  /** 点击寻车按钮（action = honk / flash / honk-flash）。 */
  onFindCarAction?: (action: string) => void;
  /** 点击退出登录。 */
  onLogout?: () => void;

  /**
   * 「退出登录」按钮是否处于按压态。
   *
   * 与充电卡片的「保存配置」一致 —— 自绘按钮 + 触摸事件驱动背景色，
   * 按下即变色，不依赖系统 Button 的延迟高亮。
   */
  @State logoutPressed: boolean = false;

  /**
   * 跟踪「退出登录」按钮的按压状态。
   *
   * 手指划出按钮范围时上报 Cancel，同样要复位，
   * 否则按钮会一直停在按下色。
   */
  private handleLogoutTouch(event: TouchEvent): void {
    switch (event.type) {
      case TouchType.Down:
        this.logoutPressed = true;
        break;
      case TouchType.Up:
      case TouchType.Cancel:
        this.logoutPressed = false;
        break;
      default:
        break;
    }
  }

  build() {
    Scroll() {
      Column() {
        // ---------- 顶栏 ----------
        Text('控制')
          .fontSize(23)
          .fontWeight(FontWeight.Normal)
          .fontColor($r('app.color.app_primary_text'))
          .width('100%')
          .margin({ top: 20, bottom: 22 })

        // ---------- 露营模式 ----------
        CampModeCard({
          phase: this.campPhase,
          durationMinutes: this.campDurationMinutes,
          remainingMinutes: this.campRemainingMinutes,
          remainingRatio: this.campRemainingRatio,
          celsius: this.campCelsius,
          onToggle: () => {
            if (this.onCampToggle !== undefined) {
              this.onCampToggle();
            }
          },
          onDurationChange: (minutes: number) => {
            if (this.onCampDurationChange !== undefined) {
              this.onCampDurationChange(minutes);
            }
          },
          onTemperatureChange: (celsius: number) => {
            if (this.onCampTemperatureChange !== undefined) {
              this.onCampTemperatureChange(celsius);
            }
          }
        })
        .margin({ bottom: 11 })

        // ---------- 空气净化 ----------
        AirPurifyCard({
          phase: this.airPhase,
          aqi: this.airAqi,
          pm25: this.airPm25,
          disabled: this.airDisabled,
          onToggle: () => {
            if (this.onAirToggle !== undefined) {
              this.onAirToggle();
            }
          }
        })
        .margin({ bottom: 11 })

        // ---------- 充电配置 ----------
        ChargeConfigCard({
          battery: this.battery,
          targetSoc: this.chargeTargetSoc,
          ampLimit: this.chargeAmpLimit,
          timerActivated: this.chargeTimerActivated,
          timerStartMinutes: this.chargeTimerStartMinutes,
          timerStopMinutes: this.chargeTimerStopMinutes,
          saving: this.chargeSaving,
          savedTargetSoc: this.savedChargeTargetSoc,
          savedAmpLimit: this.savedChargeAmpLimit,
          savedTimerActivated: this.savedChargeTimerActivated,
          savedTimerStartMinutes: this.savedChargeTimerStartMinutes,
          savedTimerStopMinutes: this.savedChargeTimerStopMinutes,
          onTargetSocChange: (percent: number) => {
            if (this.onChargeTargetSocChange !== undefined) {
              this.onChargeTargetSocChange(percent);
            }
          },
          onAmpLimitChange: (amps: number) => {
            if (this.onChargeAmpLimitChange !== undefined) {
              this.onChargeAmpLimitChange(amps);
            }
          },
          onTimerToggle: (activated: boolean) => {
            if (this.onChargeTimerToggle !== undefined) {
              this.onChargeTimerToggle(activated);
            }
          },
          onTimerChange: (startMinutes: number, stopMinutes: number) => {
            if (this.onChargeTimerChange !== undefined) {
              this.onChargeTimerChange(startMinutes, stopMinutes);
            }
          },
          onSave: () => {
            if (this.onChargeSave !== undefined) {
              this.onChargeSave();
            }
          }
        })
        .margin({ bottom: 11 })

        // ---------- 车辆 ----------
        VehicleCard({
          lockPhase: this.lockPhase,
          trunkLockPhase: this.trunkLockPhase,
          trunkPhase: this.trunkPhase,
          windowPhase: this.windowPhase,
          onLockToggle: () => {
            if (this.onLockToggle !== undefined) {
              this.onLockToggle();
            }
          },
          onTrunkLockToggle: () => {
            if (this.onTrunkLockToggle !== undefined) {
              this.onTrunkLockToggle();
            }
          },
          onTrunkToggle: () => {
            if (this.onTrunkToggle !== undefined) {
              this.onTrunkToggle();
            }
          },
          onWindowToggle: () => {
            if (this.onWindowToggle !== undefined) {
              this.onWindowToggle();
            }
          }
        })
        .margin({ bottom: 11 })

        // ---------- 寻车 ----------
        FindCarCard({
          onAction: (action: string) => {
            if (this.onFindCarAction !== undefined) {
              this.onFindCarAction(action);
            }
          }
        })
        .margin({ bottom: 11 })

        // ---------- 退出登录 ----------
        // 自绘而非用 Button：系统 Button 的按压高亮在抬手时才刷新，
        // 按住看不到变化；这里用 onTouch 直接驱动背景色，按下即变色。
        Row() {
          Text('退出登录')
            .fontSize(14)
            .fontColor($r('app.color.app_accent_text'))
        }
        .width('100%')
        .height(46)
        .justifyContent(FlexAlign.Center)
        .borderRadius(8)
        .backgroundColor(this.logoutPressed
          ? $r('app.color.app_accent_soft_pressed')
          : $r('app.color.app_accent_soft'))
        .border({ width: 1, color: $r('app.color.app_accent') })
        .margin({ top: 4, bottom: 24 })
        .onTouch((event: TouchEvent) => {
          this.handleLogoutTouch(event);
        })
        .onClick(() => {
          if (this.onLogout !== undefined) {
            this.onLogout();
          }
        })
      }
      .width('100%')
      .padding({ left: 18, right: 18 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
  }
}
