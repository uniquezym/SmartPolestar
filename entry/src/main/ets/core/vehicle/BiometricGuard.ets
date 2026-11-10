import { userAuth } from '@kit.UserAuthenticationKit';
import { BusinessError, Log } from '../../common/Log';

/**
 * 生物识别验证结果码。
 *
 * 对应 Android 端 androidx.biometric 的错误码语义，用于决定降级策略：
 *   11 -> 未录入指纹
 *   12 -> 无指纹硬件
 *    1 -> 指纹硬件当前不可用
 */
export enum BiometricResult {
  /** 验证通过。 */
  SUCCESS = 0,
  /** 未录入生物特征。 */
  NOT_ENROLLED = 11,
  /** 设备无生物特征硬件。 */
  NO_HARDWARE = 12,
  /** 硬件当前不可用。 */
  UNAVAILABLE = 1,
  /** 用户取消。 */
  CANCELLED = 13,
  /** 其他失败。 */
  FAILED = -1
}

/**
 * 生物识别验证 —— 对应 Android 端 androidx.biometric 的封装
 * （WidgetControlActivity 的 C0126d5.m960f 与 C0353jd 弹窗）。
 */
export class BiometricGuard {
  /**
   * 检查生物特征是否可用。
   *
   * @returns 可用返回 BiometricResult.SUCCESS，否则返回具体原因码
   */
  static async checkAvailable(): Promise<number> {
    try {
      const state = await userAuth.getEnrolledState(userAuth.UserAuthType.FINGERPRINT);
      // credentialCount > 0 表示已录入生物特征
      if (state.credentialCount > 0) {
        return BiometricResult.SUCCESS;
      }
      return BiometricResult.NOT_ENROLLED;
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`检查生物特征可用性失败: code=${e.code} ${e.message}`);
      if (e.code === 12500010) {
        // 该类型尚未录入
        return BiometricResult.NOT_ENROLLED;
      }
      if (e.code === 12500005) {
        // 该认证类型不受支持
        return BiometricResult.NO_HARDWARE;
      }
      if (e.code === 201) {
        // 缺少 ACCESS_BIOMETRIC 权限
        return BiometricResult.NO_HARDWARE;
      }
      return BiometricResult.UNAVAILABLE;
    }
  }

  /**
   * 创建验证实例。
   *
   * @param title 验证弹窗标题
   * @returns 实例；创建失败返回 undefined
   */
  static createInstance(title: string): userAuth.UserAuthInstance | undefined {
    try {
      // challenge 用于防止重放攻击，长度不超过 32 字节
      const challenge = new Uint8Array(32);
      for (let i = 0; i < challenge.length; i++) {
        challenge[i] = Math.floor(Math.random() * 256);
      }
      const authParam: userAuth.AuthParam = {
        challenge: challenge,
        authType: [userAuth.UserAuthType.FINGERPRINT],
        authTrustLevel: userAuth.AuthTrustLevel.ATL2
      };
      const widgetParam: userAuth.WidgetParam = {
        title: title
      };
      return userAuth.getUserAuthInstance(authParam, widgetParam);
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`创建生物识别实例失败: code=${e.code} ${e.message}`);
      return undefined;
    }
  }

  /**
   * 发起生物特征验证并等待结果。
   *
   * @param title 验证弹窗标题
   * @returns 验证结果码
   */
  static async verify(title: string): Promise<number> {
    const instance = BiometricGuard.createInstance(title);
    if (instance === undefined) {
      return BiometricResult.FAILED;
    }
    return await new Promise<number>((resolve) => {
      try {
        const callback: userAuth.IAuthCallback = {
          onResult: (result: userAuth.UserAuthResult) => {
            instance.off('result', callback);
            resolve(result.result === userAuth.UserAuthResultCode.SUCCESS ?
              BiometricResult.SUCCESS : BiometricResult.CANCELLED);
          }
        };
        instance.on('result', callback);
        instance.start();
      } catch (err) {
        const e = err as BusinessError;
        Log.warn(`生物识别验证异常: code=${e.code} ${e.message}`);
        resolve(BiometricResult.FAILED);
      }
    });
  }

  /**
   * 指纹不可用时的降级提示文案。对应 Android 端 WidgetControlActivity.m485p。
   */
  static fallbackMessage(capability: number): string {
    if (capability === BiometricResult.NOT_ENROLLED) {
      return '此设备尚未录入可用的指纹。';
    }
    if (capability === BiometricResult.NO_HARDWARE) {
      return '此设备没有可用的指纹验证硬件。';
    }
    if (capability === BiometricResult.UNAVAILABLE) {
      return '此设备的指纹硬件当前不可用。';
    }
    return '指纹验证暂不可用，请稍后重试；未发送车辆指令';
  }
}
