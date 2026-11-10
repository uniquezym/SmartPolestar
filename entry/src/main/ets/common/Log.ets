import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 统一日志出口。
 *
 * 与 Android 端保持一致的 Tag 前缀（"PolestarCompanion"），
 * 便于移植后与原版日志对照排查。
 */
export class Log {
  private static readonly DOMAIN: number = 0x0000;
  private static readonly TAG: string = 'PolestarCompanion';

  static debug(message: string): void {
    hilog.debug(Log.DOMAIN, Log.TAG, '%{public}s', message);
  }

  static info(message: string): void {
    hilog.info(Log.DOMAIN, Log.TAG, '%{public}s', message);
  }

  static warn(message: string): void {
    hilog.warn(Log.DOMAIN, Log.TAG, '%{public}s', message);
  }

  static error(message: string): void {
    hilog.error(Log.DOMAIN, Log.TAG, '%{public}s', message);
  }

  /**
   * 打印异常信息，保留原始错误码与消息。
   */
  static errorWith(where: string, err: BusinessError): void {
    hilog.error(Log.DOMAIN, Log.TAG, '%{public}s failed: code=%{public}d message=%{public}s',
      where, err.code, err.message);
  }

  /**
   * 仅打印 VIN 后 6 位，与 Android 端 m1393u0 的脱敏策略一致。
   */
  static mask(vin: string | undefined): string {
    if (vin === undefined || vin.length < 6) {
      return '******';
    }
    return vin.substring(vin.length - 6);
  }
}

/**
 * 业务异常，携带 code 与 message，便于上层区分错误类型。
 */
export class BusinessError extends Error {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.code = code;
    this.name = 'BusinessError';
  }
}
