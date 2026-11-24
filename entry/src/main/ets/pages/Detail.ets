import { HealthCard } from '../components/HealthCard';
import { StateRow } from '../components/StateRow';
import { AppIconName } from '../components/Icons';

/**
 * 车辆详情页。
 *
 * 当前承载「健康与保养」卡片与「车辆能力」入口；
 * 基础信息 / 里程与能耗 / 最后停车位置待 UX 定稿后再补。
 */
@Component
export struct Detail {
  /** 整体健康总评：良好 / 需关注 / 未知。 */
  @Prop healthStatus: string = '未知';
  /** 保养状态文案。 */
  @Prop maintenanceStatus: string = '未知';
  /** 保养状态枚举值，供 UI 判颜色。 */
  @Prop maintenanceCode: number = 0;
  /** 距离下次保养的剩余天数，-1 表示未知。 */
  @Prop serviceRemainingDays: number = -1;
  /** 距离下次保养的剩余里程（km），-1 表示未知。 */
  @Prop serviceRemainingKm: number = -1;
  /** 制动液告警枚举值。 */
  @Prop brakeFluidWarning: number = 0;
  /** 冷却液告警枚举值。 */
  @Prop coolantWarning: number = 0;
  /** 玻璃水告警枚举值。 */
  @Prop washerFluidWarning: number = 0;
  /** 12V 蓄电池告警枚举值。 */
  @Prop lowVoltageBatteryWarning: number = 0;
  /** 四轮胎压告警枚举值，顺序：左前 / 右前 / 左后 / 右后。 */
  @Prop tyreWarnings: number[] = [];
  /** 外部灯光故障灯组数。 */
  @Prop lightFaultCount: number = 0;
  /** 外部灯光故障灯组名。 */
  @Prop lightFaultNames: string[] = [];

  /**
   * 「车辆能力」入口的点击回调。
   */
  onCapabilityTap?: () => void;

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Row() {
          Column({ space: 5 }) {
            Text('车辆详情')
              .fontSize(23)
              .fontWeight(FontWeight.Normal)
              .fontColor($r('app.color.app_primary_text'))
            Text('全部只读状态')
              .fontSize(11)
              .fontColor($r('app.color.app_tertiary_text'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: 20, bottom: 4 })

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

        // ---------- 车辆能力入口 ----------
        StateRow({
          icon: AppIconName.TAB_DETAIL,
          label: '车辆能力',
          value: '查看本车支持的功能',
          showChevron: true,
          showDivider: false,
          onTap: () => {
            if (this.onCapabilityTap !== undefined) {
              this.onCapabilityTap();
            }
          }
        })
      }
      .width('100%')
      .padding({ left: 18, right: 18 })
    }
    .width('100%')
    .height('100%')
    // 内容比屏幕短时默认会垂直居中，这里改成从上往下排。
    .align(Alignment.Top)
    .backgroundColor($r('app.color.app_background'))
  }
}
