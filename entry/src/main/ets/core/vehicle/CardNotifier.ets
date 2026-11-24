import { notificationManager } from '@kit.NotificationKit';
import { Log } from '../../common/Log';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'CardNotifier';

/**
 * 卡片车控结果的通知栏提示。
 *
 * 卡片进程弹不了 Toast —— 它没有 UI 上下文，
 * 因此结果只能通过通知栏告知用户。
 *
 * 用固定的通知 id：同一 id 重复发布是「更新」而不是「新增」，
 * 不会在通知栏里堆出一串历史消息。
 */
export class CardNotifier {
  /** 通知的固定 id —— 同一个 id 的发布会互相覆盖。 */
  static readonly NOTIFICATION_ID: number = 2101;

  /** 通知槽位是否已创建过。 */
  private static slotReady: boolean = false;

  /**
   * 发布一条通知。
   *
   * 通知开关被用户关掉时（1600004）不算错误 —— 操作结果本来就会写在卡片上，
   * 通知只是额外补充，用户不想收就别打扰他。
   *
   * @param title 标题
   * @param text  正文
   */
  static async publish(title: string, text: string): Promise<void> {
    try {
      await CardNotifier.ensureSlot();
      const request: notificationManager.NotificationRequest = {
        id: CardNotifier.NOTIFICATION_ID,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: title,
            text: text
          }
        }
      };
      await notificationManager.publish(request);
      Log.info(TAG, `已发布通知: ${title} ${text}`);
    } catch (err) {
      const e = err as BusinessError;
      if (e.code === 1600004) {
        // 通知总开关关闭 —— 结果已写在卡片上，这里安静跳过。
        Log.info(TAG, `通知开关已关闭，跳过通知: ${title}`);
        return;
      }
      Log.warn(TAG, `发布通知失败 code=${e.code} ${e.message}`);
    }
  }

  /**
   * 确保通知槽位存在。
   *
   * 槽位不存在时发布会失败（20101 之类），先建一次再建。
   * 建槽位失败不阻断发布 —— 某些系统版本会自动创建默认槽位。
   */
  private static async ensureSlot(): Promise<void> {
    if (CardNotifier.slotReady) {
      return;
    }
    try {
      await notificationManager.addSlot(notificationManager.SlotType.SERVICE_INFORMATION);
      CardNotifier.slotReady = true;
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(TAG, `创建通知槽位失败 code=${e.code} ${e.message}`);
    }
  }
}
