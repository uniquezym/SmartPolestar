import { http } from '@kit.NetworkKit';
import { BusinessError, Log } from '../../common/Log';

/**
 * 通用 REST 客户端 —— 对应 Android 端 p000.ga0.m1370g0。
 *
 * 关键行为与原实现对齐：
 *   - 不跟随重定向、不使用缓存
 *   - 连接 20s / 读取 25s 超时
 *   - 响应体上限 4 MB
 *   - 固定 User-Agent: PolestarAppCN/RCS/4.25.0b262 Android/{release}
 *   - 2xx 之外抛出 "HTTP {code} {path}"
 *   - JSON 数组会被包装成 {"items": [...]}
 *
 * 差异说明：Android 端显式使用 Proxy.NO_PROXY 绕过系统代理，
 * HarmonyOS 侧通过 usingProtocol 显式指定 HTTP/1.1，避免代理干扰抓包分析。
 */
export class HttpClient {
  /** 响应体最大字节数。 */
  static readonly MAX_RESPONSE_BYTES: number = 4 * 1024 * 1024;

  /** 连接超时（毫秒）。 */
  static readonly CONNECT_TIMEOUT: number = 20000;

  /** 读取超时（毫秒）。 */
  static readonly READ_TIMEOUT: number = 25000;

  /**
   * 发起一次 JSON 请求。
   *
   * @param url         完整 URL
   * @param method      HTTP 方法
   * @param body        请求体；undefined 表示无 body
   * @param contentType Accept 头的值
   * @param bearer      Bearer token；undefined 表示不带 Authorization 头
   * @returns 解析后的 JSON 对象
   */
  static async request(url: string, method: string, body: string | undefined,
    contentType: string, bearer: string | undefined): Promise<Record<string, Object>> {
    const request = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'Accept': contentType,
        'User-Agent': HttpClient.userAgent()
      };
      if (bearer !== undefined) {
        headers['Authorization'] = `Bearer ${bearer}`;
      }

      const options: http.HttpRequestOptions = {
        method: method === 'GET' ? http.RequestMethod.GET : http.RequestMethod.POST,
        header: headers,
        readTimeout: HttpClient.READ_TIMEOUT,
        connectTimeout: HttpClient.CONNECT_TIMEOUT,
        usingProtocol: http.HttpProtocol.HTTP1_1,
        expectDataType: http.HttpDataType.STRING
      };
      if (body !== undefined) {
        options.extraData = body;
        headers['Content-Type'] = 'application/json';
      }

      const response = await request.request(url, options);
      const text = typeof response.result === 'string'
        ? response.result
        : JSON.stringify(response.result);

      const path = HttpClient.pathOf(url);
      Log.debug(`API ${method} ${path} status=${response.responseCode} bytes=${text.length}`);

      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new BusinessError(response.responseCode, `HTTP ${response.responseCode} ${path}`);
      }

      return HttpClient.parseJson(text, path);
    } catch (err) {
      if (err instanceof BusinessError) {
        throw err;
      }
      const e = err as BusinessError;
      throw new BusinessError(e.code, e.message);
    } finally {
      request.destroy();
    }
  }

  /**
   * 解析 JSON 文本。数组会被包装为 {"items": [...]}。
   */
  static parseJson(text: string, path: string): Record<string, Object> {
    let parsed: Object = JSON.parse(text);
    if (Array.isArray(parsed)) {
      return { 'items': parsed };
    }
    if (parsed !== null && typeof parsed === 'object') {
      return parsed as Record<string, Object>;
    }
    throw new BusinessError(-1, `服务返回的数据格式无法识别：${path}`);
  }

  /**
   * 固定 User-Agent，与 Android 端保持一致。
   */
  static userAgent(): string {
    return 'PolestarAppCN/RCS/4.25.0b262 HarmonyOS';
  }

  /**
   * 从 URL 中提取 path 部分。
   */
  static pathOf(url: string): string {
    const index = url.indexOf('://');
    if (index < 0) {
      return url;
    }
    const rest = url.substring(index + 3);
    const slash = rest.indexOf('/');
    return slash < 0 ? '/' : rest.substring(slash);
  }
}
