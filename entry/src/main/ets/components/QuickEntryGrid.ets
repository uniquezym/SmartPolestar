import { AppIcon, AppIconName } from './Icons';

/**
 * 半模态面板的种类。
 *
 * NONE 表示当前没有面板打开。主界面入口宫格与半模态内容都靠它对齐 ——
 * 新增一类功能时，枚举加一项、宫格加一项、Index 的面板分支加一项即可。
 */
export enum SheetKind {
  /** 没有面板打开。 */
  NONE = 'none',
  /** 车辆健康与保养。 */
  HEALTH = 'health',
  /** 充电配置。 */
  CHARGE = 'charge',
  /** 露营模式。 */
  CAMP = 'camp',
  /** 空气净化。 */
  AIR = 'air',
  /** 车辆控制（门锁 / 尾门 / 车窗）。 */
  VEHICLE = 'vehicle',
  /** 寻车。 */
  FIND_CAR = 'find_car'
}

/**
 * 一个入口项。
 */
interface QuickEntry {
  /** 打开哪种半模态。 */
  kind: SheetKind;
  /** 入口文案。 */
  label: string;
  /** 入口图标。 */
  icon: AppIconName;
}

/**
 * 主界面的功能入口宫格。
 *
 * 概览页从上往下读完是「车况」，
 * 这里补一个「要做什么」的横向分组 ——
 * 每个入口点开后是一个半模态面板，里面放对应的功能卡片。
 *
 * 面板里的卡片与主界面的快捷开关共用同一份状态（都由 Index 持有），
 * 所以在面板里操作，主界面上的开关会同步变化。
 */
@Component
export struct QuickEntryGrid {
  /** 点击某个入口。 */
  onOpen?: (kind: SheetKind) => void;

  /** 全部入口项。 */
  private static readonly ENTRIES: QuickEntry[] = [
    { kind: SheetKind.HEALTH, label: '车辆健康', icon: AppIconName.HEALTH },
    { kind: SheetKind.CHARGE, label: '充电设置', icon: AppIconName.CHARGE },
    { kind: SheetKind.CAMP, label: '露营模式', icon: AppIconName.CLIMATE_AIRFLOW },
    { kind: SheetKind.AIR, label: '空气净化', icon: AppIconName.AIR },
    { kind: SheetKind.VEHICLE, label: '车辆控制', icon: AppIconName.LOCK_SIMPLE },
    { kind: SheetKind.FIND_CAR, label: '寻车', icon: AppIconName.HORN }
  ];

  build() {
    Column() {
      Text('车辆功能')
        .fontSize(12.5)
        .fontColor($r('app.color.app_secondary_text'))
        .width('100%')
        .margin({ bottom: 12 })

      Grid() {
        ForEach(QuickEntryGrid.ENTRIES, (entry: QuickEntry) => {
          GridItem() {
            Column({ space: 7 }) {
              AppIcon({
                name: entry.icon,
                iconSize: 21,
                color: $r('app.color.app_secondary_text')
              })
              .width(21)
              .height(21)

              Text(entry.label)
                .fontSize(11.5)
                .fontColor($r('app.color.app_primary_text'))
            }
            .width('100%')
            .height(66)
            .justifyContent(FlexAlign.Center)
            .borderRadius(8)
            .backgroundColor($r('app.color.app_surface'))
            .border({ width: 1, color: $r('app.color.app_card_border') })
            .onClick(() => {
              if (this.onOpen !== undefined) {
                this.onOpen(entry.kind);
              }
            })
          }
        }, (entry: QuickEntry) => entry.kind)
      }
      .columnsTemplate('1fr 1fr 1fr')
      .rowsTemplate('1fr 1fr')
      .columnsGap(10)
      .rowsGap(10)
      .width('100%')
      .height(142)
    }
    .width('100%')
  }
}
