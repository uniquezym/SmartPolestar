/**
 * 空气净化实况窗的数据组装。
 *
 * 展示形态（对应 LiveView 的三块区域）：
 *   胶囊态   —— 「净化中 · 剩余 N 分钟」
 *   展开卡片 —— 标题「空气净化」+ 内容「AQI / PM2.5 / 剩余时间」+ 底部「停止净化」按钮
 *
 * 剩余时间按分钟计，不做秒级跳动 —— 车端上报的剩余时长并不严格递减，
 * 实时倒计时会出现数字卡住不动的观感。
 */

/**
 * 实况窗要展示的一组数据。
 */
export interface AirPurifyLiveData {
  /** AQI 指数，-1 表示未知。 */
  aqi: number;
  /** PM2.5 浓度（μg/m³），-1 表示未知。 */
  pm25: number;
  /** 剩余运行分钟数，-1 表示车端未上报。 */
  remainingMinutes: number;
}

/**
 * 实况窗文案组装。
 */
export class LiveViewData {
  /**
   * 实况窗事件标识 —— 同一业务用同一个 event，系统据此归类。
   *
   * 只能用官方白名单里的场景值，否则会被判为不合规场景。
   *
   * 选 TIMER（计时）：
   *   空气净化是按时长运行的设备服务 —— 用户主动开启、有开始时间、
   *   有截止时间、有倒计时，形态与「计时」一致。
   *   申请时在 AppGallery Connect 的实况窗服务权益里选计时场景。
   */
  static readonly EVENT_NAME: string = 'TIMER';

  /** 卡片标题。带上「中」字表达运行态 —— 辅助区被停止按钮占用了，状态词得放这里。 */
  static readonly TITLE: string = '空气净化中';

  /** 运行态标签。 */
  static readonly RUNNING_LABEL: string = '净化中';

  /**
   * 停止净化指令的公共事件名。
   *
   * 实况窗上的「停止净化」按钮用 WantAgent 发这个事件，
   * 应用进程收到后静默执行关闭 —— 全程不跳页面、不弹窗。
   */
  static readonly STOP_EVENT: string = 'com.polestar.smartpolestar.airpurify.stop';

  /** 展开卡片里「停止净化」按钮的文案。 */
  static readonly STOP_LABEL: string = '停止净化';

  /**
   * 打开应用用的 Ability 名。
   *
   * 实况窗卡片的默认点击动作用它把用户带回应用看详情。
   */
  static readonly ABILITY_NAME: string = 'EntryAbility';

  /**
   * 胶囊态图标。
   *
   * 取 /resources/rawfile 下的文件名 —— 胶囊图标是必填项，
   * 少了会报 401（The type of capsule.icon must be string | image.PixelMap）。
   */
  static readonly CAPSULE_ICON: string = 'liveview_air_icon.png';

  /** 胶囊底色 —— 用品牌深蓝，与应用主色一致。 */
  static readonly CAPSULE_BACKGROUND: string = '#FF003057';

  /** 空数据 —— 停止实况窗时不需要真实内容。 */
  static readonly EMPTY_DATA: AirPurifyLiveData = {
    aqi: -1,
    pm25: -1,
    remainingMinutes: -1
  };

  /**
   * 数值文案。未知时显示破折号。
   */
  static numberText(value: number): string {
    return value >= 0 ? `${Math.round(value)}` : '—';
  }

  /**
   * 剩余时长文案。
   *
   * 车端未上报时返回空串 —— 胶囊里就不带这一段。
   */
  static remainingText(remainingMinutes: number): string {
    if (remainingMinutes < 0) {
      return '';
    }
    return `剩余 ${Math.round(remainingMinutes)} 分钟`;
  }

  /**
   * 胶囊态文案。
   */
  static capsuleText(data: AirPurifyLiveData): string {
    const remaining = LiveViewData.remainingText(data.remainingMinutes);
    return remaining.length > 0 ? `净化中 · ${remaining}` : '净化中';
  }

  /**
   * 展开卡片的内容文案。
   *
   * AQI / PM2.5 / 剩余时间三段用「·」连接；未知的项直接不出现。
   */
  static contentText(data: AirPurifyLiveData): string {
    const parts: string[] = [];
    if (data.aqi >= 0) {
      parts.push(`AQI ${LiveViewData.numberText(data.aqi)}`);
    }
    if (data.pm25 >= 0) {
      parts.push(`PM2.5 ${LiveViewData.numberText(data.pm25)}`);
    }
    const remaining = LiveViewData.remainingText(data.remainingMinutes);
    if (remaining.length > 0) {
      parts.push(remaining);
    }
    if (parts.length === 0) {
      return '净化中';
    }
    return parts.join(' · ');
  }
}
