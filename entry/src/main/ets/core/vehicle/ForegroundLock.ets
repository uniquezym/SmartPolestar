import { BiometricGuard, BiometricResult } from './BiometricGuard';
import { Log } from '../../common/Log';

/**
 * 前台解锁守卫。
 *
 * 指纹验证的定位：**只在应用从后台切回前台时要求一次**，
 * 用于确认是机主本人在操作；一旦解锁，应用停留在前台期间的车控动作不再重复验证，
 * 避免每次点按钮都弹指纹框。
 *
 * 状态机：
 *   后台      -> locked = true（需要指纹）
 *   前台未解锁 -> locked = true
 *   指纹通过  -> locked = false（前台期间免验证）
 *   再次回后台 -> locked = true
 */
export class ForegroundLock {
  /** 是否需要指纹解锁。 */
  private static locked: boolean = false;

  /** 是否已经尝试过解锁（用于避免重复弹窗）。 */
  private static verifying: boolean = false;

  /**
   * 标记为已离开前台。下次回到前台时需要重新验证指纹。
   */
  static markBackgrounded(): void {
    ForegroundLock.locked = true;
    Log.info('应用退到后台，切回前台时需要指纹验证');
  }

  /**
   * 当前是否处于锁定状态。
   */
  static isLocked(): boolean {
    return ForegroundLock.locked;
  }

  /**
   * 标记为已解锁。
   */
  static unlock(): void {
    ForegroundLock.locked = false;
    ForegroundLock.verifying = false;
  }

  /**
   * 尝试用指纹解锁。
   *
   * 指纹不可用（未录入 / 无硬件 / 硬件异常）时不阻断流程——
   * 车控指令本身仍需服务端鉴权，这里只是「机主在场」的软性确认。
   *
   * @param title 验证弹窗标题
   * @returns 是否已解锁（true 表示可以继续；false 表示用户取消或验证失败）
   */
  static async tryUnlock(title: string): Promise<boolean> {
    if (!ForegroundLock.locked) {
      return true;
    }
    if (ForegroundLock.verifying) {
      // 已有一次验证在进行中，避免重复弹窗
      return false;
    }

    ForegroundLock.verifying = true;
    try {
      const capability = await BiometricGuard.checkAvailable();
      if (capability !== BiometricResult.SUCCESS) {
        // 没有指纹能力：直接放行，不给用户添堵
        Log.info(`指纹不可用（code=${capability}），跳过前台解锁验证`);
        ForegroundLock.unlock();
        return true;
      }

      const result = await BiometricGuard.verify(title);
      if (result === BiometricResult.SUCCESS) {
        Log.info('指纹验证通过，前台期间免重复验证');
        ForegroundLock.unlock();
        return true;
      }

      Log.warn('用户取消指纹验证，保持锁定状态');
      return false;
    } finally {
      ForegroundLock.verifying = false;
    }
  }
}
