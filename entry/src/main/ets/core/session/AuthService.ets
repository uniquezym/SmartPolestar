import { deviceInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { HttpClient } from '../net/HttpClient';
import { RequestSigner } from './RequestSigner';
import { SessionState } from '../model/SessionState';
import { SessionStore } from './SessionStore';
import { BusinessError, Log } from '../../common/Log';

/**
 * 账号登录与 token 续期 —— 对应 Android 端 p000.ga0 的
 * m1400E（密码登录）、m1412e0（刷新）。
 *
 * 接口：
 *   POST /user/api/v2/oauth/login/password
 *   POST /user/api/v2/oauth/refresh-global-token
 * 两者均通过 query string 的 sign 做防重放与设备绑定，body 仅承载业务数据。
 */
export class AuthService {
  private static readonly PATH_LOGIN: string = '/user/api/v2/oauth/login/password';
  private static readonly PATH_REFRESH: string = '/user/api/v2/oauth/refresh-global-token';

  /** 默认 token 有效期（秒）。 */
  private static readonly DEFAULT_EXPIRES_SECONDS: number = 14400;

  /** 触发续期的提前量（毫秒）。 */
  private static readonly REFRESH_MARGIN_MS: number = 30000;

  /** 瞬时失败后的最长重试延迟（毫秒）。 */
  private static readonly MAX_RETRY_DELAY_MS: number = 45000;

  /**
   * 使用手机号 + 密码登录。
   *
   * @param context  上下文（用于持久化）
   * @param phone    中国区手机号
   * @param password 密码（明文置于 JSON body，靠 TLS + 签名保护）
   * @returns 登录后的会话（已落盘）
   */
  static async login(context: common.UIAbilityContext, phone: string, password: string):
    Promise<SessionState> {
    const body = `{"clientId":"${RequestSigner.CLIENT_ID}","phone":"${phone}",` +
      `"password":"${password}","autocrt":true}`;

    const url = await RequestSigner.signedUrl(
      AuthService.PATH_LOGIN,
      AuthService.deviceId(),
      AuthService.deviceModel(),
      AuthService.brand(),
      AuthService.systemVersion());

    const response = await HttpClient.request(url, 'POST', body, 'application/json', undefined);

    const code = (response['code'] as number) ?? 200;
    if (code !== 200) {
      throw new BusinessError(code, `账号登录失败：${(response['msg'] as string) ?? '服务端拒绝请求'}`);
    }

    const data = response['data'] as Record<string, Object> | undefined;
    if (data === undefined) {
      throw new BusinessError(-1, '账号登录失败：服务端未返回数据');
    }

    const session = new SessionState();
    const token = data['globleToken'] as Record<string, Object> | undefined;
    if (token !== undefined) {
      session.accessToken = AuthService.pick(token, ['accessToken', 'access_token']);
      session.refreshToken = AuthService.pick(token, ['refreshToken', 'refresh_token']);
      const expiresIn = (token['expiresIn'] as number) ??
        ((data['expiresIn'] as number) ?? AuthService.DEFAULT_EXPIRES_SECONDS);
      session.expiresAt = expiresIn * 1000 + Date.now();
    } else {
      session.accessToken = (data['globleToken'] as string) ?? (data['globalToken'] as string) ?? '';
      session.refreshToken = AuthService.pick(data, ['refreshToken', 'refresh_token']);
      const expiresIn = (data['expiresIn'] as number) ?? AuthService.DEFAULT_EXPIRES_SECONDS;
      session.expiresAt = expiresIn * 1000 + Date.now();
    }

    if (session.accessToken.length === 0) {
      Log.error('登录成功响应中没有 C3 global token');
      throw new BusinessError(-1, '登录成功响应中没有 C3 global token');
    }

    await SessionStore.save(context, session);
    return session;
  }

  /**
   * 在需要时续期 access token。对应 ga0.m1412e0。
   *
   * @param context 上下文
   * @param session 会话（就地更新）
   * @param force   为 true 时无视过期时间强制续期
   */
  static async refreshIfNeeded(context: common.UIAbilityContext, session: SessionState,
    force: boolean): Promise<void> {
    const now = Date.now();
    if (!force && !session.needsRefresh(now)) {
      return;
    }

    // 并发保护：若其他请求已刷新过，直接复用
    if (!force) {
      const stored = await SessionStore.load(context);
      if (stored !== undefined && stored.expiresAt > now + AuthService.REFRESH_MARGIN_MS) {
        session.accessToken = stored.accessToken;
        session.refreshToken = stored.refreshToken;
        session.expiresAt = stored.expiresAt;
        Log.info('token already refreshed by another request');
        return;
      }
    }

    if (session.refreshToken.length === 0) {
      if (force || session.expiresAt <= now) {
        await SessionStore.clear(context);
        throw new BusinessError(401, '登录状态已失效，请重新登录');
      }
      Log.info('refresh token unavailable; current access token remains valid');
      return;
    }

    // 瞬时失败退避
    if (!force && session.expiresAt > now) {
      const retryAfter = await SessionStore.getRefreshRetryAfter(context);
      if (retryAfter > now) {
        Log.info('refresh deferred after transient failure while current bearer is still valid');
        return;
      }
    }

    try {
      const body = `{"refreshToken":"${session.refreshToken}"}`;
      const url = await RequestSigner.signedUrl(
        AuthService.PATH_REFRESH,
        AuthService.deviceId(),
        AuthService.deviceModel(),
        AuthService.brand(),
        AuthService.systemVersion());

      const response = await HttpClient.request(url, 'POST', body, 'application/json', undefined);
      const code = (response['code'] as number) ?? 200;
      const data = (response['data'] as Record<string, Object> | undefined) ?? response;

      if (code !== 200) {
        if (code === 400 || code === 401 || code === 403) {
          await SessionStore.clear(context);
          throw new BusinessError(code, '登录状态已失效，请重新登录');
        }
        throw new BusinessError(code, `刷新令牌请求失败（code=${code}）`);
      }

      let token = data['globleToken'] as Record<string, Object> | undefined;
      if (token === undefined) {
        token = data['globalToken'] as Record<string, Object> | undefined;
      }
      if (token === undefined) {
        token = data['global_token'] as Record<string, Object> | undefined;
      }

      let accessToken = '';
      let refreshToken = '';
      let expiresIn = 0;
      if (token !== undefined) {
        accessToken = AuthService.pick(token, ['accessToken', 'access_token', 'token']);
        refreshToken = AuthService.pick(token, ['refreshToken', 'refresh_token']);
        expiresIn = (token['expiresIn'] as number) ?? ((token['expires_in'] as number) ?? 0);
      }
      if (accessToken.length === 0) {
        accessToken = AuthService.pick(data, ['globleToken', 'globalToken', 'global_token']);
      }
      if (accessToken.length === 0) {
        accessToken = AuthService.pick(data, ['accessToken', 'access_token', 'token', 'tokenValue']);
      }
      if (refreshToken.length === 0) {
        refreshToken = AuthService.pick(data, ['refreshToken', 'refresh_token']);
      }
      if (accessToken.length === 0) {
        await SessionStore.clear(context);
        throw new BusinessError(401, '登录状态已失效，请重新登录');
      }

      session.accessToken = accessToken;
      if (refreshToken.length > 0) {
        session.refreshToken = refreshToken;
      }
      session.expiresAt = expiresIn > 0
        ? expiresIn * 1000 + Date.now()
        : Date.now() + AuthService.DEFAULT_EXPIRES_SECONDS * 1000;

      await SessionStore.clearRefreshRetryAfter(context);
      await SessionStore.save(context, session);
    } catch (err) {
      if (err instanceof BusinessError && (err.code === 400 || err.code === 401 || err.code === 403)) {
        throw err;
      }
      // 瞬时失败但当前 token 仍有效：记账后退避重试
      if (!force && session.expiresAt > Date.now()) {
        const retryAt = Math.min(session.expiresAt, Date.now() + AuthService.MAX_RETRY_DELAY_MS);
        await SessionStore.setRefreshRetryAfter(context, retryAt);
        Log.warn('refresh failed transiently; retaining still-valid bearer');
        return;
      }
      if (err instanceof Error) {
        throw err;
      }
      throw new BusinessError(-1, '刷新令牌请求失败');
    }
  }

  /**
   * 从多个候选 key 中取第一个非空值。对应 ga0.m1386r。
   */
  static pick(obj: Record<string, Object>, keys: string[]): string {
    for (const key of keys) {
      const value = obj[key] as string | undefined;
      if (value !== undefined && value.length > 0 && value.toLowerCase() !== 'null') {
        return value;
      }
    }
    return '';
  }

  /**
   * 设备标识。Android 端取 Settings.Secure android_id。
   *
   * HarmonyOS 侧使用设备的稳定标识组合（deviceType + productModel + buildVersion）。
   * 注意：deviceInfo.serial 需要 ohos.permission.sec.ACCESS_UDID 特权权限，
   * 第三方应用无法申请，故不采用。
   */
  private static deviceId(): string {
    return `harmony-${deviceInfo.deviceType}-${deviceInfo.productModel}-${deviceInfo.buildVersion}`;
  }

  /**
   * 设备型号。
   */
  private static deviceModel(): string {
    return deviceInfo.productModel.length > 0 ? deviceInfo.productModel : 'HarmonyOS';
  }

  /**
   * 设备品牌（小写）。
   */
  private static brand(): string {
    return deviceInfo.brand.length > 0 ? deviceInfo.brand.toLowerCase() : 'harmonyos';
  }

  /**
   * 系统版本。
   */
  private static systemVersion(): string {
    return deviceInfo.osFullName.length > 0 ? deviceInfo.osFullName : 'HarmonyOS';
  }
}
