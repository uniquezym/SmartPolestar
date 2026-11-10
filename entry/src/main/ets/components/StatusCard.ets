/**
 * 状态卡片组件。
 *
 * 为什么用独立 @Component 而不是 @Builder：
 *
 *   ArkUI 的 @Builder 默认按值传递参数，官方文档明确写着
 *   「当传递的参数为状态变量时，状态变量的改变不会引起 @Builder 函数内的 UI 刷新」，
 *   且限制条件第 3 条：「@Builder 传入的参数是两个或两个以上，且未使用按回调传递参数，
 *   不会触发动态渲染 UI」。
 *
 *   本卡片有 title / value / detail 三个参数，走 @Builder 时状态永远不刷新；
 *   改用 @Component + @Prop 后，父组件的 @State 变化会正常触发子组件重绘。
 */
@Component
export struct StatusCard {
  /** 卡片标题。 */
  @Prop title: ResourceStr = '';
  /** 主数值。 */
  @Prop value: string = '';
  /** 补充说明，为空时不显示。 */
  @Prop detail: string = '';

  build() {
    Column({ space: 6 }) {
      Text(this.title)
        .fontSize(13)
        .fontColor($r('app.color.app_secondary_text'))
      Text(this.value)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_primary_text'))
      if (this.detail.length > 0) {
        Text(this.detail)
          .fontSize(12)
          .fontColor($r('app.color.app_secondary_text'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.app_card_background'))
    .borderRadius(10)
  }
}
