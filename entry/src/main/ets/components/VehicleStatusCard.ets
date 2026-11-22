import { AppIcon, AppIconName } from './Icons';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'VehicleStatusCard';

/**
 * 淡出时长（毫秒）。
 *
 * 淡出结束后才换内容并淡入 —— 旧内容先退场，新内容再进场，
 * 两段合起来是一次完整的「整条替换」，而不是左右滚动。
 */
const FADE_OUT_MS: number = 160;

/**
 * 淡入 / 淡出的过渡时长（毫秒）。
 */
const FADE_DURATION_MS: number = 200;

/**
 * 切换时新内容上移的距离（vp）。
 */
const SLIDE_DISTANCE: number = 6;

/**
 * 状态的语义档位，决定徽章配色。
 */
export enum StatusTone {
  /** 正常运行中（充电 / 露营 / 空调 / 净化）—— 品牌蓝。 */
  NORMAL = 0,
  /** 已完成 —— 成功绿。 */
  OK = 1,
  /** 需要关注（车辆健康告警）—— 警示黄。 */
  WARN = 2,
  /** 异常（充电错误）—— 错误红。 */
  ERROR = 3
}

/**
 * 一条可轮播的车辆状态。
 */
export interface StatusEntry {
  /** 徽章配色档位。 */
  tone: StatusTone;
  /** 主文案（如「充电完成」）。 */
  title: string;
  /** 辅助数据（如「剩余 32 分」），空字符串则不显示。 */
  detail: string;
}

/**
 * 车辆状态卡片。
 *
 * 复刻海外版 Polestar App 的「状态条」：白色圆角卡片，左侧彩色数字徽章
 * （数字 = 当前这条的序号，第几条），中间状态文案，右侧下钻箭头。
 *
 * 多条状态时轮播显示 —— 但不是滚动，而是整条内容先淡出、
 * 换上新内容再淡入，读起来是「换了一条状态」。
 *
 * 轮播由组件自己驱动：父组件只负责提供状态列表。
 * 内容始终直接取自 entries[currentIndex]，
 * 因此父组件更新了某条状态的文案（比如倒计时），卡片会立刻跟上。
 */
@Component
export struct VehicleStatusCard {
  /** 全部状态。 */
  @Prop entries: StatusEntry[] = [];
  /** 轮播间隔（毫秒）。 */
  @Prop intervalMs: number = 5000;
  /** 是否处于活跃状态（页面可见）。页面隐藏时停掉轮播。 */
  @Prop @Watch('onActiveChanged') active: boolean = true;

  /** 当前显示第几条。 */
  @State private currentIndex: number = 0;
  /** 内容的可见度：1 = 完全可见，0 = 完全透明。 */
  @State private visible: number = 1;

  /** 轮播定时器。 */
  private carouselTimer: number = -1;
  /** 换内容的定时器。 */
  private swapTimer: number = -1;

  aboutToAppear(): void {
    this.startCarousel();
  }

  aboutToDisappear(): void {
    this.stopCarousel();
  }

  /**
   * 活跃状态变化时启停轮播。
   */
  private onActiveChanged(): void {
    if (this.active) {
      this.startCarousel();
    } else {
      this.stopCarousel();
    }
  }

  /**
   * 启动轮播定时器。
   */
  private startCarousel(): void {
    this.stopCarousel();
    this.carouselTimer = setInterval(() => {
      this.advance();
    }, this.intervalMs);
  }

  /**
   * 停止轮播定时器。
   */
  private stopCarousel(): void {
    if (this.carouselTimer !== -1) {
      clearInterval(this.carouselTimer);
      this.carouselTimer = -1;
    }
    if (this.swapTimer !== -1) {
      clearTimeout(this.swapTimer);
      this.swapTimer = -1;
    }
  }

  /**
   * 推进到下一条状态。
   *
   * 两段式：先淡出当前内容，间隔一小段时间后换成下一条并淡入。
   */
  private advance(): void {
    const count = this.entries.length;
    if (count <= 1) {
      // 只有一条状态时不需要轮播，把下标归零以免指向已消失的条目。
      this.currentIndex = 0;
      return;
    }
    this.visible = 0;
    if (this.swapTimer !== -1) {
      clearTimeout(this.swapTimer);
    }
    this.swapTimer = setTimeout(() => {
      this.swapTimer = -1;
      // 淡出的这段时间里状态列表可能变了（状态消失了）——
      // 重新取一次条数，避免除以 0 或指向越界的条目。
      const total = this.entries.length;
      if (total === 0) {
        this.currentIndex = 0;
        this.visible = 1;
        return;
      }
      this.currentIndex = (this.safeIndex() + 1) % total;
      this.visible = 1;
    }, FADE_OUT_MS);
  }

  /**
   * 当前下标 —— 越界时回落到第一条。
   */
  private safeIndex(): number {
    const count = this.entries.length;
    if (count === 0) {
      return 0;
    }
    if (this.currentIndex < 0 || this.currentIndex >= count) {
      return 0;
    }
    return this.currentIndex;
  }

  /**
   * 当前显示的状态条目。
   */
  private currentEntry(): StatusEntry {
    const index = this.safeIndex();
    if (this.entries.length === 0) {
      return { tone: StatusTone.NORMAL, title: '', detail: '' };
    }
    return this.entries[index];
  }

  /**
   * 徽章底色。取当前这条的语义色。
   */
  private badgeColor(): ResourceColor {
    switch (this.currentEntry().tone) {
      case StatusTone.ERROR:
        return $r('app.color.app_error');
      case StatusTone.WARN:
        return $r('app.color.app_warn');
      case StatusTone.OK:
        return $r('app.color.app_ok');
      default:
        return $r('app.color.app_accent');
    }
  }

  build() {
    // ---------- 卡片主体 ----------
    Row({ space: 12 }) {
      // 徽章：数字 = 当前这条的序号（第几条）
      Text(`${this.safeIndex() + 1}`)
        .fontSize(12)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_on_accent'))
        .width(22)
        .height(22)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.badgeColor())
        .borderRadius(11)

      // 状态文案：整条内容一起淡出淡入
      Row({ space: 8 }) {
        Text(this.currentEntry().title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_primary_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.currentEntry().detail.length > 0) {
          Text(this.currentEntry().detail)
            .fontSize(13)
            .fontColor($r('app.color.app_tertiary_text'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      .alignItems(VerticalAlign.Bottom)
      .opacity(this.visible)
      .translate({ x: 0, y: (1 - this.visible) * SLIDE_DISTANCE })
      .animation({ duration: FADE_DURATION_MS, curve: Curve.EaseOut })

      // 下钻箭头
      AppIcon({
        name: AppIconName.ARROW_UP_RIGHT,
        iconSize: 16,
        color: $r('app.color.app_polar')
      })
        .width(16)
        .height(16)
    }
    .width('100%')
    .height(44)
    .padding({ left: 12, right: 12 })
    .backgroundColor($r('app.color.app_surface'))
    .borderRadius(8)
    .border({ width: 1, color: $r('app.color.app_card_border') })
    .alignItems(VerticalAlign.Center)
  }
}
