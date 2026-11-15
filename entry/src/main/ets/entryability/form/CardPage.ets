import { AppIcon, AppIconName } from '../../components/Icons';

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
 * 【控制交互】点击按钮通过 postCardAction 的 router 事件跳转到主应用的
 * 车控确认页，由主应用完成指纹验证与指令下发 —— 卡片进程不能弹指纹框，
 * 且 FormExtensionAbility 生命周期只有 10 秒，做不了「验证 → 下发 → 轮询确认」。
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
  /** 快照时刻（epoch millis）。 */
  @LocalStorageProp('cardUpdatedAt') updatedAt: number = 0;

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
   * 跳转到主应用的车控确认页。
   *
   * 指纹验证与指令下发都在主应用里完成，卡片只负责入口。
   *
   * @param control 控制项：lock / climate
   */
  private gotoControl(control: string): void {
    postCardAction(this, {
      action: 'router',
      abilityName: 'EntryAbility',
      params: {
        control: control
      }
    });
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
      this.gotoControl(control);
    })
  }

  build() {
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
    .backgroundColor($r('app.color.app_background'))
  }
}
