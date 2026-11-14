/**
 * 车辆控制页（占位）。
 *
 * UX 设计尚未定稿，先保留页面骨架与标题，内容待设计确认后实现。
 * 计划包含 6 组控制：车锁 / 尾门 / 车窗 / 驻车空调 / 空气净化 / 寻车。
 */
@Component
export struct Control {
  build() {
    Scroll() {
      Column({ space: 16 }) {
        Row() {
          Column({ space: 5 }) {
            Text('控制')
              .fontSize(23)
              .fontWeight(FontWeight.Normal)
              .fontColor($r('app.color.app_primary_text'))
            Text('6 类车控能力')
              .fontSize(11)
              .fontColor($r('app.color.app_tertiary_text'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: 20, bottom: 4 })
      }
      .width('100%')
      .padding({ left: 18, right: 18 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
  }
}
