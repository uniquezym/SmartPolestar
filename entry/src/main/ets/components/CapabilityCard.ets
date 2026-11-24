/**
 * 一条能力项。
 */
export interface CapabilityItem {
  /** 能力名。 */
  title: string;
  /** 服务端字段名，用作 ForEach 的 key。 */
  key: string;
  /** 说明文字。 */
  desc: string;
  /** 是否支持；null 表示服务端未下发这一项。 */
  supported: boolean | null;
  /**
   * 值文案。
   *
   * 三类来源共用这一个字段：
   *   数值型限制 —— 如「30 分钟」
   *   枚举型档位 —— 如「2 档」
   *   文本型字段 —— 如软件版本号
   * 空串表示这一项没有值，只有「支持 / 不支持」的开关语义。
   */
  value: string;
}

/**
 * 能力项的状态等级。
 *
 * 放在组件外 —— ArkUI 的 @Component 结构体里不允许再声明枚举。
 */
enum CapabilityLevel {
  /** 支持。 */
  OK,
  /** 不支持。 */
  OFF,
  /** 服务端未下发这一项。 */
  UNKNOWN
}

/**
 * 车辆能力卡片。
 *
 * 展示 car-information 接口返回的能力开关，按业务分组排列。
 *
 * 这一张卡目前是**纯展示**的 —— 探测结果只用于让人看清这台车支持什么，
 * 还没接到各功能的可用性判断上（那是后续的事）。
 */
@Component
export struct CapabilityCard {
  /** 分组标题。 */
  @Prop groupTitle: string = '';
  /** 该组的能力项。 */
  @Prop items: CapabilityItem[] = [];
  /** 该组已开启的能力数（用于分组标题右侧的摘要）。 */
  @Prop enabledCount: number = 0;

  /**
   * 能力项的等级。
   */
  private levelOf(item: CapabilityItem): CapabilityLevel {
    if (item.supported === null) {
      return CapabilityLevel.UNKNOWN;
    }
    return item.supported ? CapabilityLevel.OK : CapabilityLevel.OFF;
  }

  /**
   * 能力项的状态文案。
   *
   * 数值型限制项不显示「支持 / 不支持」——
   * 它的语义就是那个数字本身，单独一行展示更清楚。
   */
  private statusText(item: CapabilityItem): string {
    if (item.value.length > 0) {
      return item.value;
    }
    const level = this.levelOf(item);
    if (level === CapabilityLevel.OK) {
      return '支持';
    }
    if (level === CapabilityLevel.OFF) {
      return '不支持';
    }
    return '未下发';
  }

  /**
   * 等级对应的文字颜色。
   */
  private statusColor(item: CapabilityItem): ResourceColor {
    if (item.value.length > 0) {
      return $r('app.color.app_accent_text');
    }
    const level = this.levelOf(item);
    if (level === CapabilityLevel.OK) {
      return $r('app.color.app_ok');
    }
    if (level === CapabilityLevel.OFF) {
      return $r('app.color.app_tertiary_text');
    }
    return $r('app.color.app_warn');
  }

  /**
   * 等级对应的标签底色。
   */
  private statusBg(item: CapabilityItem): ResourceColor {
    if (item.value.length > 0) {
      return $r('app.color.app_accent_soft_bg');
    }
    const level = this.levelOf(item);
    if (level === CapabilityLevel.OK) {
      return $r('app.color.app_ok_soft');
    }
    if (level === CapabilityLevel.OFF) {
      return $r('app.color.app_surface_muted');
    }
    return $r('app.color.app_warn_soft');
  }

  /**
   * 一行能力项。
   *
   * 只传结构性参数（序号、是否末行），状态值一律在 Builder 内部现取 ——
   * Builder 的参数按值传递，状态值当参数传进来，界面不会跟着刷新。
   */
  @Builder
  capabilityLine(item: CapabilityItem, last: boolean) {
    Row() {
      Column({ space: 2 }) {
        Text(item.title)
          .fontSize(13.5)
          .fontColor($r('app.color.app_primary_text'))
        if (item.desc.length > 0) {
          Text(item.desc)
            .fontSize(10.5)
            .fontColor($r('app.color.app_tertiary_text'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.statusText(item))
        .fontSize(11.5)
        .fontColor(this.statusColor(item))
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor(this.statusBg(item))
        .borderRadius(4)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 9, bottom: 9 })
    .border({ width: { bottom: last ? 0 : 1 }, color: $r('app.color.app_rule') })
  }

  build() {
    Column() {
      // ---------- 分组标题 ----------
      Row() {
        Text(this.groupTitle)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_secondary_text'))

        Blank()

        Text(this.enabledCount > 0 ? `${this.enabledCount} 项可用` : '无可用项')
          .fontSize(10)
          .fontColor($r('app.color.app_tertiary_text'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ bottom: 4 })

      ForEach(this.items, (item: CapabilityItem) => {
        this.capabilityLine(item, false)
      }, (item: CapabilityItem) => item.key)
    }
    .width('100%')
    .padding({ top: 12, left: 16, right: 16, bottom: 12 })
    .border({ width: 1, color: $r('app.color.app_rule') })
    .borderRadius(8)
  }
}
