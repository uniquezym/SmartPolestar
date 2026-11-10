import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '../../common/Log';

/**
 * 令牌保险箱 —— 用 HUKS AES-256-GCM 加密会话 token。
 *
 * 参考官方 HUKS 示例 https://device.harmonyos.com/cn/docs/apiref/harmonyos-guides/huks-encryption-decryption-arkts
 * （AES/GCM/NoPadding 章节），关键行为：
 *   - isKeyItemExist 密钥不存在时**抛 12000011**，不是返回 false，需 catch
 *   - generateKeyItem 只带 ALGORITHM/KEY_SIZE/PURPOSE（不带 BLOCK_MODE/PADDING）
 *   - initSession.properties 必须带 PURPOSE（ENCRYPT 或 DECRYPT 方向）
 *   - initSession.inData 必须直接放明文/密文，不能空
 *   - GCM 是单次 initSession + finishSession，不用 updateSession 分段
 *   - 加密的 finishSession.outData = 密文 || Tag；解密时 AE_TAG 放 properties
 *
 * 密文对外布局保持与 Android 端一致：IV(12B) || 密文 || GCM Tag(16B)
 */
export class TokenVault {
  /** HUKS 中的密钥别名。 */
  static readonly KEY_ALIAS: string = 'smartpolestar_tokens_v1';

  /** GCM IV 长度（字节）。 */
  private static readonly IV_LENGTH: number = 12;

  /** GCM 认证标签长度（字节）。 */
  private static readonly TAG_LENGTH: number = 16;

  /**
   * 确认密钥存在，不存在则生成。
   */
  static async ensureKey(): Promise<void> {
    let exists: boolean = false;
    try {
      exists = await huks.isKeyItemExist(TokenVault.KEY_ALIAS, {});
    } catch (err) {
      const e = err as BusinessError;
      if (e.code === 12000011) {
        exists = false;
      } else {
        throw new BusinessError(e.code, `HUKS 密钥查询失败: ${e.message}`);
      }
    }
    if (exists) {
      return;
    }
    try {
      // generateKeyItem 只带三个 tag：ALGORITHM + KEY_SIZE + PURPOSE
      // BLOCK_MODE / PADDING 属于 session 层参数，不在 generate 时指定
      const options: huks.HuksOptions = {
        properties: [
          { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
          { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
          { tag: huks.HuksTag.HUKS_TAG_PURPOSE,
            value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT |
              huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT }
        ]
      };
      await huks.generateKeyItem(TokenVault.KEY_ALIAS, options);
    } catch (err) {
      const e = err as BusinessError;
      if (e.code === 12000017) {
        return; // 并发场景下别处刚生成
      }
      throw new BusinessError(e.code, `HUKS 密钥生成失败: ${e.message}`);
    }
  }

  /**
   * 加密明文，返回 IV || 密文 || Tag。
   */
  static async encrypt(plain: Uint8Array): Promise<Uint8Array> {
    await TokenVault.ensureKey();
    try {
      const iv = await TokenVault.randomBytes(TokenVault.IV_LENGTH);

      const encryptProps: huks.HuksParam[] = [
        { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
        { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
        { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT },
        { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
        { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
        { tag: huks.HuksTag.HUKS_TAG_NONCE, value: iv }
      ];
      const options: huks.HuksOptions = {
        inData: plain,
        properties: encryptProps
      };

      const initResult = await huks.initSession(TokenVault.KEY_ALIAS, options);
      const finishResult = await huks.finishSession(initResult.handle, options);
      // finishSession.outData 已经是 密文 || Tag
      const cipherWithTag = finishResult.outData ?? new Uint8Array(0);

      const out = new Uint8Array(TokenVault.IV_LENGTH + cipherWithTag.length);
      out.set(iv, 0);
      out.set(cipherWithTag, TokenVault.IV_LENGTH);
      return out;
    } catch (err) {
      const e = err as BusinessError;
      throw new BusinessError(e.code, `加密失败: ${e.message}`);
    }
  }

  /**
   * 解密 IV || 密文 || Tag。
   */
  static async decrypt(raw: Uint8Array): Promise<Uint8Array> {
    if (raw.length < TokenVault.IV_LENGTH + TokenVault.TAG_LENGTH) {
      throw new BusinessError(-1, '密文长度非法');
    }
    const iv = raw.slice(0, TokenVault.IV_LENGTH);
    const cipher = raw.slice(TokenVault.IV_LENGTH, raw.length - TokenVault.TAG_LENGTH);
    const tag = raw.slice(raw.length - TokenVault.TAG_LENGTH);

    try {
      const decryptProps: huks.HuksParam[] = [
        { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
        { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
        { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
        { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
        { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
        { tag: huks.HuksTag.HUKS_TAG_NONCE, value: iv },
        { tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag }
      ];
      const options: huks.HuksOptions = {
        inData: cipher,
        properties: decryptProps
      };

      const initResult = await huks.initSession(TokenVault.KEY_ALIAS, options);
      const finishResult = await huks.finishSession(initResult.handle, options);
      return finishResult.outData ?? new Uint8Array(0);
    } catch (err) {
      const e = err as BusinessError;
      throw new BusinessError(e.code, `解密失败: ${e.message}`);
    }
  }

  /**
   * 生成随机字节，使用系统安全随机源。
   */
  private static async randomBytes(length: number): Promise<Uint8Array> {
    const random = cryptoFramework.createRandom();
    const result = await random.generateRandom(length);
    return new Uint8Array(result.data);
  }
}
