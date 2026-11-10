import { cryptoFramework } from '@kit.CryptoArchitectureKit';

/**
 * 网关请求签名 —— 对应 Android 端 p000.ga0.m1401M。
 *
 * 协议要点（与官方 App 一致）：
 *   1. 组装 9 个业务参数：appId / timestamp / nonce / deviceId / deviceModel /
 *      brand / clientType / systemVer / appVer
 *   2. 按 key 字典序排序，URL-encode 后拼成 canonical string（k=v&k=v）
 *   3. sign = MD5(SECRET + canonical + SECRET)，输出小写 hex
 *   4. sign 连同原参数一起拼成最终 query string
 *
 * 注意：这里用的是裸 MD5 而非 HMAC，密钥硬编码在客户端，属于弱方案。
 * 此处严格复刻原实现以保证服务端验签通过。
 */
export class RequestSigner {
  /** 签名密钥（双侧拼接）。 */
  private static readonly SECRET: string = '385798256D8247E9B7E2E93BF2741517';

  static readonly APP_ID: string = 'polestar-app-android';
  static readonly APP_VERSION: string = '4.25.0';
  static readonly CLIENT_ID: string = 'polestar-app-android';

  /** 参与签名的参数键，按字典序排序后的顺序即为 canonical 顺序。 */
  static readonly SIGNED_KEYS: string[] = [
    'appId', 'appVer', 'brand', 'clientType', 'deviceId', 'deviceModel', 'nonce', 'systemVer', 'timestamp'
  ];

  /**
   * 计算 sign。
   *
   * @param params 参与签名的参数（须含全部 9 项）
   * @returns 32 位小写 hex
   */
  static async sign(params: Map<string, string>): Promise<string> {
    const keys = Array.from(params.keys()).sort();
    const parts: string[] = [];
    for (const key of keys) {
      parts.push(`${RequestSigner.urlEncode(key)}=${RequestSigner.urlEncode(params.get(key) as string)}`);
    }
    const canonical = parts.join('&');
    const payload = `${RequestSigner.SECRET}${canonical}${RequestSigner.SECRET}`;
    return await RequestSigner.md5Hex(payload);
  }

  /**
   * 生成带签名的网关 URL。
   *
   * @param path      网关路径，如 "/user/api/v2/oauth/login/password"
   * @param deviceId  设备标识（Android 端取 Settings.Secure android_id）
   * @param deviceModel 设备型号
   * @param brand     设备品牌（小写）
   * @param systemVer 系统版本
   * @returns 完整 URL（含 query string）
   */
  static async signedUrl(path: string, deviceId: string, deviceModel: string, brand: string,
    systemVer: string): Promise<string> {
    const params = new Map<string, string>();
    params.set('appId', RequestSigner.APP_ID);
    params.set('timestamp', Date.now().toString());
    params.set('nonce', RequestSigner.uuid());
    params.set('deviceId', deviceId);
    params.set('deviceModel', deviceModel);
    params.set('brand', brand.toLowerCase());
    params.set('clientType', 'PHONE');
    params.set('systemVer', systemVer);
    params.set('appVer', RequestSigner.APP_VERSION);

    const sign = await RequestSigner.sign(params);
    params.set('sign', sign);

    // 最终 query 按插入序拼接（sign 位于末尾）
    const queryParts: string[] = [];
    params.forEach((value, key) => {
      queryParts.push(`${RequestSigner.urlEncode(key)}=${RequestSigner.urlEncode(value)}`);
    });
    return `https://gw.app.polestar-auto.com${path}?${queryParts.join('&')}`;
  }

  /**
   * URL 编码，并把 "+" 换回 "%20"、"%7E" 换回 "~"。
   *
   * 对应 Android 端 m1375j0：
   *   URLEncoder.encode(str, "UTF-8").replace("+", "%20").replace("%7E", "~")
   */
  static urlEncode(value: string): string {
    return RequestSigner.javaUrlEncode(value)
      .replace(/\+/g, '%20')
      .replace(/%7E/g, '~');
  }

  /**
   * 复刻 java.net.URLEncoder.encode(s, "UTF-8") 的行为。
   *
   * 差异点：
   *   - 空格编码为 '+'（随后由上层替换为 %20）
   *   - 未编码字符集为 A-Za-z0-9 以及 .-*_
   *   - 其余字节按 UTF-8 逐字节百分号编码
   */
  private static javaUrlEncode(value: string): string {
    const safe = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-*_';
    const bytes = RequestSigner.utf8Bytes(value);
    let result = '';
    for (const byte of bytes) {
      const ch = String.fromCharCode(byte);
      if (safe.indexOf(ch) >= 0) {
        result += ch;
      } else if (ch === ' ') {
        result += '+';
      } else {
        const hex = byte.toString(16).toUpperCase();
        result += '%' + (hex.length === 1 ? '0' + hex : hex);
      }
    }
    return result;
  }

  /**
   * UTF-8 编码为字节数组。
   */
  static utf8Bytes(text: string): Uint8Array {
    const out: number[] = [];
    for (let i = 0; i < text.length; i++) {
      let code = text.charCodeAt(i);
      if (code >= 0xd800 && code <= 0xdbff && i + 1 < text.length) {
        const next = text.charCodeAt(i + 1);
        if (next >= 0xdc00 && next <= 0xdfff) {
          code = 0x10000 + ((code - 0xd800) << 10) + (next - 0xdc00);
          i++;
        }
      }
      if (code < 0x80) {
        out.push(code);
      } else if (code < 0x800) {
        out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
      } else if (code < 0x10000) {
        out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      } else {
        out.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f),
          0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
      }
    }
    return new Uint8Array(out);
  }

  /**
   * MD5 摘要，输出 32 位小写 hex。
   *
   * 使用系统 cryptoFramework，与 Java 的 MessageDigest.getInstance("MD5") 结果一致。
   */
  static async md5Hex(text: string): Promise<string> {
    const md = cryptoFramework.createMd('MD5');
    const data: cryptoFramework.DataBlob = { data: RequestSigner.utf8Bytes(text) };
    await md.update(data);
    const digest = await md.digest();
    return RequestSigner.toHex(digest.data);
  }

  /**
   * 字节数组转小写 hex。
   */
  static toHex(bytes: Uint8Array): string {
    let result = '';
    for (const byte of bytes) {
      const hex = byte.toString(16);
      result += hex.length === 1 ? '0' + hex : hex;
    }
    return result;
  }

  /**
   * 生成 UUID v4。
   */
  static uuid(): string {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      const v = c === 'x' ? r : (r & 0x3 | 0x8);
      return v.toString(16);
    });
  }
}
