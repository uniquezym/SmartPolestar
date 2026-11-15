import { AppIconName } from './Icons';
import { SwitchRow } from './SwitchRow';
import { TogglePhase } from './StateToggle';

/**
 * 车辆卡片（门锁与尾门）。
 *
 * 对应设计稿 `design/polestar-volvo-ux/index.html` 的第三张 `.ctrl`：
 *   卡片头（车辆 / 门锁与尾门）
 *   → 整车锁 / 尾门锁 / 尾门开合 / 全部车窗 四行开关
 *
 * 开关语义与设计稿一致：**滑块靠右表示「未锁 / 打开」**，
 * 靠左表示「已锁 / 关闭」—— 锁车与解锁互为反向动作，
 * 开关表达的是「解锁」这一侧的状态。
 */
@Component
export struct VehicleCard {
  /** 整车锁阶段（ON = 未锁）。 */
  @Prop lockPhase: TogglePhase = TogglePhase.OFF;
  /** 尾门锁阶段（ON = 未锁）。 */
  @Prop trunkLockPhase: TogglePhase = TogglePhase.OFF;
  /** 尾门阶段（ON = 已打开）。 */
  @Prop trunkPhase: TogglePhase = TogglePhase.OFF;
  /** 车窗阶段（ON = 车窗开）。 */
  @Prop windowPhase: TogglePhase = TogglePhase.OFF;

  /** 点击整车锁开关。 */
  onLockToggle?: () => void;
  /** 点击尾门锁开关。 */
  onTrunkLockToggle?: () => void;
  /** 点击尾门开合开关。 */
  onTrunkToggle?: () => void;
  /** 点击全部车窗开关。 */
  onWindowToggle?: () => void;

  build() {
    Column() {
      // ---------- 卡片头 ----------
      Row() {
        Text('车辆')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_primary_text'))

        Blank()

        Text('门锁与尾门')
          .fontSize(10)
          .fontColor($r('app.color.app_tertiary_text'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 13 })

      // ---------- 四行开关 ----------
      SwitchRow({
        icon: AppIconName.LOCK_SIMPLE,
        label: '整车锁',
        phase: this.lockPhase,
        offText: '已锁',
        onText: '未锁',
        onTap: () => {
          if (this.onLockToggle !== undefined) {
            this.onLockToggle();
          }
        }
      })

      SwitchRow({
        icon: AppIconName.LOCK_SIMPLE,
        label: '尾门锁',
        phase: this.trunkLockPhase,
        offText: '已锁',
        onText: '未锁',
        onTap: () => {
          if (this.onTrunkLockToggle !== undefined) {
            this.onTrunkLockToggle();
          }
        }
      })

      SwitchRow({
        icon: AppIconName.TRUNK,
        label: '尾门开合',
        phase: this.trunkPhase,
        offText: '已关闭',
        onText: '已打开',
        onTap: () => {
          if (this.onTrunkToggle !== undefined) {
            this.onTrunkToggle();
          }
        }
      })

      SwitchRow({
        icon: AppIconName.WINDOW,
        label: '全部车窗',
        phase: this.windowPhase,
        offText: '车窗关',
        onText: '车窗开',
        lastRow: true,
        onTap: () => {
          if (this.onWindowToggle !== undefined) {
            this.onWindowToggle();
          }
        }
      })
    }
    .width('100%')
    .padding({ top: 15, left: 16, right: 16, bottom: 16 })
    .border({ width: 1, color: $r('app.color.app_rule') })
    .borderRadius(8)
  }
}
