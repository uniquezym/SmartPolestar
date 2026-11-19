/**
 * 健康项目的等级。
 *
 * 放在组件外 —— ArkUI 的 @Component 结构体里不允许再声明枚举。
 */
enum HealthLevel {
  /** 正常。 */
  OK,
  /** 需要关注。 */
  WARN,
  /** 异常。 */
  ERROR,
  /** 车端未上报这一项。 */
  UNKNOWN
}

/**
 * 液位与电气项的标识。
 *
 * 用它代替把状态值当参数传给 @Builder —— ArkUI 的 Builder 参数按值传递，
 * 状态变化后不会重新求值，界面会停在旧值上。
 */
enum FluidKind {
  /** 制动液。 */
  BRAKE,
  /** 冷却液。 */
  COOLANT,
  /** 玻璃水。 */
  WASHER,
  /** 12V 蓄电池。 */
  BATTERY
}

/**
 * 健康与保养卡片。
 *
 * 四个分区，按安全性排序：
 *   1. 保养        —— 剩余天数 / 剩余里程，用户最常看
 *   2. 轮胎        —— 四个轮位用 2×2 网格，位置关系一目了然
 *   3. 液位与电气  —— 制动液 / 冷却液 / 玻璃水 / 12V 电池，同构的四行
 *   4. 外部灯光    —— 灯组多，只在有故障时列出明细
 *
 * 胎压只显示状态不显示数值 —— 车端是被动式监测，
 * 拿到的 kPa 可能是标称值或残值，展示出来会误导用户。
 */
@Component
export struct HealthCard {
  /** 整体总评：良好 / 需关注 / 未知。 */
  @Prop healthStatus: string = '未知';
  /** 距离下次保养的剩余天数，-1 表示未知。 */
  @Prop serviceRemainingDays: number = -1;
  /** 距离下次保养的剩余里程（km），-1 表示未知。 */
  @Prop serviceRemainingKm: number = -1;
  /** 保养状态文案。 */
  @Prop maintenanceStatus: string = '未知';
  /** 保养状态枚举值，供 UI 判颜色。 */
  @Prop maintenanceCode: number = 0;

  /** 制动液告警枚举值。1=无告警 2=偏低 3=严重偏低，-1=车端未上报。 */
  @Prop brakeFluidWarning: number = -1;
  /** 冷却液告警枚举值。1=无告警 2=偏低，-1=车端未上报。 */
  @Prop coolantWarning: number = -1;
  /** 玻璃水告警枚举值。1=无告警 2=偏低，-1=车端未上报。 */
  @Prop washerFluidWarning: number = -1;
  /** 12V 蓄电池告警枚举值。1=无告警 2=偏低，-1=车端未上报。 */
  @Prop lowVoltageBatteryWarning: number = -1;

  /**
   * 四轮胎压告警枚举值，顺序：左前 / 右前 / 左后 / 右后。
   *
   * 1=无告警 2=很低 3=低 4=偏高，-1=车端未上报。
   * 注意这四个字段是 optional 的 —— 有些车不装胎压监测，
   * 服务端就不会下发，值是 undefined。
   */
  @Prop tyreWarnings: number[] = [];

  /** 外部灯光故障灯组数，0 表示无故障。 */
  @Prop lightFaultCount: number = 0;
  /** 故障灯组名列表，仅在有故障时非空。 */
  @Prop lightFaultNames: string[] = [];

  /**
   * 液位项的枚举值。
   */
  private fluidValue(kind: FluidKind): number {
    if (kind === FluidKind.BRAKE) {
      return this.brakeFluidWarning;
    }
    if (kind === FluidKind.COOLANT) {
      return this.coolantWarning;
    }
    if (kind === FluidKind.WASHER) {
      return this.washerFluidWarning;
    }
    return this.lowVoltageBatteryWarning;
  }

  /**
   * 液位项的等级。
   *
   * 1=无告警 2=偏低 3=严重偏低。
   * 0（未指定）与 -1（车端没这个字段）都算「未上报」。
   */
  private fluidLevel(kind: FluidKind): HealthLevel {
    const value = this.fluidValue(kind);
    if (value === 1) {
      return HealthLevel.OK;
    }
    if (value === 2) {
      return HealthLevel.WARN;
    }
    if (value >= 3) {
      return HealthLevel.ERROR;
    }
    return HealthLevel.UNKNOWN;
  }

  /**
   * 液位项的文案。
   */
  private fluidText(kind: FluidKind): string {
    const value = this.fluidValue(kind);
    const isBattery = kind === FluidKind.BATTERY;
    if (value === 1) {
      return '正常';
    }
    if (value === 2) {
      return isBattery ? '电压偏低' : '偏低';
    }
    if (value >= 3) {
      return isBattery ? '电压偏低' : '严重偏低';
    }
    return '未上报';
  }

  /**
   * 某轮位的胎压枚举值。
   */
  private tyreValue(index: number): number {
    if (index < 0 || index >= this.tyreWarnings.length) {
      return -1;
    }
    return this.tyreWarnings[index];
  }

  /**
   * 胎压的等级。
   *
   * 1=无告警 2=很低 3=低 4=偏高。
   * 「很低」比「低」更危险，判为异常；「偏高」也必须报出来。
   */
  private tyreLevel(index: number): HealthLevel {
    const value = this.tyreValue(index);
    if (value === 1) {
      return HealthLevel.OK;
    }
    if (value === 2) {
      return HealthLevel.ERROR;
    }
    if (value === 3 || value === 4) {
      return HealthLevel.WARN;
    }
    return HealthLevel.UNKNOWN;
  }

  /**
   * 胎压的文案。
   *
   * 按枚举值区分「偏低」与「偏高」—— 两者都是 WARN 级但含义相反，
   * 混成一句话会让人搞不清该往哪边调胎压。
   */
  private tyreText(index: number): string {
    const value = this.tyreValue(index);
    if (value === 1) {
      return '正常';
    }
    if (value === 2) {
      return '很低';
    }
    if (value === 3) {
      return '偏低';
    }
    if (value === 4) {
      return '偏高';
    }
    return '未上报';
  }

  /**
   * 保养状态的等级。
   *
   * 1=正常 2=未知警告 3~5=将近 6~8=到期 9~11=逾期。
   */
  private maintenanceLevel(): HealthLevel {
    const value = this.maintenanceCode;
    if (value === 1) {
      return HealthLevel.OK;
    }
    if (value === 2 || (value >= 3 && value <= 5)) {
      return HealthLevel.WARN;
    }
    if (value >= 6) {
      return HealthLevel.ERROR;
    }
    return HealthLevel.UNKNOWN;
  }

  /**
   * 等级对应的文字颜色。
   */
  private levelColor(level: HealthLevel): ResourceColor {
    if (level === HealthLevel.OK) {
      return $r('app.color.app_ok');
    }
    if (level === HealthLevel.WARN) {
      return $r('app.color.app_warn');
    }
    if (level === HealthLevel.ERROR) {
      return $r('app.color.app_error');
    }
    return $r('app.color.app_tertiary_text');
  }

  /**
   * 等级对应的标签底色。
   */
  private levelBg(level: HealthLevel): ResourceColor {
    if (level === HealthLevel.OK) {
      return $r('app.color.app_ok_soft');
    }
    if (level === HealthLevel.WARN) {
      return $r('app.color.app_warn_soft');
    }
    if (level === HealthLevel.ERROR) {
      return $r('app.color.app_error_soft');
    }
    return $r('app.color.app_surface_muted');
  }

  /**
   * 整体总评的等级。
   */
  private overallLevel(): HealthLevel {
    if (this.healthStatus === '良好') {
      return HealthLevel.OK;
    }
    if (this.healthStatus === '需关注') {
      return HealthLevel.WARN;
    }
    return HealthLevel.UNKNOWN;
  }

  /**
   * 轮位名。
   */
  private tyreName(index: number): string {
    const names: string[] = ['左前', '右前', '左后', '右后'];
    return index < names.length ? names[index] : '';
  }

  /**
   * 剩余天数的展示文本。
   */
  private daysText(): string {
    if (this.serviceRemainingDays < 0) {
      return '—';
    }
    return `${this.serviceRemainingDays}`;
  }

  /**
   * 剩余里程的展示文本。
   */
  private kmText(): string {
    if (this.serviceRemainingKm < 0) {
      return '—';
    }
    return `${this.serviceRemainingKm}`;
  }

  /**
   * 分区标题。
   *
   * 标题上方带一条分隔线 —— 四个分区之间要有明确的视觉分界，
   * 否则「保养 / 轮胎 / 液位与电气 / 外部灯光」读起来像一整块。
   */
  @Builder
  sectionTitle(title: string, first: boolean) {
    Column() {
      if (!first) {
        Divider()
          .color($r('app.color.app_rule'))
          .strokeWidth(1)
          .width('100%')
          // 与上一段拉开距离 —— 贴着上一行会显得挤。
          .margin({ top: 10 })
      }
      Text(title)
        .fontSize(11)
        .fontColor($r('app.color.app_tertiary_text'))
        .width('100%')
        .padding({ top: 10, bottom: 8 })
    }
    .width('100%')
  }

  /**
   * 「标签 + 右侧状态」的清单行。
   *
   * 只传结构性参数（标签、哪一项、是否末行）——
   * 状态值一律在 Builder 内部现取。Builder 的参数按值传递，
   * 把状态值当参数传进来，状态变化后界面不会刷新。
   */
  @Builder
  statusLine(label: string, kind: FluidKind, last: boolean) {
    Row() {
      Text(label)
        .fontSize(13.5)
        .fontColor($r('app.color.app_primary_text'))

      Blank()

      Text(this.fluidText(kind))
        .fontSize(11.5)
        .fontColor(this.levelColor(this.fluidLevel(kind)))
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor(this.levelBg(this.fluidLevel(kind)))
        .borderRadius(4)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 10, bottom: 10 })
    .border({ width: { bottom: last ? 0 : 1 }, color: $r('app.color.app_rule') })
  }

  /**
   * 单个轮位的胎压格。
   *
   * 只显示轮位名与状态 —— 车端被动式监测，不展示 kPa 数值。
   *
   * 宽度用 layoutWeight 而不是 width('100%') ——
   * 在 Row 里写死 100% 会让两个格子各占满整行，第二列被挤出卡片。
   */
  @Builder
  tyreCell(index: number) {
    Row() {
      Text(this.tyreName(index))
        .fontSize(12)
        .fontColor($r('app.color.app_secondary_text'))

      Blank()

      Text(this.tyreText(index))
        .fontSize(11.5)
        .fontColor(this.levelColor(this.tyreLevel(index)))
    }
    .layoutWeight(1)
    .alignItems(VerticalAlign.Center)
    .padding({ top: 10, bottom: 10, left: 10, right: 10 })
    .backgroundColor($r('app.color.app_surface_sunken'))
    .borderRadius(6)
  }

  build() {
    Column() {
      // ---------- 卡片头 ----------
      Row() {
        Text('健康与保养')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_primary_text'))

        Blank()

        Text(this.healthStatus)
          .fontSize(10)
          .fontColor(this.levelColor(this.overallLevel()))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(this.levelBg(this.overallLevel()))
          .borderRadius(4)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // ---------- 保养 ----------
      this.sectionTitle('保养', true)

      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text(this.daysText())
            .fontSize(22)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_primary_text'))
          Text('天后保养')
            .fontSize(11)
            .fontColor($r('app.color.app_tertiary_text'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Column({ space: 4 }) {
          Text(this.kmText())
            .fontSize(22)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.app_primary_text'))
          Text('km 后保养')
            .fontSize(11)
            .fontColor($r('app.color.app_tertiary_text'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)

      Row() {
        Text('保养状态')
          .fontSize(13.5)
          .fontColor($r('app.color.app_primary_text'))

        Blank()

        Text(this.maintenanceStatus)
          .fontSize(11.5)
          .fontColor(this.levelColor(this.maintenanceLevel()))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(this.levelBg(this.maintenanceLevel()))
          .borderRadius(4)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      // 底部留白加大 —— 「正常」标签紧贴下方的分隔线会显得挤。
      .padding({ top: 12, bottom: 12 })

      // ---------- 轮胎 ----------
      this.sectionTitle('轮胎', false)

      Row({ space: 10 }) {
        this.tyreCell(0)
        this.tyreCell(1)
      }
      .width('100%')

      Row({ space: 10 }) {
        this.tyreCell(2)
        this.tyreCell(3)
      }
      .width('100%')
      .margin({ top: 10 })

      // ---------- 液位与电气 ----------
      this.sectionTitle('液位与电气', false)

      this.statusLine('制动液', FluidKind.BRAKE, false)
      this.statusLine('冷却液', FluidKind.COOLANT, false)
      this.statusLine('玻璃水', FluidKind.WASHER, false)
      this.statusLine('12V 蓄电池', FluidKind.BATTERY, true)

      // ---------- 外部灯光 ----------
      this.sectionTitle('外部灯光', false)

      Row() {
        Text('灯组状态')
          .fontSize(13.5)
          .fontColor($r('app.color.app_primary_text'))

        Blank()

        Text(this.lightFaultCount > 0 ? `${this.lightFaultCount} 个灯组故障` : '正常')
          .fontSize(11.5)
          .fontColor(this.lightFaultCount > 0
            ? $r('app.color.app_error')
            : $r('app.color.app_ok'))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .backgroundColor(this.lightFaultCount > 0
            ? $r('app.color.app_error_soft')
            : $r('app.color.app_ok_soft'))
          .borderRadius(4)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ top: 10, bottom: 10 })

      // 灯组明细：只在有故障时列出。
      if (this.lightFaultCount > 0) {
        ForEach(this.lightFaultNames, (name: string) => {
          Row() {
            Circle()
              .width(4)
              .height(4)
              .fill($r('app.color.app_error'))
            Text(name)
              .fontSize(12)
              .fontColor($r('app.color.app_secondary_text'))
              .margin({ left: 8 })
          }
          .width('100%')
          .padding({ top: 5, bottom: 5 })
        }, (name: string) => name)
      }
    }
    .width('100%')
    .padding({ top: 15, left: 16, right: 16, bottom: 16 })
    .border({ width: 1, color: $r('app.color.app_rule') })
    .borderRadius(8)
  }
}
