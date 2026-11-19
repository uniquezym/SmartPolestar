import { AppIcon, AppIconName } from './Icons';

/**
 * 寻车卡片。
 *
 * 对应设计稿 `design/polestar-volvo-ux/index.html` 的第四张 `.ctrl`：
 *   卡片头（寻车 / 需物理在场）
 *   → 鸣笛 / 闪灯 两枚描边按钮（等宽并排）
 *   → 「鸣笛并闪灯」按钮（整行，与上面两枚同款样式）
 *
 * 三个动作都是一次性的，没有状态回读 —— 下发成功即提示，不做轮询。
 * 按钮是「动作」不是「状态」，因此三个按钮样式一致，都不带选中态；
 * 指令真正下发成功后给一次短暂的品牌蓝高亮，表示「指令已触发」。
 *
 * **指纹门禁**：寻车会远程驱动车辆鸣笛 / 闪灯，属于高风险操作，
 * 指纹校验由上层（Index）完成 —— 指纹弹窗需要 UI 上下文，
 * 卡片自己弹不了。因此高亮的触发时机也交给上层决定：
 * 点击时只上报动作，校验通过且指令下发成功后才点亮高亮。
 */
@Component
export struct FindCarCard {
  /**
   * 最近一次成功触发的动作，用于瞬时高亮。
   *
   * 由上层在指纹校验通过、指令下发成功后设置，
   * 超时后清空（清空时机也在上层）。
   */
  @Prop flashAction: string = '';

  /**
   * 点击按钮。
   *
   * @param action 动作标识（honk / flash / honk-flash）
   */
  onAction?: (action: string) => void;

  /**
   * 按钮。
   *
   * 三个按钮都是「动作」而非「状态」，样式完全一致：
   * 描边、无填充 —— 实心品牌蓝会被读成「已选中」。
   *
   * @param label  按钮文案
   * @param icon   按钮图标
   * @param action 动作标识
   */
  @Builder
  private actionButton(label: string, icon: AppIconName, action: string) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 7 }) {
        AppIcon({
          name: icon,
          iconSize: 16,
          color: this.flashAction === action
            ? $r('app.color.app_accent_text')
            : $r('app.color.app_primary_text')
        })
        Text(label)
          .fontSize(13)
          .fontColor(this.flashAction === action
            ? $r('app.color.app_accent_text')
            : $r('app.color.app_primary_text'))
      }
      .alignItems(VerticalAlign.Center)
    }
    .layoutWeight(1)
    .height(44)
    .padding({ left: 0, right: 0 })
    .borderRadius(4)
    .backgroundColor(Color.Transparent)
    .border({
      width: 1,
      color: this.flashAction === action
        ? $r('app.color.app_accent')
        : $r('app.color.app_rule_strong')
    })
    .onClick(() => {
      if (this.onAction !== undefined) {
        this.onAction(action);
      }
    })
  }

  build() {
    Column() {
      // ---------- 卡片头 ----------
      Row() {
        Text('寻车')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_primary_text'))

        Blank()

        Text('需物理在场')
          .fontSize(10)
          .fontColor($r('app.color.app_tertiary_text'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 13 })

      // ---------- 鸣笛 / 闪灯 ----------
      Row({ space: 8 }) {
        this.actionButton('鸣笛', AppIconName.HORN, 'honk')
        this.actionButton('闪灯', AppIconName.FLASH, 'flash')
      }
      .width('100%')

      // ---------- 鸣笛并闪灯 ----------
      Row({ space: 8 }) {
        this.actionButton('鸣笛并闪灯', AppIconName.HORN, 'honk-flash')
      }
      .width('100%')
      .margin({ top: 8 })
    }
    .width('100%')
    .padding({ top: 15, left: 16, right: 16, bottom: 16 })
    .border({ width: 1, color: $r('app.color.app_rule') })
    .borderRadius(8)
  }
}
