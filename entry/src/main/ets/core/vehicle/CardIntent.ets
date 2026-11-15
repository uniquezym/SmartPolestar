/**
 * 卡片控制项的中转通道。
 *
 * 卡片上的按钮通过 postCardAction 的 router 事件把控制项带进主应用，
 * 但 `windowStage.loadContent` 没有路由 params 重载，
 * `router.pushUrl` 的 params 又只在 push 场景可用 ——
 * 因此统一用这个进程内持有者传递，单一数据源，不依赖路由参数。
 *
 * 生命周期：
 *   - EntryAbility 解析 want 后调用 `set()`
 *   - CardControl 页在 aboutToAppear 调用 `take()` 读取并清空
 */
export class CardIntent {
  /** 待处理的控制项：lock / climate；空串表示没有卡片请求。 */
  private static pending: string = '';

  /**
   * 写入待处理的控制项。
   *
   * @param control 控制项（lock / climate）
   */
  static set(control: string): void {
    CardIntent.pending = control;
  }

  /**
   * 读取并清空待处理的控制项。
   *
   * @returns 控制项；没有待处理请求时返回空串
   */
  static take(): string {
    const control = CardIntent.pending;
    CardIntent.pending = '';
    return control;
  }

  /**
   * 查看待处理的控制项但不清空。
   */
  static peek(): string {
    return CardIntent.pending;
  }
}
