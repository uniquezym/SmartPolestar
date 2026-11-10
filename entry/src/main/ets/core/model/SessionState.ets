/**
 * 会话上下文 —— 对应 Android 端 p000.da0。
 *
 * 原字段映射：
 *   f1325a -> accessToken   C3 global token
 *   f1326b -> refreshToken  用于静默续期
 *   f1327c -> c3Host        主业务 gRPC 主机（服务发现得到）
 *   f1328d -> c3LbsHost     定位/空调定时 gRPC 主机
 *   f1329e -> expiresAt     access token 绝对过期时间（epoch millis）
 */
export class SessionState {
  accessToken: string = '';
  refreshToken: string = '';
  c3Host: string = '';
  c3LbsHost: string = '';
  expiresAt: number = 0;

  constructor(accessToken: string = '', refreshToken: string = '', expiresAt: number = 0) {
    this.accessToken = accessToken;
    this.refreshToken = refreshToken;
    this.expiresAt = expiresAt;
  }

  /**
   * 距过期不足 30 秒即视为需要续期（与 Android 端 needsRefresh 判定一致）。
   */
  needsRefresh(now: number): boolean {
    return this.expiresAt <= now + 30000;
  }

  /**
   * 当前 access token 是否仍然可用。
   */
  isUsable(now: number): boolean {
    return this.accessToken.length > 0 && this.expiresAt > now;
  }

  /**
   * 序列化为加密前的明文，格式为 "accessToken\nrefreshToken\nexpiresAt"。
   * 与 Android 端 m1383p0 保持一致。
   */
  toPlaintext(): string {
    return `${this.accessToken}\n${this.refreshToken}\n${this.expiresAt}`;
  }

  /**
   * 从明文反序列化。
   */
  static fromPlaintext(plain: string): SessionState | undefined {
    const parts = plain.split('\n');
    if (parts.length < 3 || parts[0].length === 0) {
      return undefined;
    }
    const expiresAt = Number.parseInt(parts[2], 10);
    if (Number.isNaN(expiresAt)) {
      return undefined;
    }
    return new SessionState(parts[0], parts[1], expiresAt);
  }
}
