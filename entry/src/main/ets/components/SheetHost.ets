import { AirPurifyCard } from './AirPurifyCard';
import { CampModeCard } from './CampModeCard';
import { ChargeConfigCard } from './ChargeConfigCard';
import { FindCarCard } from './FindCarCard';
import { HealthCard } from './HealthCard';
import { TogglePhase } from './StateToggle';
import { VehicleCard } from './VehicleCard';
import { SheetKind } from './QuickEntryGrid';

/**
 * 半模态面板的内容宿主。
 *
 * 主界面点击入口后弹出的面板，里面放的是控制页 / 详情页已有的卡片组件。
 * 组件本身是「props 进、回调出」的纯展示层，状态全部由 Index 持有 ——
 * 所以面板里的开关与主界面的快捷开关天然同步。
 *
 * 面板只做内容分发，不含业务逻辑。
 */
@Component
export struct SheetHost {
  /** 当前面板种类。 */
  kind: SheetKind = SheetKind.NONE;

  // ---- 车辆健康 ----
  /** 整体健康总评：良好 / 需关注 / 未知。 */
  healthStatus: string = '未知';
  /** 保养状态文案。 */
  maintenanceStatus: string = '未知';
  /** 保养状态枚举值，供 UI 判颜色。 */
  maintenanceCode: number = 0;
  /** 距离下次保养的剩余天数，-1 表示未知。 */
  serviceRemainingDays: number = -1;
  /** 距离下次保养的剩余里程（km），-1 表示未知。 */
  serviceRemainingKm: number = -1;
  /** 制动液告警枚举值。 */
  brakeFluidWarning: number = -1;
  /** 冷却液告警枚举值。 */
  coolantWarning: number = -1;
  /** 玻璃水告警枚举值。 */
  washerFluidWarning: number = -1;
  /** 12V 蓄电池告警枚举值。 */
  lowVoltageBatteryWarning: number = -1;
  /** 四轮胎压告警枚举值，顺序：左前 / 右前 / 左后 / 右后。 */
  tyreWarnings: number[] = [];
  /** 外部灯光故障灯组数。 */
  lightFaultCount: number = 0;
  /** 外部灯光故障灯组名。 */
  lightFaultNames: string[] = [];

  // ---- 充电配置 ----
  /** 当前电量（百分比），-1 表示未知。 */
  battery: number = -1;
  /** 充电上限（百分比），-1 表示未知。 */
  chargeTargetSoc: number = -1;
  /** 电流上限（安培），-1 表示未知。 */
  chargeAmpLimit: number = -1;
  /** 预约充电是否启用。 */
  chargeTimerActivated: boolean = false;
  /** 预约开始时刻（自 00:00 起的分钟数），-1 表示未设置。 */
  chargeTimerStartMinutes: number = -1;
  /** 预约结束时刻（自 00:00 起的分钟数），-1 表示未设置。 */
  chargeTimerStopMinutes: number = -1;
  /** 充电配置保存中。 */
  chargeSaving: boolean = false;
  /** 车端已生效的充电上限（百分比），-1 表示未知。 */
  savedChargeTargetSoc: number = -1;
  /** 车端已生效的电流上限（安培），-1 表示未知。 */
  savedChargeAmpLimit: number = -1;
  /** 车端已生效的预约充电开关。 */
  savedChargeTimerActivated: boolean = false;
  /** 车端已生效的预约开始时刻（分钟数），-1 表示未知。 */
  savedChargeTimerStartMinutes: number = -1;
  /** 车端已生效的预约结束时刻（分钟数），-1 表示未知。 */
  savedChargeTimerStopMinutes: number = -1;

  // ---- 露营模式 ----
  /** 露营模式阶段。 */
  campPhase: TogglePhase = TogglePhase.OFF;
  /** 露营模式运行时长（分钟）。 */
  campDurationMinutes: number = 60;
  /** 露营模式剩余时间（分钟），0 表示未开启。 */
  campRemainingMinutes: number = 0;
  /** 剩余时间占全程的比例（0 ~ 1），用于进度条。 */
  campRemainingRatio: number = 0;
  /** 露营模式目标温度（摄氏度）。 */
  campCelsius: number = 22;

  // ---- 空气净化 ----
  /** 空气净化阶段。 */
  airPhase: TogglePhase = TogglePhase.OFF;
  /** AQI 指数，-1 表示未知。 */
  airAqi: number = -1;
  /** PM2.5 浓度（μg/m³），-1 表示未知。 */
  airPm25: number = -1;
  /** 空气净化是否禁用（驻车空调在跑时置灰）。 */
  airDisabled: boolean = false;

  // ---- 车辆控制 ----
  /** 整车锁阶段（ON = 未锁）。 */
  lockPhase: TogglePhase = TogglePhase.OFF;
  /** 尾门锁阶段（ON = 未锁）。 */
  trunkLockPhase: TogglePhase = TogglePhase.OFF;
  /** 尾门阶段（ON = 已打开）。 */
  trunkPhase: TogglePhase = TogglePhase.OFF;
  /** 车窗阶段（ON = 车窗开）。 */
  windowPhase: TogglePhase = TogglePhase.OFF;

  // ---- 寻车 ----
  /** 寻车按钮的瞬时高亮动作标识，为空表示不高亮。 */
  findCarFlashAction: string = '';

  // ---- 回调 ----
  /** 修改充电上限。 */
  onChargeTargetSocChange?: (percent: number) => void;
  /** 修改电流上限。 */
  onAmpLimitChange?: (amps: number) => void;
  /** 预约充电开关。 */
  onChargeTimerToggle?: (activated: boolean) => void;
  /** 预约时段。 */
  onChargeTimerChange?: (startMinutes: number, stopMinutes: number) => void;
  /** 保存充电配置。 */
  onChargeSave?: () => void;
  /** 点击露营模式开关。 */
  onCampToggle?: () => void;
  /** 调节运行时长。 */
  onCampDurationChange?: (minutes: number) => void;
  /** 修改露营模式目标温度。 */
  onCampTemperatureChange?: (celsius: number) => void;
  /** 点击空气净化开关。 */
  onAirToggle?: () => void;
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

  /**
   * 面板内容。
   */
  @Builder
  content() {
    Scroll() {
      Column() {
        if (this.kind === SheetKind.HEALTH) {
          HealthCard({
            healthStatus: this.healthStatus,
            maintenanceStatus: this.maintenanceStatus,
            maintenanceCode: this.maintenanceCode,
            serviceRemainingDays: this.serviceRemainingDays,
            serviceRemainingKm: this.serviceRemainingKm,
            brakeFluidWarning: this.brakeFluidWarning,
            coolantWarning: this.coolantWarning,
            washerFluidWarning: this.washerFluidWarning,
            lowVoltageBatteryWarning: this.lowVoltageBatteryWarning,
            tyreWarnings: this.tyreWarnings,
            lightFaultCount: this.lightFaultCount,
            lightFaultNames: this.lightFaultNames
          })
        } else if (this.kind === SheetKind.CHARGE) {
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
              if (this.onAmpLimitChange !== undefined) {
                this.onAmpLimitChange(amps);
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
        } else if (this.kind === SheetKind.CAMP) {
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
        } else if (this.kind === SheetKind.AIR) {
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
        } else if (this.kind === SheetKind.VEHICLE) {
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
        } else if (this.kind === SheetKind.FIND_CAR) {
          FindCarCard({
            flashAction: this.findCarFlashAction,
            onAction: (action: string) => {
              if (this.onFindCarAction !== undefined) {
                this.onFindCarAction(action);
              }
            }
          })
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, bottom: 20 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
  }

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
  }
}
