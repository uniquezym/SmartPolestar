/**
 * 极星图标库 —— 还原 Android 原版的线性描边图标。
 *
 * 路径数据直接取自 APK 的 res/drawable/*.xml（vector drawable），
 * 统一为 24×24 视口、1.55~1.8px 描边、圆头圆角的视觉语言，
 * 与原版 ic_* 系列保持一致。
 *
 * 用法：<AppIcon name={AppIconName.LOCK_CLOSED} color={...} iconSize={20} />
 *
 * 注意：ArkUI 的 Path 组件用 SVG path 语法，坐标系与 Android vector 一致，
 * 但描边色需显式指定（不能像 Android 那样写在 vector 里）。
 *
 * 【单位坑】Path 的 commands 坐标单位是 **px**（物理像素），而组件的
 * width/height 默认单位是 **vp**。两者不同域，直接使用会让 24 单位的图标在
 * 3 倍屏上只画成 8vp 大小（约 1/3）。
 * 本组件的处理：把 Path 盒子也写成 px 尺寸（视口与路径坐标 1:1 对齐），
 * 再用 scale() 按 vp2px(1) 放大到目标 vp 尺寸 —— 这样无需解析 path 字符串。
 */

/**
 * 图标名枚举。
 */
export enum AppIconName {
  /** 车锁（已锁）。 */
  LOCK_CLOSED = 'lock_closed',
  /** 车锁（已解锁）。 */
  LOCK_OPEN = 'lock_open',
  /** 驻车空调（气流）。 */
  CLIMATE_AIRFLOW = 'climate_airflow',
  /** 驻车空调（制冷）。 */
  CLIMATE_COOL = 'climate_cool',
  /** 驻车空调（制热）。 */
  CLIMATE_HEAT = 'climate_heat',
  /** 鸣笛。 */
  HORN = 'horn',
  /** 闪灯。 */
  FLASH = 'flash',
  /** 充电。 */
  CHARGE = 'charge',
  /** 充电枪已连接（插头）。 */
  CHARGE_LINK = 'charge_link',
  /** 车辆健康。 */
  HEALTH = 'health',
  /** 里程。 */
  MILEAGE = 'mileage',
  /** 位置。 */
  LOCATION = 'location',
  /** 尾门。 */
  TRUNK = 'trunk',
  /** 车窗。 */
  WINDOW = 'window',
  /** 空气净化。 */
  AIR = 'air',
  /** 向下箭头。 */
  CHEVRON_DOWN = 'chevron_down',
  /** 充电（交流）。填充图标。 */
  CHARGE_AC = 'charge_ac',
  /** 充电（直流）。填充图标。 */
  CHARGE_DC = 'charge_dc',
  /** 充电（插头）。填充图标。 */
  CHARGE_PLUG = 'charge_plug',
  /** 闹钟（预约充电）。 */
  ALARM = 'alarm',
  /** 概览（首页）。 */
  TAB_HOME = 'tab_home',
  /** 控制。 */
  TAB_CONTROL = 'tab_control',
  /** 详情。 */
  TAB_DETAIL = 'tab_detail',
  /** 刷新。 */
  REFRESH = 'refresh'
}

/**
 * 各图标的路径与描边宽度。
 */
interface IconShape {
  path: string;
  strokeWidth: number;
  /** 是否为填充图标（原版 ic_charge_* 是填充而非描边）。 */
  filled?: boolean;
}

const SHAPES: Record<string, IconShape> = {
  // Android: ic_lock_closed.xml（路径放大到 4..20，占满视口）
  [AppIconName.LOCK_CLOSED]: {
    path: 'M4.5,9.5 L19.5,9.5 L19.5,20.5 L4.5,20.5 Z M7,9.5 L7,6 A5,5 0 0 1 17,6 L17,9.5 M12,13.5 L12,17',
    strokeWidth: 1.8
  },
  // Android: ic_lock_open.xml
  [AppIconName.LOCK_OPEN]: {
    path: 'M6.5,9.5 L6.5,6 A5.5,5.5 0 0 1 16.7,3.3 M5,9.5 L18.5,9.5 A2.4,2.4 0 0 1 20.9,11.9 L20.9,20.5 ' +
      'A2.4,2.4 0 0 1 18.5,22.9 L5,22.9 A2.4,2.4 0 0 1 2.6,20.5 L2.6,11.9 A2.4,2.4 0 0 1 5,9.5 Z M12,14 L12,18.5',
    strokeWidth: 1.9
  },
  // Android: ic_climate_airflow.xml（等比放大到 2.5..21.5）
  [AppIconName.CLIMATE_AIRFLOW]: {
    path: 'M2.5,7.5 L21.5,7.5 M2.5,12 L21.5,12 M2.5,16.5 L21.5,16.5 M12,2.5 L12,21.5 ' +
      'M7,4.9 L12,2.5 L17,4.9 M7,19.1 L12,21.5 L17,19.1',
    strokeWidth: 1.7
  },
  // Android: ic_climate_cool.xml
  [AppIconName.CLIMATE_COOL]: {
    path: 'M12,2.5 L12,21.5 M3.4,7 L20.6,17 M3.4,17 L20.6,7 ' +
      'M12,2.5 L9,5.4 M12,2.5 L15,5.4 M12,21.5 L9,18.6 M12,21.5 L15,18.6',
    strokeWidth: 1.7
  },
  // Android: ic_climate_heat.xml
  [AppIconName.CLIMATE_HEAT]: {
    path: 'M5.8,20.5 C3.9,17.9 7.8,15.4 5.8,12.8 C3.9,10.3 7.8,7.8 5.8,5.2 ' +
      'M12,20.5 C10.1,17.9 14,15.4 12,12.8 C10.1,10.3 14,7.8 12,5.2 ' +
      'M18.2,20.5 C16.3,17.9 20.2,15.4 18.2,12.8 C16.3,10.3 20.2,7.8 18.2,5.2',
    strokeWidth: 1.8
  },
  // Android: ic_horn.xml
  [AppIconName.HORN]: {
    path: 'M2.8,9.5 L7.3,9.5 L16,4.8 L16,19.2 L7.3,14.5 L2.8,14.5 Z M7.3,9.5 L7.3,14.5 ' +
      'M18.8,8.4 C20.3,9.9 20.3,14.1 18.8,15.6 M21.2,5.8 C23.8,8.6 23.8,15.4 21.2,18.2',
    strokeWidth: 1.75
  },
  // Android: ic_flash.xml
  [AppIconName.FLASH]: {
    path: 'M12.2,4.2 C16.4,4.2 19.7,7.6 19.7,12 C19.7,16.4 16.4,19.8 12.2,19.8 L9.2,19.8 L9.2,4.2 Z ' +
      'M6.3,6.3 L2.2,6.3 M5.4,9.4 L1.5,9.4 M5,12.9 L1.5,12.9 M5.4,16.4 L1.5,16.4 M6.3,19.7 L2.2,19.7',
    strokeWidth: 1.65
  },
  // Android: ic_charge_status.xml
  [AppIconName.CHARGE]: {
    path: 'M5,2 L19,2 A2.6,2.6 0 0 1 21.6,4.6 L21.6,19.4 A2.6,2.6 0 0 1 19,22 L5,22 A2.6,2.6 0 0 1 2.4,19.4 ' +
      'L2.4,4.6 A2.6,2.6 0 0 1 5,2 Z M12.6,4.6 L7.9,12.2 L11.4,12.2 L10.8,19.6 L16.5,10.6 L13,10.6 Z',
    strokeWidth: 1.7
  },
  // 充电枪已连接：细线插头（两根插脚 + 插头体）
  [AppIconName.CHARGE_LINK]: {
    path: 'M10.4,5 L10.4,10 M13.6,5 L13.6,10 ' +
      'M8.2,10 L15.8,10 A1.2,1.2 0 0 1 17,11.2 L17,14.8 A1.2,1.2 0 0 1 15.8,16 L8.2,16 ' +
      'A1.2,1.2 0 0 1 7,14.8 L7,11.2 A1.2,1.2 0 0 1 8.2,10 Z',
    strokeWidth: 1.6
  },
  // Android: ic_health_service.xml
  [AppIconName.HEALTH]: {
    path: 'M14.4,5 A5.6,5.6 0 0 0 7,12.4 L1.9,17.5 A2.2,2.2 0 0 0 5,20.6 L10.1,15.5 ' +
      'A5.6,5.6 0 0 0 17.6,8.5 L14.4,11.7 L12.4,9.7 L15.7,6.4 Z',
    strokeWidth: 1.8
  },
  // Android: ic_mileage_history.xml（等比放大到 2..22）
  [AppIconName.MILEAGE]: {
    path: 'M2,17.5 L9.5,10 L13.5,14 L22,5.5 M18,5 L22,5.5 L22,9.5',
    strokeWidth: 1.8
  },
  // Android: ic_location_pin.xml（128 视口，等比放大到 3..21）
  [AppIconName.LOCATION]: {
    path: 'M12,21.5 C12,21.5 20,14.2 20,9.6 C20,5.4 16.4,2 12,2 C7.6,2 4,5.4 4,9.6 ' +
      'C4,14.2 12,21.5 12,21.5 Z M12,6.5 A3.1,3.1 0 1 1 12,12.7 A3.1,3.1 0 1 1 12,6.5 Z',
    strokeWidth: 1.7
  },
  // 尾门（由原版尾门控制语义自绘）
  [AppIconName.TRUNK]: {
    path: 'M3,12.5 L3,18.5 A2.4,2.4 0 0 0 5.4,20.9 L18.6,20.9 A2.4,2.4 0 0 0 21,18.5 L21,12.5 ' +
      'M3,12.5 L7,6.4 A2.4,2.4 0 0 1 9,5.3 L15,5.3 A2.4,2.4 0 0 1 17,6.4 L21,12.5 Z M8.8,12.5 L15.2,12.5',
    strokeWidth: 1.7
  },
  // 车窗（由原版车窗控制语义自绘）
  [AppIconName.WINDOW]: {
    path: 'M3.6,5 L20.4,5 A1.4,1.4 0 0 1 21.8,6.4 L21.8,17.6 A1.4,1.4 0 0 1 20.4,19 L3.6,19 A1.4,1.4 0 0 1 2.2,17.6 ' +
      'L2.2,6.4 A1.4,1.4 0 0 1 3.6,5 Z M12,5 L12,19 M6,8.4 L9.4,8.4 M14.6,15.6 L18,15.6',
    strokeWidth: 1.7
  },
  // 空气净化（由原版 PreCleaning 语义自绘）
  [AppIconName.AIR]: {
    path: 'M2,7.5 L11.5,7.5 A3,3 0 1 0 8.5,4.5 M2,12 L16,12 A3,3 0 1 1 13,9 M2,16.5 L10,16.5 A3,3 0 1 1 7,13.5',
    strokeWidth: 1.7
  },
  // Android: ic_chevron_down.xml
  [AppIconName.CHEVRON_DOWN]: {
    path: 'M5,8.5 L12,15.5 L19,8.5',
    strokeWidth: 1.8
  },
  // Android: ic_charge_plug.xml（填充图标）
  [AppIconName.CHARGE_PLUG]: {
    path: 'M8,2 L10,2 L10,7 L14,7 L14,2 L16,2 L16,7 L19,7 L19,10 ' +
      'C19,12.9 17.2,15.3 14.5,15.9 L14.5,22 L11.5,22 L11.5,15.9 ' +
      'C8.8,15.3 7,12.9 7,10 L7,7 L8,7 Z',
    strokeWidth: 0,
    filled: true
  },
  // Android: ic_charge_ac.xml（填充图标，底部带两段圆头）
  [AppIconName.CHARGE_AC]: {
    path: 'M8,2 L10,2 L10,7 L14,7 L14,2 L16,2 L16,7 L19,7 L19,10 ' +
      'C19,12.8 17.2,15.1 14.5,15.8 L14.5,17 C14.5,18.7 15.8,20 17.5,20 ' +
      'L17.5,22 C14.7,22 12.5,19.8 12.5,17 L12.5,15.9 C9.8,15.1 8,12.8 8,10 L8,7 L8,7 Z',
    strokeWidth: 0,
    filled: true
  },
  // Android: ic_charge_dc.xml（填充图标）
  [AppIconName.CHARGE_DC]: {
    path: 'M9,2 L15,2 L15,6 L18,6 L18,9 L20,11 L20,14 L18,14 L18,22 L8,22 L8,14 L6,14 ' +
      'L6,11 L8,9 L8,6 L9,6 Z',
    strokeWidth: 0,
    filled: true
  },
  // Android: ic_alarm.xml（128 视口，等比缩放到 24 视口）
  [AppIconName.ALARM]: {
    path: 'M12,2.5 A10,10 0 1 1 11.99,2.5 Z M11.2,6.2 L11.2,12.4 L16.6,12.4 L16.6,13.6 ' +
      'L11.2,13.6 L11.2,6.2 Z',
    strokeWidth: 0,
    filled: true
  },
  // 底部导航：概览
  [AppIconName.TAB_HOME]: {
    path: 'M3.5,10 L12,3.5 L20.5,10 L20.5,19.5 A1,1 0 0 1 19.5,20.5 L14.5,20.5 L14.5,14.5 L9.5,14.5 L9.5,20.5 L4.5,20.5 A1,1 0 0 1 3.5,19.5 Z',
    strokeWidth: 1.7
  },
  // 底部导航：控制（九宫格）
  [AppIconName.TAB_CONTROL]: {
    path: 'M3.5,3.5 L10.5,3.5 L10.5,10.5 L3.5,10.5 Z M13.5,3.5 L20.5,3.5 L20.5,10.5 L13.5,10.5 Z ' +
      'M3.5,13.5 L10.5,13.5 L10.5,20.5 L3.5,20.5 Z M13.5,13.5 L20.5,13.5 L20.5,20.5 L13.5,20.5 Z',
    strokeWidth: 1.6
  },
  // 底部导航：详情（清单）
  [AppIconName.TAB_DETAIL]: {
    path: 'M5,12 L19,12 M6,9 L18,9 M7,6 L17,6 M8,15 L16,15 M9,18 L15,18',
    strokeWidth: 1.7
  },
  // 刷新（环形箭头）
  [AppIconName.REFRESH]: {
    path: 'M20.5,12 A8.5,8.5 0 1 1 17.9,5.9 M20.5,4.5 L20.5,9 L16,9',
    strokeWidth: 1.7
  }
};

/**
 * 线性描边图标。
 */
@Component
export struct AppIcon {
  /** 图标名。 */
  @Prop name: AppIconName = AppIconName.LOCK_CLOSED;
  /** 描边色（填充图标下即为填充色）。 */
  @Prop color: ResourceColor = $r('app.color.app_secondary_text');
  /** 尺寸（vp）。用 iconSize 而非 size —— size 与 CustomComponent 基类属性冲突。 */
  @Prop iconSize: number = 24;

  /** 图标视口边长（路径坐标单位，px 域）。 */
  private readonly viewport: number = 24;
  /** 屏幕密度：1vp 对应多少 px。 */
  private density: number = 3;

  aboutToAppear(): void {
    this.density = this.getUIContext().vp2px(1);
  }

  /**
   * 放大系数：视口 24px → 目标 iconSize vp。
   */
  private iconScale(): ScaleOptions {
    const s: number = this.iconSize * this.density / this.viewport;
    return { x: s, y: s, centerX: 0, centerY: 0 };
  }

  /**
   * 描边宽度：scale 会一并放大描边，需反向抵消，使视觉描边与 SVG viewBox 语义一致。
   */
  private strokeWidth(): number {
    return SHAPES[this.name].strokeWidth / this.density;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      if (SHAPES[this.name].filled === true) {
        Path({ commands: SHAPES[this.name].path })
          .width(`${this.viewport}px`)
          .height(`${this.viewport}px`)
          .scale(this.iconScale())
          .fill(this.color)
      } else {
        Path({ commands: SHAPES[this.name].path })
          .width(`${this.viewport}px`)
          .height(`${this.viewport}px`)
          .scale(this.iconScale())
          .fill(Color.Transparent)
          .stroke(this.color)
          .strokeWidth(this.strokeWidth())
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
      }
    }
    .width(this.iconSize)
    .height(this.iconSize)
  }
}
