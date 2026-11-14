/**
 * 车模标记点的位置与文案。
 *
 * ArkTS 不允许用对象字面量做类型，必须显式声明类。
 */
class PlanMarker {
  /** 圆心 X 坐标（相对 200 宽视口，vp 等效单位）。 */
  x: number = 0;
  /** 圆心 Y 坐标（相对 340 高视口，vp 等效单位）。 */
  y: number = 0;
  /** 标记文字。 */
  text: string = '';
  /** 是否处于警示态（开启 / 解锁）。 */
  warn: boolean = false;

  constructor(x: number, y: number, text: string, warn: boolean) {
    this.x = x;
    this.y = y;
    this.text = text;
    this.warn = warn;
  }
}

/**
 * 车辆俯视示意图。
 *
 * 还原 Android 原版 MainActivity 的车辆图示（g10 控件）：
 * 车身线稿 + 位置标记点，机盖 / 充电口 / 尾门 / 四门四窗均可点击。
 *
 * 【单位说明】Path 的 commands 坐标单位是 px（物理像素），与设计稿的
 * CSS px 不同域。做法是：Path 盒子写成 px 尺寸（与路径坐标 1:1），
 * 再用 scale() 按 vp2px(1) 放大到 200×340vp —— 等效于把设计稿的
 * 200×340 视口映射为 200×340vp，路径坐标可直接沿用设计稿数值。
 */
@Component
export struct VehiclePlan {
  /** 车锁已解锁 —— 整车标记点显示警示色。 */
  @Prop unlocked: boolean = false;
  /** 机盖开启 —— 机盖标记点显示警示色。 */
  @Prop hoodOpen: boolean = false;
  /** 充电口开启 —— 充电口标记点显示警示色。 */
  @Prop portOpen: boolean = false;
  /** 尾门解锁 —— 尾门标记点显示警示色。 */
  @Prop trunkUnlocked: boolean = false;
  /** 尾门指令执行中 —— 标记点显示蓝色描边与旋转指示器。 */
  @Prop trunkBusy: boolean = false;
  /** 车窗开启 —— 四窗区域染警示色。 */
  @Prop windowOpen: boolean = false;
  /** 点击尾门（解锁 / 锁定切换）。 */
  onTrunkTap?: () => void;

  /** 车模视口宽（设计稿单位，映射为 vp）。 */
  private readonly viewW: number = 200;
  /** 车模视口高（设计稿单位，映射为 vp）。 */
  private readonly viewH: number = 340;
  /** 屏幕密度：1vp 对应多少 px。 */
  private density: number = 3;

  aboutToAppear(): void {
    this.density = this.getUIContext().vp2px(1);
  }

  /**
   * 标记点：常态中性，开启态走警示色。
   */
  @Builder
  marker(marker: PlanMarker) {
    Stack({ alignContent: Alignment.Center }) {
      Text(marker.text)
        .fontSize(9)
        .fontColor(marker.warn ? $r('app.color.app_on_accent') : $r('app.color.app_tertiary_text'))
    }
    .width(26)
    .height(26)
    .borderRadius(13)
    .backgroundColor(marker.warn ? $r('app.color.app_warn') : $r('app.color.app_surface'))
    .border({ width: 1.2, color: marker.warn
      ? $r('app.color.app_warn')
      : $r('app.color.app_card_border') })
    .position({ x: marker.x - 13, y: marker.y - 13 })
  }

  /**
   * 描边宽度：设计稿单位 → 抵消 scale 放大，保持视觉粗细与设计稿一致。
   */
  private sw(value: number): number {
    return value / this.density;
  }

  /**
   * 车模放大系数：px 域视口 → vp 尺寸。
   */
  private planScale(): ScaleOptions {
    return { x: this.density, y: this.density, centerX: 0, centerY: 0 };
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ---------- 车身线稿（Path 盒子为 px 尺寸，与路径坐标 1:1） ----------
      Stack({ alignContent: Alignment.TopStart }) {
        Path({ commands: 'M22,76 L39,76 L39,122 L22,122 Z M161,76 L178,76 L178,122 L161,122 Z' })
          .fill($r('app.color.app_surface_sunken'))
          .stroke($r('app.color.app_card_border'))
          .strokeWidth(this.sw(1))
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)
        Path({ commands: 'M22,226 L39,226 L39,272 L22,272 Z M161,226 L178,226 L178,272 L161,272 Z' })
          .fill($r('app.color.app_surface_sunken'))
          .stroke($r('app.color.app_card_border'))
          .strokeWidth(this.sw(1))
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)

        Path({
          commands: 'M100 6c33 0 53 19 57 46l4 46v152c0 44-19 78-61 78S39 298 39 254V98l4-46c4-27 24-46 57-46z'
        })
          .fill(Color.Transparent)
          .stroke($r('app.color.app_primary_text'))
          .strokeWidth(this.sw(1.6))
          .strokeLineJoin(LineJoinStyle.Round)
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)

        // 风挡与尾窗
        Path({ commands: 'M64 58c7-13 65-13 72 0l3 26H61z' })
          .fill($r('app.color.app_surface_muted'))
          .stroke($r('app.color.app_primary_text'))
          .strokeWidth(this.sw(1.1))
          .strokeLineJoin(LineJoinStyle.Round)
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)
        Path({ commands: 'M62 234h76l-4 20H66z' })
          .fill($r('app.color.app_surface_muted'))
          .stroke($r('app.color.app_primary_text'))
          .strokeWidth(this.sw(1.1))
          .strokeLineJoin(LineJoinStyle.Round)
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)

        // 四窗：开启时染警示色。框线与车身外框同粗
        Path({ commands: 'M45,96 L98,96 L98,158 L45,158 Z' })
          .fill(this.windowOpen ? $r('app.color.app_warn_soft') : Color.Transparent)
          .stroke($r('app.color.app_primary_text'))
          .strokeWidth(this.sw(1.6))
          .strokeLineJoin(LineJoinStyle.Round)
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)
        Path({ commands: 'M102,96 L155,96 L155,158 L102,158 Z' })
          .fill(this.windowOpen ? $r('app.color.app_warn_soft') : Color.Transparent)
          .stroke($r('app.color.app_primary_text'))
          .strokeWidth(this.sw(1.6))
          .strokeLineJoin(LineJoinStyle.Round)
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)
        Path({ commands: 'M45,162 L98,162 L98,224 L45,224 Z' })
          .fill(this.windowOpen ? $r('app.color.app_warn_soft') : Color.Transparent)
          .stroke($r('app.color.app_primary_text'))
          .strokeWidth(this.sw(1.6))
          .strokeLineJoin(LineJoinStyle.Round)
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)
        Path({ commands: 'M102,162 L155,162 L155,224 L102,224 Z' })
          .fill(this.windowOpen ? $r('app.color.app_warn_soft') : Color.Transparent)
          .stroke($r('app.color.app_primary_text'))
          .strokeWidth(this.sw(1.6))
          .strokeLineJoin(LineJoinStyle.Round)
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)

        // 内部分隔线
        Path({ commands: 'M45 54h110M61 84h78M39 98h122M61 234h78M39 254h122' })
          .fill(Color.Transparent)
          .stroke($r('app.color.app_card_border'))
          .strokeWidth(this.sw(1))
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)
        Path({ commands: 'M100 84v150M61 84v150M139 84v150' })
          .fill(Color.Transparent)
          .stroke($r('app.color.app_card_border'))
          .strokeWidth(this.sw(1))
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)

        // 灯组
        Path({ commands: 'M52 34l14-4 3 10-15 4z' })
          .fill($r('app.color.app_primary_text'))
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)
        Path({ commands: 'M148 34l-14-4-3 10 15 4z' })
          .fill($r('app.color.app_primary_text'))
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)
        Path({ commands: 'M48 300l19-4-2 10-19 4z' })
          .fill($r('app.color.app_primary_text'))
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)
        Path({ commands: 'M152 300l-19-4 2 10 19 4z' })
          .fill($r('app.color.app_primary_text'))
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)
      }
      .width(`${this.viewW}px`)
      .height(`${this.viewH}px`)
      .scale(this.planScale())

      // ---------- 位置标记点（vp 坐标，与缩放后的车模对齐） ----------
      this.marker(new PlanMarker(100, 22, '盖', this.hoodOpen))
      this.marker(new PlanMarker(52, 238, '口', this.portOpen))
      this.marker(new PlanMarker(61, 108, '前左', this.unlocked))
      this.marker(new PlanMarker(139, 108, '前右', this.unlocked))
      this.marker(new PlanMarker(61, 186, '后左', this.unlocked))
      this.marker(new PlanMarker(139, 186, '后右', this.unlocked))

      // 尾门标记点：可点击，解锁后走警示色，执行中显示蓝色描边与转圈
      Stack({ alignContent: Alignment.Center }) {
        if (this.trunkBusy) {
          LoadingProgress()
            .width(13)
            .height(13)
            .color($r('app.color.app_accent'))
        } else {
          Text('尾')
            .fontSize(9)
            .fontColor(this.trunkUnlocked
              ? $r('app.color.app_on_accent')
              : $r('app.color.app_tertiary_text'))
        }
      }
      .width(26)
      .height(26)
      .borderRadius(13)
      .backgroundColor(this.trunkUnlocked ? $r('app.color.app_warn') : $r('app.color.app_surface'))
      .border({ width: 1.2, color: this.trunkBusy
        ? $r('app.color.app_accent')
        : (this.trunkUnlocked ? $r('app.color.app_warn') : $r('app.color.app_card_border')) })
      .position({ x: 87, y: 249 })
      .onClick(() => {
        if (this.trunkBusy) {
          return;
        }
        if (this.onTrunkTap !== undefined) {
          this.onTrunkTap();
        }
      })

      // 说明文字
      Text('机盖').fontSize(9).fontColor($r('app.color.app_tertiary_text'))
        .position({ x: 118, y: 14 })
      Text('充电口').fontSize(9).fontColor($r('app.color.app_tertiary_text'))
        .position({ x: 2, y: 206 })
    }
    .width(this.viewW)
    .height(this.viewH)
  }
}
