import { AppIcon, AppIconName } from './Icons';

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
  /** 机盖开启 —— 机盖标记点显示警示色。 */
  @Prop hoodOpen: boolean = false;
  /** 充电口开启 —— 充电口标记点显示警示色。 */
  @Prop portOpen: boolean = false;
  /**
   * 充电枪已连接 —— 充电口标记点显示插头图标，并引出一段充电线。
   *
   * 原版 Android 车模没有充电指示（g10 只画「充电口打开」橙色标签），
   * 这里沿用车模既有的标记点语言，把充电状态交给同一个标记点表达。
   */
  @Prop @Watch('onChargingChanged') charging: boolean = false;
  /**
   * 充电标记点的强调色 —— 随充电阶段变化（充电中蓝 / 已完成绿 / 故障红）。
   */
  @Prop chargeColor: ResourceColor = $r('app.color.app_accent');
  /**
   * 充电标记点是否呼吸 —— 只有真正在充电时才呼吸。
   *
   * 之前把「已连接」直接当成充电中，导致充满之后光环还在转。
   */
  @Prop chargePulsing: boolean = false;
  /** 尾门解锁 —— 尾门标记点显示警示色。 */
  @Prop trunkUnlocked: boolean = false;
  /** 尾门指令执行中 —— 标记点显示蓝色描边与旋转指示器。 */
  @Prop trunkBusy: boolean = false;
  /**
   * 四扇车窗状态，顺序：0=左前 1=右前 2=左后 3=右后。
   *
   * 值 1 或 3 视为开启，对应原版 g10.m1311b 的判定。
   */
  @Prop windowStates: number[] = [];
  /**
   * 四个车门状态，顺序：0=左前 1=右前 2=左后 3=右后。
   *
   * 值 1 或 3 视为开启，对应原版 g10.onDraw 的车门图示判定。
   */
  @Prop doorStates: number[] = [];
  /** 点击尾门（解锁 / 锁定切换）。 */
  onTrunkTap?: () => void;

  /** 车模视口宽（设计稿单位，映射为 vp）。 */
  private readonly viewW: number = 200;
  /** 车模视口高（设计稿单位，映射为 vp）。 */
  private readonly viewH: number = 340;
  /** 屏幕密度：1vp 对应多少 px。 */
  private density: number = 3;
  /** 充电呼吸动效的相位：0=收缩，1=扩散。 */
  @State chargePulse: number = 0;
  /** 充电动画的定时器句柄。 */
  private pulseTimer: number = -1;

  aboutToAppear(): void {
    this.density = this.getUIContext().vp2px(1);
    // 首次渲染若已在充电态，@Watch 不会触发，这里补一次启动。
    this.syncPulse();
  }

  aboutToDisappear(): void {
    this.stopPulse();
  }

  /**
   * 按当前是否需要呼吸来启停动画。
   */
  private syncPulse(): void {
    if (this.chargePulsing) {
      this.startPulse();
    } else {
      this.stopPulse();
      this.chargePulse = 0;
    }
  }

  /**
   * 启动充电呼吸动效。
   *
   * ArkUI 的 animation 属性只对「属性值发生变化」生效，静态值配 animation
   * 不会动。因此用定时器交替切换相位，再由 animation 做平滑过渡。
   */
  private startPulse(): void {
    if (this.pulseTimer !== -1) {
      return;
    }
    this.pulseTimer = setInterval(() => {
      this.chargePulse = this.chargePulse === 0 ? 1 : 0;
    }, 1100);
  }

  /**
   * 停止充电呼吸动效。
   */
  private stopPulse(): void {
    if (this.pulseTimer !== -1) {
      clearInterval(this.pulseTimer);
      this.pulseTimer = -1;
    }
  }

  /**
   * 充电标记状态变化时启停动效。
   *
   * 呼吸只跟随 chargePulsing（真正在充电），不是跟随 charging（插着枪）。
   */
  private onChargingChanged(): void {
    this.syncPulse();
  }

  /**
   * 标记点：常态中性，开启态走警示色。
   *
   * 位置按车模缩放后的坐标系对齐。
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
    .position({
      x: marker.x - 13,
      y: marker.y - 13
    })
  }

  /**
   * 充电口标记点：充电枪已连接时用深蓝实心圆盘 + 白色插头 + 单圈呼吸光环。
   *
   * 深蓝实心对纸白底是高对比，一眼可见；实心蓝底白图标也与右侧快捷按钮
   * 「开启 = 蓝底白图标」是同一套视觉语言。
   * 呼吸光环只有一圈，直径与透明度同步缓慢变化，不产生视觉噪音。
   */
  @Builder
  chargingPortMarker() {
    Stack({ alignContent: Alignment.Center }) {
      // 呼吸光环：只在真正充电时出现，直径与透明度随相位缓慢变化
      if (this.chargePulsing) {
        Stack()
          .width(this.chargePulse === 0 ? 30 : 40)
          .height(this.chargePulse === 0 ? 30 : 40)
          .borderRadius(this.chargePulse === 0 ? 15 : 20)
          .border({ width: 1.4, color: this.chargeColor })
          .opacity(this.chargePulse === 0 ? 0.15 : 0.55)
          .animation({ duration: 1100, curve: Curve.EaseInOut })
      }

      // 主体：实心圆盘，颜色随充电阶段变化
      Stack()
        .width(26)
        .height(26)
        .borderRadius(13)
        .backgroundColor(this.chargeColor)

      // 白色插头图标
      AppIcon({
        name: AppIconName.CHARGE_LINK,
        iconSize: 15,
        color: $r('app.color.app_on_accent')
      })
    }
    // 外层容器取最大光环直径，保证 40px 的环不被裁切；
    // 内部各元素仍以中心对齐，圆盘与光环同心。
    .width(40)
    .height(40)
    .borderRadius(20)
    .position({
      x: 52 - 20,
      y: 238 - 20
    })
  }

  /**
   * 描边宽度：设计稿单位 → 抵消 scale 放大，保持视觉粗细与设计稿一致。
   */
  private sw(value: number): number {
    return value / this.density;
  }

  /**
   * 判断某个部件是否处于开启态。
   *
   * 协议中 1 与 3 都表示「未关闭」，与原版 g10 的判定一致。
   */
  private isOpen(states: number[], index: number): boolean {
    if (index < 0 || index >= states.length) {
      return false;
    }
    const value = states[index];
    return value === 1 || value === 3;
  }

  /**
   * 开启的车门图示路径。
   *
   * 车门绕铰链向车身外侧展开，画成一块外凸的四边形门板：
   * 近边贴车身侧面（x=39 / x=161），远边向外偏移到 x=21 / x=179，
   * 并沿车身方向错开 10 —— 四扇门统一往车尾方向偏，形成一致的开门透视。
   * 坐标为 200×340 设计稿坐标系。
   */
  private doorPath(index: number): string {
    switch (index) {
      case 0: // 左前门
        return 'M39,100 L39,158 L21,168 L21,110 Z';
      case 1: // 右前门
        return 'M161,100 L161,158 L179,168 L179,110 Z';
      case 2: // 左后门
        return 'M39,164 L39,222 L21,232 L21,174 Z';
      default: // 右后门
        return 'M161,164 L161,222 L179,232 L179,174 Z';
    }
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
        // 尾门板：车身尾部的半圆区域（y=254 分割线以下、到车尾弧线）。
        // 填充色表达尾门锁状态，与车窗、车门同一套语言。
        // 画在车身轮廓之前 —— 否则填充会盖掉车身弧线的描边。
        // 上边界是已有的 M39 254h122 分隔线，底边与车身弧线重合。
        // 必须显式 stroke(Transparent)：Path 默认描边是黑色，
        // 不关掉的话封闭路径的顶部横线会多出一道黑边。
        Path({ commands: 'M39 254 L161 254 C161 294 142 328 100 328 C58 328 39 298 39 254 Z' })
          .fill(this.trunkUnlocked ? $r('app.color.app_trunk_open_fill') : Color.Transparent)
          .stroke(Color.Transparent)
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)

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

        // 四窗：逐扇独立染色，开启时填充 + 描边都走警示色。
        // 描边必须一起换 —— 原来描边始终是车身色，深色模式下填充色
        // （app_warn_soft = #2C2113）在 #0E0F10 底上几乎看不出来。
        Path({ commands: 'M45,96 L98,96 L98,158 L45,158 Z' })
          .fill(this.isOpen(this.windowStates, 0) ? $r('app.color.app_warn_soft') : Color.Transparent)
          .stroke(this.isOpen(this.windowStates, 0) ? $r('app.color.app_warn') : $r('app.color.app_primary_text'))
          .strokeWidth(this.sw(1.6))
          .strokeLineJoin(LineJoinStyle.Round)
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)
        Path({ commands: 'M102,96 L155,96 L155,158 L102,158 Z' })
          .fill(this.isOpen(this.windowStates, 1) ? $r('app.color.app_warn_soft') : Color.Transparent)
          .stroke(this.isOpen(this.windowStates, 1) ? $r('app.color.app_warn') : $r('app.color.app_primary_text'))
          .strokeWidth(this.sw(1.6))
          .strokeLineJoin(LineJoinStyle.Round)
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)
        Path({ commands: 'M45,162 L98,162 L98,224 L45,224 Z' })
          .fill(this.isOpen(this.windowStates, 2) ? $r('app.color.app_warn_soft') : Color.Transparent)
          .stroke(this.isOpen(this.windowStates, 2) ? $r('app.color.app_warn') : $r('app.color.app_primary_text'))
          .strokeWidth(this.sw(1.6))
          .strokeLineJoin(LineJoinStyle.Round)
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)
        Path({ commands: 'M102,162 L155,162 L155,224 L102,224 Z' })
          .fill(this.isOpen(this.windowStates, 3) ? $r('app.color.app_warn_soft') : Color.Transparent)
          .stroke(this.isOpen(this.windowStates, 3) ? $r('app.color.app_warn') : $r('app.color.app_primary_text'))
          .strokeWidth(this.sw(1.6))
          .strokeLineJoin(LineJoinStyle.Round)
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)

        // 开启的车门：向外展开的门板，用沃尔沃主题蓝
        if (this.isOpen(this.doorStates, 0)) {
          Path({ commands: this.doorPath(0) })
            .fill($r('app.color.app_accent_soft'))
            .stroke($r('app.color.app_accent'))
            .strokeWidth(this.sw(1.4))
            .strokeLineJoin(LineJoinStyle.Round)
            .width(`${this.viewW}px`)
            .height(`${this.viewH}px`)
        }
        if (this.isOpen(this.doorStates, 1)) {
          Path({ commands: this.doorPath(1) })
            .fill($r('app.color.app_accent_soft'))
            .stroke($r('app.color.app_accent'))
            .strokeWidth(this.sw(1.4))
            .strokeLineJoin(LineJoinStyle.Round)
            .width(`${this.viewW}px`)
            .height(`${this.viewH}px`)
        }
        if (this.isOpen(this.doorStates, 2)) {
          Path({ commands: this.doorPath(2) })
            .fill($r('app.color.app_accent_soft'))
            .stroke($r('app.color.app_accent'))
            .strokeWidth(this.sw(1.4))
            .strokeLineJoin(LineJoinStyle.Round)
            .width(`${this.viewW}px`)
            .height(`${this.viewH}px`)
        }
        if (this.isOpen(this.doorStates, 3)) {
          Path({ commands: this.doorPath(3) })
            .fill($r('app.color.app_accent_soft'))
            .stroke($r('app.color.app_accent'))
            .strokeWidth(this.sw(1.4))
            .strokeLineJoin(LineJoinStyle.Round)
            .width(`${this.viewW}px`)
            .height(`${this.viewH}px`)
        }

        // 充电线：充电枪已连接时，从充电口标记点左上角引出一段短线，
        // 斜向上再折平，暗示线缆走向车外。
        // 起点取圆点左上 45° 方向的边缘点（约 43,229），与圆相切不留缝；
        // 标记点在上层会盖住圆内部分，线必须画到圆外才会可见。
        if (this.charging) {
          Path({ commands: 'M43 229 L30 214 L12 214' })
            .fill(Color.Transparent)
            .stroke(this.chargeColor)
            .strokeWidth(this.sw(1.6))
            .strokeLineCap(LineCapStyle.Round)
            .strokeLineJoin(LineJoinStyle.Round)
            .width(`${this.viewW}px`)
            .height(`${this.viewH}px`)
        }

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

        // 尾门热区：透明 Path，承载点击。
        // 必须放在这个 Stack 的**最后**（最上层）—— 车身轮廓、尾灯、
        // 内部分隔线虽然 fill 透明，仍会按几何形状参与命中测试并吃掉
        // 点击，垫在它们下面就点不到尾门板。
        Path({ commands: 'M39 254 L161 254 C161 294 142 328 100 328 C58 328 39 298 39 254 Z' })
          .fill(Color.Transparent)
          .stroke(Color.Transparent)
          .width(`${this.viewW}px`)
          .height(`${this.viewH}px`)
          .onClick(() => {
            if (this.trunkBusy) {
              return;
            }
            if (this.onTrunkTap !== undefined) {
              this.onTrunkTap();
            }
          })
      }
      .width(`${this.viewW}px`)
      .height(`${this.viewH}px`)
      .scale(this.planScale())

      // ---------- 位置标记点（vp 坐标，与缩放后的车模对齐） ----------
      this.marker(new PlanMarker(100, 22, '盖', this.hoodOpen))
      if (this.charging) {
        this.chargingPortMarker()
      } else {
        this.marker(new PlanMarker(52, 238, '口', this.portOpen))
      }

      // 尾门状态指示：不再是「尾」字圆点（既是状态又是按钮，语义双重）。
      // 尾门板本身承担热区与状态，这里只叠加一个轻量指示：
      //   已解锁 → 锁图标（提示「当前是解锁态，点一下会上锁」）
      //   执行中 → 转圈（填充色保持原状态不变，只用动效表达进行中）
      Stack({ alignContent: Alignment.Center }) {
        if (this.trunkBusy) {
          LoadingProgress()
            .width(24)
            .height(24)
            .color($r('app.color.app_accent'))
        } else if (this.trunkUnlocked) {
          AppIcon({
            name: AppIconName.LOCK_OPEN,
            iconSize: 13,
            color: $r('app.color.app_trunk_open_stroke')
          })
        }
      }
      .width(34)
      .height(34)
      .position({ x: 83, y: 274 })
      // 指示器浮在尾门热区之上，必须让出命中测试，
      // 否则这 34×34 的透明区域会把尾门点击吃掉。
      .hitTestBehavior(HitTestMode.Transparent)

      // 说明文字
      Text('机盖').fontSize(9).fontColor($r('app.color.app_tertiary_text'))
        .position({ x: 118, y: 14 })
      // 充电口标签上移，给充电线让出位置
      Text('充电口').fontSize(9).fontColor($r('app.color.app_tertiary_text'))
        .position({ x: 2, y: 196 })
    }
    .width(this.viewW)
    .height(this.viewH)
  }
}
