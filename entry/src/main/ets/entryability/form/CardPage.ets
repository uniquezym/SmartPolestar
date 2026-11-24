import { AppIcon, AppIconName } from '../../components/Icons';
import { CARD_OP_TTL_MS } from '../../core/vehicle/CardConstants';

/**
 * 桌面卡片页面（4×2）。
 *
 * 布局严格对齐 UX 设计稿（design/polestar-volvo-ux/index.html 的「桌面卡片 4×2」章节）：
 *   328 × 168 vp，圆角 18，内边距 12 / 14
 *   顶栏   车型名 15px/500 + 更新时间 9.5px 等宽
 *   指标区 电量 / 预计续航，标签 9.5px 等宽 .16em，数值 30px 等宽 -.05em
 *   充电行 固定 16px 槽位，未充电时隐藏但保留占位
 *   控制区 整车锁 / 驻车空调，40px 高，12.5px 字号
 *
 * 【数据接收】用 @LocalStorageProp 接收 updateForm 推送的数据。
 * 装饰器的入参 key 必须与 CardBinding 的字段名完全一致，否则推送不生效。
 * 这里是**字面量**而不是 CardKeys.MODEL_NAME —— 装饰器参数需编译期常量，
 * 写成静态字段虽然运行期等价，但编译期校验会告警。
 *
 * 【控制交互】点击按钮用 postCardAction 的 **message** 事件把控制项交给
 * 卡片提供方进程（FormExtensionAbility.onFormEvent）直接执行 ——
 * **不跳转任何界面**，用户点完就停在桌面。
 *
 * 为什么不用 router 事件拉起主应用：那样会跳到确认页，
 * 与「点一下直接执行」的预期不符。
 * 为什么不在卡片里自己做车控：卡片页面只有渲染能力，
 * 真正的网络链路要放在提供方进程里（见 CardControlTask）。
 */

/**
 * 卡片的 LocalStorage 实例。
 *
 * 卡片页面通过 @Entry(storage) 接收 FormExtensionAbility 推送的数据。
 */
const cardStorage: LocalStorage = new LocalStorage();

@Entry(cardStorage)
@Component
struct CardPage {
  /** 车型名。 */
  @LocalStorageProp('cardModelName') modelName: string = '极星2';
  /** 电量百分比。 */
  @LocalStorageProp('cardBattery') battery: number = -1;
  /** 预计续航（公里）。 */
  @LocalStorageProp('cardRange') range: number = -1;
  /** 充电信息行文案。 */
  @LocalStorageProp('cardChargeText') chargeText: string = '';
  /** 充电信息行是否显示。 */
  @LocalStorageProp('cardChargeVisible') chargeVisible: boolean = false;
  /** 车锁状态文案。 */
  @LocalStorageProp('cardLockText') lockText: string = '—';
  /** 驻车空调状态文案。 */
  @LocalStorageProp('cardClimateText') climateText: string = '—';
  /** 操作结果文案。 */
  @LocalStorageProp('cardOpText') opText: string = '';
  /** 操作结果是否显示。 */
  @LocalStorageProp('cardOpVisible') opVisible: boolean = false;
  /** 操作结果产生时刻（epoch millis）。 */
  @LocalStorageProp('cardOpAt') opAt: number = 0;
  /** 快照时刻（epoch millis）。 */
  @LocalStorageProp('cardUpdatedAt') updatedAt: number = 0;

  /**
   * 操作结果当前是否应当显示。
   *
   * 结果只在卡片上停留几秒，之后自己隐去。
   * 卡片页面不会因为「时间到了」被重新推送，
   * 所以这里按时刻算 —— 下一次重绘时自然就不显示了。
   */
  private opShowing(): boolean {
    if (!this.opVisible || this.opAt <= 0) {
      return false;
    }
    return (Date.now() - this.opAt) < CARD_OP_TTL_MS;
  }

  /**
   * 「距上次更新」的相对时间文案。
   */
  private relativeTime(): string {
    if (this.updatedAt <= 0) {
      return '等待同步';
    }
    const delta = Date.now() - this.updatedAt;
    if (delta < 60000) {
      return '刚刚更新';
    }
    if (delta < 3600000) {
      return `${Math.max(1, Math.floor(delta / 60000))} 分钟前`;
    }
    if (delta < 86400000) {
      return `${Math.max(1, Math.floor(delta / 3600000))} 小时前`;
    }
    return `${Math.max(1, Math.floor(delta / 86400000))} 天前`;
  }

  /**
   * 电量数值文案。未知时显示占位符。
   */
  private batteryText(): string {
    return this.battery < 0 ? '—' : `${Math.round(this.battery)}`;
  }

  /**
   * 续航数值文案。未知时显示占位符。
   */
  private rangeText(): string {
    return this.range < 0 ? '—' : `${Math.round(this.range)}`;
  }

  /**
   * 车锁按钮的图标。已锁显示闭锁，未锁显示开锁。
   */
  private lockIcon(): AppIconName {
    return this.lockText === '未锁' ? AppIconName.LOCK_OPEN : AppIconName.LOCK_CLOSED;
  }

  /**
   * 把控制项交给卡片提供方进程直接执行。
   *
   * 用 message 事件而不是 router 事件 —— router 会拉起主应用界面，
   * message 只在提供方进程内投递，不打断用户。
   *
   * @param control 控制项：lock / climate
   */
  private sendControl(control: string): void {
    postCardAction(this, {
      action: 'message',
      params: {
        value: control
      }
    });
  }

  /**
   * 消费掉点击卡片空白区域的事件。
   *
   * 卡片根节点不绑 onClick 时，点击卡片主体会触发系统默认行为 ——
   * 直接把应用拉到前台。这与「点一下直接执行、不打断用户」的预期冲突。
   *
   * 这里在根节点绑一个空的 onClick 把事件吃掉：卡片就变成一块纯展示的桌面，
   * 只有底部的两个控制按钮有反应。
   */
  private consumeTap(): void {
  }

  /**
   * 控制按钮。
   *
   * 显示的是**当前状态**而非将要执行的动作，与主应用右侧圆钮同一套语言。
   */
  @Builder
  controlButton(icon: AppIconName, label: string, control: string) {
    Row({ space: 6 }) {
      AppIcon({ name: icon, iconSize: 15, color: $r('app.color.app_primary_text') })
        .width(15)
        .height(15)
      Text(label)
        .fontSize(12.5)
        .fontColor($r('app.color.app_primary_text'))
        .maxLines(1)
    }
    .height(40)
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .borderRadius(4)
    .border({ width: 1, color: $r('app.color.app_card_border') })
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      this.sendControl(control);
    })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // ---------- 顶栏：车型 + 更新时间 ----------
        Row() {
          Text(this.modelName)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_primary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Text(this.relativeTime())
            .fontSize(9.5)
            .fontFamily('HarmonyOS Sans Mono')
            .fontColor($r('app.color.app_tertiary_text'))
        }
        .width('100%')
        .height(20)
        .alignItems(VerticalAlign.Bottom)

        // ---------- 电量 / 预计续航 ----------
        Row() {
          Column() {
            Text('电量')
              .fontSize(9.5)
              .fontFamily('HarmonyOS Sans Mono')
              .fontColor($r('app.color.app_tertiary_text'))
              .letterSpacing(1.5)
            Row({ space: 3 }) {
              Text(this.batteryText())
                .fontSize(30)
                .fontFamily('HarmonyOS Sans Mono')
                .fontColor($r('app.color.app_primary_text'))
              Text('%')
                .fontSize(12)
                .fontColor($r('app.color.app_tertiary_text'))
            }
            .margin({ top: 5 })
            .alignItems(VerticalAlign.Bottom)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Column() {
            Text('预计续航')
              .fontSize(9.5)
              .fontFamily('HarmonyOS Sans Mono')
              .fontColor($r('app.color.app_tertiary_text'))
              .letterSpacing(1.5)
            Row({ space: 3 }) {
              Text(this.rangeText())
                .fontSize(30)
                .fontFamily('HarmonyOS Sans Mono')
                .fontColor($r('app.color.app_primary_text'))
              Text('km')
                .fontSize(12)
                .fontColor($r('app.color.app_tertiary_text'))
            }
            .margin({ top: 5 })
            .alignItems(VerticalAlign.Bottom)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .padding({ left: 14 })
          .border({ width: { left: 1 }, color: $r('app.color.app_rule') })
        }
        .width('100%')
        .margin({ top: 6 })

        // ---------- 充电信息行：固定 16vp 槽位 ----------
        // 未充电时隐藏但保留占位，保证下方控制按钮不随充电状态上下跳动。
        Row({ space: 6 }) {
          AppIcon({ name: AppIconName.CHARGE, iconSize: 11, color: $r('app.color.app_accent') })
            .width(11)
            .height(11)
          Text(this.chargeText)
            .fontSize(10)
            .fontFamily('HarmonyOS Sans Mono')
            .fontColor($r('app.color.app_accent'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
        }
        .width('100%')
        .height(16)
        .margin({ top: 5 })
        .alignItems(VerticalAlign.Center)
        .visibility(this.chargeVisible ? Visibility.Visible : Visibility.Hidden)

        // 把控制按钮压到卡片底部
        Blank()

        // ---------- 控制按钮 ----------
        Row({ space: 8 }) {
          this.controlButton(this.lockIcon(), this.lockText, 'lock')
          this.controlButton(AppIconName.CLIMATE_COOL, this.climateText, 'climate')
        }
        .width('100%')
      }
      .width('100%')
      .height('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 12 })

      // ---------- 操作结果浮层 ----------
      // 卡片进程弹不了 Toast，操作结果只能显示在这里。
      // 盖在充电信息行的位置 —— 两者不会同时出现（操作发生时充电行信息意义不大）。
      if (this.opShowing()) {
        Text(this.opText)
          .fontSize(10)
          .fontFamily('HarmonyOS Sans Mono')
          .fontColor($r('app.color.app_accent'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .height(16)
          .textAlign(TextAlign.Center)
          .padding({ left: 14, right: 14 })
          .backgroundColor($r('app.color.app_background'))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
    // 卡片根节点绑 onClick，把点击卡片主体的事件吃掉。
    // 不绑的话系统默认行为是把应用拉到前台 —— 那正是要避免的。
    .onClick(() => {
      this.consumeTap();
    })
  }
}
