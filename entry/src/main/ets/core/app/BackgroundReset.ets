/**
 * 后台超时回到概览页的状态协调。
 *
 * 分工：
 *   - Ability 的 onBackground / onForeground 负责计时。这两个回调时机可靠，
 *     一定会被调用，但**不能**在这里做路由跳转 —— 那一刻 ArkUI 的 UI 还没
 *     恢复前台，router 指令会被丢弃。
 *   - 页面在 onPageShow 时执行跳转 —— ArkUI 切回前台时会给页面触发
 *     onPageShow，这时做路由跳转才生效。
 *
 * 【两个坑】
 * 1. 切回前台时，路由栈里的**每个页面**都会依次触发 onPageShow —— Index 在
 *    栈底，会先于 ParkedPlace 触发。所以判定函数不能「读取即消费」，否则
 *    Index 会把「后台超时」标记吃掉，轮到 ParkedPlace 时它已不知道要 back。
 *    needReset() 是纯判断，不改状态。
 *
 * 2. 只有**切后台时正停在栈顶的那个页面**才该执行 back。若在 Index 时切后台，
 *    回来后不该跳转；之后用户自己进 ParkedPlace，那次进入是新的页面生命周期，
 *    不该触发历史标记。所以进入后台时记下当时的栈顶页面名，
 *    needReset() 只对该页面的那次恢复为 true。
 */
import { UIContext } from '@kit.ArkUI';
import { Log } from '../../common/Log';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'BackgroundReset';

export class BackgroundReset {
  /** 后台停留超过这个时长（毫秒），回到前台就重置回概览页。 */
  static readonly THRESHOLD_MS: number = 2 * 60 * 1000;

  /** 概览页路由名。 */
  private static readonly INDEX_URL: string = 'pages/Index';

  /** 进入后台的时刻；0 表示当前不在后台。 */
  private static hiddenAt: number = 0;

  /** 进入后台时所在的页面名 —— 只有这个页面恢复显示时才需要 back。 */
  private static hiddenPage: string = '';

  /**
   * 应用进入后台时调用。
   *
   * @param pageName 进入后台时栈顶页面的名字（如 'Index' / 'ParkedPlace'）
   */
  static onBackground(pageName: string): void {
    BackgroundReset.hiddenAt = Date.now();
    BackgroundReset.hiddenPage = pageName;
    Log.info(TAG, `进入后台，时刻=${BackgroundReset.hiddenAt}，所在页面=${pageName}`);
  }

  /**
   * 应用回到前台时调用。
   *
   * 只打日志，**不改状态** —— onForeground 与 onPageShow 的先后顺序不保证，
   * 判定统一交给 needReset() 现场算，两种顺序结果一致。
   *
   * @returns 后台停留时长（毫秒）；未进入过后台返回 0
   */
  static onForeground(): number {
    const elapsed = BackgroundReset.elapsed();
    Log.info(TAG, `回到前台，后台停留 ${elapsed} ms，阈值 ${BackgroundReset.THRESHOLD_MS} ms，` +
      `超时=${elapsed >= BackgroundReset.THRESHOLD_MS}`);
    return elapsed;
  }

  /**
   * 当前这次后台已经停留了多久（毫秒）。
   *
   * 纯计算，不改状态。
   */
  static elapsed(): number {
    if (BackgroundReset.hiddenAt === 0) {
      return 0;
    }
    return Date.now() - BackgroundReset.hiddenAt;
  }

  /**
   * 当前页面是否需要 back 回概览页。
   *
   * **纯判断，不消费标记** —— 栈里多个页面都会问，结果必须一致。
   *
   * @param pageName 当前页面的名字
   * @returns true 表示需要 back 回概览页
   */
  static needReset(pageName: string): boolean {
    const elapsed = BackgroundReset.elapsed();
    if (elapsed < BackgroundReset.THRESHOLD_MS) {
      return false;
    }
    // 只有切后台时停在这一页的才需要跳转 ——
    // 否则用户后来自己进的页面会被历史标记误伤。
    if (BackgroundReset.hiddenPage !== pageName) {
      Log.info(TAG, `后台 ${elapsed} ms 超时，但当时停在 ${BackgroundReset.hiddenPage}，` +
        `当前页 ${pageName} 无需跳转`);
      return false;
    }
    Log.info(TAG, `后台 ${elapsed} ms 超时，当前页 ${pageName} 需要回到概览页`);
    return true;
  }

  /**
   * 后台停留是否已超时。
   *
   * **纯判断，不消费标记** —— 与 needReset 分开是因为「切 Tab」和「页面跳转」
   * 是两件事：概览页要切自己的 Tab（消费标记），子页要 back 回概览页
   * （也消费标记），但两者不能互相把对方的标记吃掉。
   *
   * @returns true 表示后台停留已超时
   */
  static isTimeout(): boolean {
    const elapsed = BackgroundReset.elapsed();
    if (elapsed < BackgroundReset.THRESHOLD_MS) {
      return false;
    }
    Log.info(TAG, `后台 ${elapsed} ms 超时`);
    return true;
  }

  /**
   * 标记已处理 —— 重置完成后调用，避免下次误触发。
   */
  static consume(): void {
    Log.info(TAG, `重置标记已消费（后台停留 ${BackgroundReset.elapsed()} ms）`);
    BackgroundReset.hiddenAt = 0;
    BackgroundReset.hiddenPage = '';
  }

  /**
   * 后退到概览页（栈底）。
   *
   * @param uiContext 页面上下文
   * @returns true 表示发生了跳转
   */
  static backToIndex(uiContext: UIContext): boolean {
    const uiRouter = uiContext.getRouter();
    try {
      const state = uiRouter.getState();
      Log.info(TAG, `当前路由: name=${state.name} path=${state.path} index=${state.index}`);
      Log.info(TAG, `路由栈长度=${uiRouter.getLength()}`);

      // 【坑】getState().path 拿到的是**目录部分**（如 'pages/'），
      // 页面文件名要看 name —— 它才是 'Index' / 'ParkedPlace'。
      if (state.name === 'Index') {
        Log.info(TAG, '已在概览页，无需后退');
        BackgroundReset.consume();
        return false;
      }
      const indexStates = uiRouter.getStateByUrl(BackgroundReset.INDEX_URL);
      if (indexStates.length > 0) {
        // back(index) 直接跳到该位置 —— 逐层 back() 是异步的，连调多次不可靠。
        const index = indexStates[0].index;
        uiRouter.back(index);
        Log.info(TAG, `已后退到概览页（back 到 index=${index}）`);
        BackgroundReset.consume();
        return true;
      }
      // 概览页不在栈里（登录页 replaceUrl 过来的场景），
      // 清掉整个栈再重建概览页。
      uiRouter.clear();
      uiRouter.replaceUrl({ url: BackgroundReset.INDEX_URL });
      Log.info(TAG, '已清栈并重建概览页');
      BackgroundReset.consume();
      return true;
    } catch (err) {
      Log.error(TAG, `后退到概览页失败: ${(err as Error).message}`);
      return false;
    }
  }
}
