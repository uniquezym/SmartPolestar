import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 统一日志出口。
 *
 * 【Tag 约定】每个文件在自己的模块顶层定义一个 TAG 常量，值就是文件名
 * （如 Index.ets 里是 `const TAG: string = 'Index'`），调用时传进去。
 * 这样日志里能直接看出是哪个文件打的，过滤时按 Tag 筛即可。
 */
export class Log {
  /** 日志域，全应用统一。 */
  static readonly DOMAIN: number = 0x0000;

  static debug(tag: string, message: string): void {
    hilog.debug(Log.DOMAIN, tag, '%{public}s', message);
  }

  static info(tag: string, message: string): void {
    hilog.info(Log.DOMAIN, tag, '%{public}s', message);
  }

  static warn(tag: string, message: string): void {
    hilog.warn(Log.DOMAIN, tag, '%{public}s', message);
  }

  static error(tag: string, message: string): void {
    hilog.error(Log.DOMAIN, tag, '%{public}s', message);
  }

  /**
   * 打印异常信息，保留原始错误码与消息。
   */
  static errorWith(tag: string, where: string, err: BusinessError): void {
    hilog.error(Log.DOMAIN, tag, '%{public}s failed: code=%{public}d message=%{public}s',
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
