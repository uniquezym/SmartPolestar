import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { SessionState } from '../model/SessionState';
import { TokenVault } from './TokenVault';
import { Log } from '../../common/Log';

/**
 * 会话持久化 —— 对应 Android 端 ga0.m1346B / m1383p0 / m1419v。
 *
 * Android 端把加密后的 token blob 存进 SharedPreferences("session") 的 "token_blob"；
 * HarmonyOS 侧改用 Preferences 存储同一布局的密文。
 */
export class SessionStore {
  /** Preferences 存储名，与 Android 端保持同名便于对照。 */
  static readonly STORE_NAME: string = 'session';

  /** token blob 的键名。 */
  static readonly KEY_TOKEN_BLOB: string = 'token_blob';

  /** 续期失败后的重试时刻。 */
  static readonly KEY_REFRESH_RETRY_AFTER: string = 'refresh_retry_after';

  /** 上次成功刷新车辆状态的时刻（epoch millis）。对应 Android 端的 "last_refresh_at"。 */
  static readonly KEY_LAST_REFRESH_AT: string = 'last_refresh_at';

  private static store: preferences.Preferences | undefined = undefined;

  /**
   * 获取（并缓存）Preferences 实例。
   */
  static async open(context: common.UIAbilityContext): Promise<preferences.Preferences> {
    if (SessionStore.store !== undefined) {
      return SessionStore.store;
    }
    SessionStore.store = await preferences.getPreferences(context, SessionStore.STORE_NAME);
    return SessionStore.store;
  }

  /**
   * 保存会话（自动加密）。
   */
  static async save(context: common.UIAbilityContext, session: SessionState): Promise<void> {
    const store = await SessionStore.open(context);
    const plain = session.toPlaintext();
    const cipher = await TokenVault.encrypt(SessionStore.utf8(plain));
    const blob = SessionStore.base64(cipher);
    await store.put(SessionStore.KEY_TOKEN_BLOB, blob);
    await store.flush();
  }

  /**
   * 读取会话（自动解密）。
   *
   * @returns 会话；不存在或数据损坏时返回 undefined
   */
  static async load(context: common.UIAbilityContext): Promise<SessionState | undefined> {
    const store = await SessionStore.open(context);
    const blob = await store.get(SessionStore.KEY_TOKEN_BLOB, '') as string;
    if (blob.length === 0 || blob.length > 131072) {
      return undefined;
    }
    try {
      const cipher = SessionStore.base64Decode(blob);
      if (cipher.length < 28 || cipher.length > 65536) {
        return undefined;
      }
      const plain = await TokenVault.decrypt(cipher);
      const session = SessionState.fromPlaintext(SessionStore.utf8Decode(plain));
      return session;
    } catch (err) {
      Log.warn(`读取会话失败: ${(err as Error).message}`);
      return undefined;
    }
  }

  /**
   * 清空会话。对应 m1419v。
   */
  static async clear(context: common.UIAbilityContext): Promise<void> {
    const store = await SessionStore.open(context);
    await store.clear();
    await store.flush();
  }

  /**
   * 读取续期退避时刻。
   */
  static async getRefreshRetryAfter(context: common.UIAbilityContext): Promise<number> {
    const store = await SessionStore.open(context);
    return await store.get(SessionStore.KEY_REFRESH_RETRY_AFTER, 0) as number;
  }

  /**
   * 写入续期退避时刻。
   */
  static async setRefreshRetryAfter(context: common.UIAbilityContext, timestamp: number): Promise<void> {
    const store = await SessionStore.open(context);
    await store.put(SessionStore.KEY_REFRESH_RETRY_AFTER, timestamp);
    await store.flush();
  }

  /**
   * 清除续期退避时刻。
   */
  static async clearRefreshRetryAfter(context: common.UIAbilityContext): Promise<void> {
    const store = await SessionStore.open(context);
    await store.delete(SessionStore.KEY_REFRESH_RETRY_AFTER);
    await store.flush();
  }

  /**
   * 读取上次成功刷新车辆状态的时刻。
   */
  static async getLastRefreshAt(context: common.UIAbilityContext): Promise<number> {
    const store = await SessionStore.open(context);
    return await store.get(SessionStore.KEY_LAST_REFRESH_AT, 0) as number;
  }

  /**
   * 写入上次成功刷新车辆状态的时刻。
   */
  static async setLastRefreshAt(context: common.UIAbilityContext, timestamp: number): Promise<void> {
    const store = await SessionStore.open(context);
    await store.put(SessionStore.KEY_LAST_REFRESH_AT, timestamp);
    await store.flush();
  }

  // ---------------- 编解码辅助 ----------------

  private static utf8(text: string): Uint8Array {
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

  private static utf8Decode(bytes: Uint8Array): string {
    let result = '';
    let i = 0;
    while (i < bytes.length) {
      const byte = bytes[i++];
      if (byte < 0x80) {
        result += String.fromCharCode(byte);
      } else if (byte >= 0xc0 && byte < 0xe0) {
        result += String.fromCharCode(((byte & 0x1f) << 6) | (bytes[i++] & 0x3f));
      } else if (byte >= 0xe0 && byte < 0xf0) {
        const b2 = bytes[i++] & 0x3f;
        const b3 = bytes[i++] & 0x3f;
        result += String.fromCharCode(((byte & 0x0f) << 12) | (b2 << 6) | b3);
      } else {
        const b2 = bytes[i++] & 0x3f;
        const b3 = bytes[i++] & 0x3f;
        const b4 = bytes[i++] & 0x3f;
        const code = (((byte & 0x07) << 18) | (b2 << 12) | (b3 << 6) | b4) - 0x10000;
        result += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff));
      }
    }
    return result;
  }

  private static base64(bytes: Uint8Array): string {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let result = '';
    for (let i = 0; i < bytes.length; i += 3) {
      const b0 = bytes[i];
      const b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
      const b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      const n = (b0 << 16) | (b1 << 8) | b2;
      result += alphabet.charAt((n >> 18) & 63);
      result += alphabet.charAt((n >> 12) & 63);
      result += i + 1 < bytes.length ? alphabet.charAt((n >> 6) & 63) : '=';
      result += i + 2 < bytes.length ? alphabet.charAt(n & 63) : '=';
    }
    return result;
  }

  private static base64Decode(text: string): Uint8Array {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const clean = text.replace(/=+$/, '');
    const bytes: number[] = [];
    for (let i = 0; i < clean.length; i += 4) {
      const c0 = alphabet.indexOf(clean.charAt(i));
      const c1 = alphabet.indexOf(clean.charAt(i + 1));
      const c2 = i + 2 < clean.length ? alphabet.indexOf(clean.charAt(i + 2)) : -1;
      const c3 = i + 3 < clean.length ? alphabet.indexOf(clean.charAt(i + 3)) : -1;
      const n = (c0 << 18) | (c1 << 12) | ((c2 < 0 ? 0 : c2) << 6) | (c3 < 0 ? 0 : c3);
      bytes.push((n >> 16) & 255);
      if (i + 2 < clean.length) {
        bytes.push((n >> 8) & 255);
      }
      if (i + 3 < clean.length) {
        bytes.push(n & 255);
      }
    }
    return new Uint8Array(bytes);
  }
}
