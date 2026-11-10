/**
 * 极简 protobuf wire-format 编码器 —— 对应 Android 端 p000.ga0 的
 * m1369g / m1364c / m1394v0 / m1395w0 / m1389s0。
 *
 * Android 端本就是手写 wire-format 而非使用 protobuf 运行时，
 * 这里逐字节对齐其行为，确保同一份消息在两端产生完全相同的字节序列。
 */
export class ProtoWriter {
  private chunks: Uint8Array[] = [];
  private total: number = 0;

  /**
   * 拼接多个字节片段。还原自 m1369g。
   */
  static concat(...parts: Uint8Array[]): Uint8Array {
    let total = 0;
    for (const part of parts) {
      total += part.length;
    }
    const out = new Uint8Array(total);
    let offset = 0;
    for (const part of parts) {
      out.set(part, offset);
      offset += part.length;
    }
    return out;
  }

  /**
   * 写入一个 varint。还原自 m1394v0。
   *
   * 注意：Android 端使用有符号右移 `>>>`，对超过 2^53 的值会有差异，
   * 但 protobuf varint 均为非负且不超过 2^53，实际无影响。
   */
  static writeVarint(value: number): Uint8Array {
    // 用数组承载，避免 JS 位运算的 32 位截断
    const bytes: number[] = [];
    let v = value;
    while (v > 0x7f) {
      bytes.push((v & 0x7f) | 0x80);
      v = Math.floor(v / 128);
    }
    bytes.push(v);
    return new Uint8Array(bytes);
  }

  /**
   * 写入一个 varint 类型的 protobuf 字段。还原自 m1395w0。
   */
  static writeVarintField(fieldNumber: number, value: number): Uint8Array {
    return ProtoWriter.concat(
      ProtoWriter.writeVarint(fieldNumber * 8),
      ProtoWriter.writeVarint(value)
    );
  }

  /**
   * 写入一个 length-delimited 类型的 protobuf 字段。还原自 m1364c。
   */
  static writeBytesField(fieldNumber: number, payload: Uint8Array): Uint8Array {
    return ProtoWriter.concat(
      ProtoWriter.writeVarint(fieldNumber * 8 + 2),
      ProtoWriter.writeVarint(payload.length),
      payload
    );
  }

  /**
   * 写入一个字符串类型的 protobuf 字段。还原自 m1389s0。
   */
  static writeStringField(fieldNumber: number, value: string): Uint8Array {
    return ProtoWriter.writeBytesField(fieldNumber, ProtoWriter.encodeUtf8(value));
  }

  /**
   * 写入一个 fixed32 (wire type 5) 字段。
   * 用于空调启动时的目标温度 22.0f（field 3）。
   */
  static writeFixed32Field(fieldNumber: number, value: number): Uint8Array {
    const buf = new ArrayBuffer(4);
    new DataView(buf).setFloat32(0, value, true);
    return ProtoWriter.concat(
      ProtoWriter.writeVarint(fieldNumber * 8 + 5),
      new Uint8Array(buf)
    );
  }

  /**
   * UTF-8 编码。
   */
  static encodeUtf8(text: string): Uint8Array {
    const out: number[] = [];
    for (let i = 0; i < text.length; i++) {
      let code = text.charCodeAt(i);
      // 代理对处理
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
        out.push(
          0xf0 | (code >> 18),
          0x80 | ((code >> 12) & 0x3f),
          0x80 | ((code >> 6) & 0x3f),
          0x80 | (code & 0x3f)
        );
      }
    }
    return new Uint8Array(out);
  }

  /**
   * 追加任意字节。
   */
  write(chunk: Uint8Array): void {
    this.chunks.push(chunk);
    this.total += chunk.length;
  }

  /**
   * 追加 varint 字段。
   */
  writeVarintField(fieldNumber: number, value: number): void {
    this.write(ProtoWriter.writeVarintField(fieldNumber, value));
  }

  /**
   * 追加字符串字段。
   */
  writeStringField(fieldNumber: number, value: string): void {
    this.write(ProtoWriter.writeStringField(fieldNumber, value));
  }

  /**
   * 追加 length-delimited 字段。
   */
  writeBytesField(fieldNumber: number, payload: Uint8Array): void {
    this.write(ProtoWriter.writeBytesField(fieldNumber, payload));
  }

  /**
   * 追加 fixed32 字段。
   */
  writeFixed32Field(fieldNumber: number, value: number): void {
    this.write(ProtoWriter.writeFixed32Field(fieldNumber, value));
  }

  /**
   * 输出最终字节序列。
   */
  toUint8Array(): Uint8Array {
    const out = new Uint8Array(this.total);
    let offset = 0;
    for (const chunk of this.chunks) {
      out.set(chunk, offset);
      offset += chunk.length;
    }
    return out;
  }
}
