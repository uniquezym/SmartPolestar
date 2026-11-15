import { AppIcon, AppIconName } from './Icons';

/** 瞬时高亮时长（毫秒）。 */
const FLASH_HIGHLIGHT_MS: number = 1500;

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
 * 点击后给一次短暂的品牌蓝高亮，表示「指令已触发」，1.5 秒后自动退回。
 */
@Component
export struct FindCarCard {
  /** 最近一次触发的动作，用于瞬时高亮。 */
  @State private flashedAction: string = '';
  /** 高亮定时器句柄。 */
  private flashTimer: number = -1;

  /**
   * 点击按钮。
   *
   * @param action 动作标识（honk / flash / honk-flash）
   */
  onAction?: (action: string) => void;

  aboutToDisappear(): void {
    this.clearFlash();
  }

  /**
   * 触发瞬时高亮。
   *
   * 寻车没有「关闭」命令（协议里只有 HonkFlash 一个 RPC，
   * 枚举只有鸣笛 / 闪灯 / 鸣笛并闪灯），所以按钮不能做成开关。
   * 这里用一次短暂高亮来表达「指令已触发」。
   *
   * @param action 动作标识
   */
  private flash(action: string): void {
    this.flashedAction = action;
    this.clearFlash();
    this.flashTimer = setTimeout(() => {
      this.flashedAction = '';
      this.flashTimer = -1;
    }, FLASH_HIGHLIGHT_MS);
  }

  private clearFlash(): void {
    if (this.flashTimer !== -1) {
      clearTimeout(this.flashTimer);
      this.flashTimer = -1;
    }
  }

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
          color: this.flashedAction === action
            ? $r('app.color.app_accent_text')
            : $r('app.color.app_primary_text')
        })
        Text(label)
          .fontSize(13)
          .fontColor(this.flashedAction === action
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
      color: this.flashedAction === action
        ? $r('app.color.app_accent')
        : $r('app.color.app_rule_strong')
    })
    .onClick(() => {
      this.flash(action);
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
