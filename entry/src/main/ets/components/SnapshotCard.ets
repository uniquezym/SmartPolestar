import { SnapshotItem } from '../core/vehicle/VehicleSnapshot';

/**
 * 只读状态快照卡片。
 *
 * 展示某个状态域的当前值 —— 能力探测回答「支持什么」，
 * 这里回答「现在是什么状态」。
 */
@Component
export struct SnapshotCard {
  /** 组名。 */
  @Prop groupTitle: string = '';
  /** 该组的记录。 */
  @Prop items: SnapshotItem[] = [];

  /**
   * 一行记录。
   *
   * 只传结构性参数（是否末行），状态值在 Builder 内部现取 ——
   * Builder 的参数按值传递，状态值当参数传进来界面不会跟着刷新。
   */
  @Builder
  snapshotLine(item: SnapshotItem, last: boolean) {
    Row() {
      Text(item.title)
        .fontSize(13)
        .fontColor($r('app.color.app_secondary_text'))

      Blank()

      Text(item.value.length > 0 ? item.value : '—')
        .fontSize(13)
        .fontColor($r('app.color.app_primary_text'))
        .textAlign(TextAlign.End)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 8, bottom: 8 })
    .border({ width: { bottom: last ? 0 : 1 }, color: $r('app.color.app_rule') })
  }

  build() {
    Column() {
      Text(this.groupTitle)
        .fontSize(12)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_secondary_text'))
        .width('100%')
        .padding({ bottom: 4 })

      ForEach(this.items, (item: SnapshotItem, index: number) => {
        this.snapshotLine(item, index === this.items.length - 1)
      }, (item: SnapshotItem) => item.key)
    }
    .width('100%')
    .padding({ top: 12, left: 16, right: 16, bottom: 12 })
    .border({ width: 1, color: $r('app.color.app_rule') })
    .borderRadius(8)
  }
}
