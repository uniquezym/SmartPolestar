/**
 * 车辆视觉配置解析。
 *
 * 车辆的漆面、轮毂、车型年款全部编码在一串 **contentCodes** 里 ——
 * 16 段、以横杠分隔的大写字母数字串。还原自 Android 端：
 *   p000/vo0.m2927a        —— 16 段结构校验 + 轮毂尺寸推导
 *   p000/AbstractC0223ft.m1244S —— 漆面码 → 颜色枚举
 *   p000/h80.m1502c         —— 颜色枚举 → 中文名
 *
 * 段位含义（索引从 0 开始）：
 *   [0]  固定 "534"（车型族）
 *   [1]  漆面码，如 1104 / 110N / 1118
 *   [6][7] 车顶与动力组合（EV05/TP00、EV04/TX00）
 *   [10] 车顶饰条
 *   [12] 前轮毂码
 *   [13] 后轮毂码
 *   [15] 车型年款，如 2024
 */
export class VehicleVisual {
  /** contentCodes 的段数。 */
  static readonly SLOT_COUNT: number = 16;

  /** 车身颜色中文名，空串表示未识别。 */
  paintName: string = '';

  /** 轮毂尺寸（英寸），0 表示未识别。 */
  wheelInch: number = 0;

  /** 是否高性能套件（R116 前轮 + R005 后轮）。 */
  performancePack: boolean = false;

  /** 车型年款，空串表示未识别。 */
  modelYear: string = '';

  /**
   * 解析 contentCodes。
   *
   * @param contentCodes 车辆配置码串
   * @returns 解析结果；结构不合法时返回各项均为空的实例
   */
  static parse(contentCodes: string): VehicleVisual {
    const result = new VehicleVisual();
    if (contentCodes.length === 0) {
      return result;
    }

    const slots = contentCodes.trim().toUpperCase().split('-');
    if (slots.length !== VehicleVisual.SLOT_COUNT) {
      return result;
    }
    // 第 1 段必须是车型族「534」，末段必须是 4 位年款。
    if (slots[0] !== '534' || !slots[15].match(/^20\d{2}$/)) {
      return result;
    }
    for (const slot of slots) {
      if (slot.length === 0 || !slot.match(/^[A-Z0-9]+$/)) {
        return result;
      }
    }

    result.modelYear = slots[15];
    result.paintName = VehicleVisual.paintNameOf(slots[1]);
    result.wheelInch = VehicleVisual.wheelInchOf(slots[12], slots[13]);
    result.performancePack = slots[12] === 'R116' && slots[13] === 'R005';
    return result;
  }

  /**
   * 漆面码 → 中文颜色名。
   *
   * 110E / 110H 都是雪晶白（不同材质，同一颜色）。
   */
  private static paintNameOf(code: string): string {
    switch (code) {
      case '1104': return '虚空黑';
      case '1107': return '太空黑';
      case '1109': return '木星金';
      case '110E':
      case '110H': return '雪晶白';
      case '110N': return '午夜蓝';
      case '110R': return '月光银';
      case '1115': return '蒸汽灰';
      case '110T': return '雷霆灰';
      case '110U': return '镁光银';
      case '1117': return '风暴灰';
      case '1118': return '沙丘色';
      default: return '';
    }
  }

  /**
   * 前 / 后轮毂码 → 轮毂尺寸（英寸）。
   *
   * 前后轮尺寸必须一致才认 —— 不一致说明配置异常，返回 0。
   */
  private static wheelInchOf(front: string, rear: string): number {
    const frontInch = VehicleVisual.wheelInchOfCode(front);
    const rearInch = VehicleVisual.wheelInchOfCode(rear);
    if (frontInch <= 0 || rearInch <= 0 || frontInch !== rearInch) {
      return 0;
    }
    return frontInch;
  }

  /**
   * 单个轮毂码 → 尺寸（英寸）。
   *
   * 对应 Android 端 `wi0` 构造函里的两段 switch：
   * 前轮毂（slots[12]）走 hashCode sparse-switch，
   *   分成两组：{R116, R149, R159} → 20 寸，{R14B, R184} → 19 寸
   * 后轮毂（slots[13]）走字符串比较，
   *   分成两组：{R003, R00B} → 19 寸，{R004, R005, R00C} → 20 寸
   *
   * 前后尺寸不一致说明是错配轮毂（Android 端会记 WHEEL_STAGGERED_SIZE_MISMATCH），
   * 这种情况下不显示尺寸。
   */
  private static wheelInchOfCode(code: string): number {
    switch (code) {
      // 前轮毂
      case 'R116':
      case 'R149':
      case 'R159': return 20;
      case 'R14B':
      case 'R184': return 19;
      // 后轮毂
      case 'R003':
      case 'R00B': return 19;
      case 'R004':
      case 'R005':
      case 'R00C': return 20;
      default: return 0;
    }
  }
}
