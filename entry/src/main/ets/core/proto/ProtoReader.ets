/**
 * 极简 protobuf wire-format 解码器 —— 对应 Android 端 p000.ga0 的
 * m1363b0 / m1374j / m1376k / m1390t / m1391t0 / m1352I / m1372i。
 *
 * 与 Android 端一致的约定：
 *   - 仅支持 wire type 0 (varint) / 1 (64-bit) / 2 (length-delimited) / 5 (32-bit)
 *   - 字段号 0 视为非法
 *   - 不做嵌套消息自动递归，字段值按 Long 或 Uint8Array 原样保留
 */
export class ProtoReader {
  private buf: Uint8Array;
  private cursor: number = 0;

  constructor(buf: Uint8Array) {
    this.buf = buf;
  }

  /**
   * 读取一个 varint。还原自 m1363b0。
   *
   * @returns 解码出的值；数据不足时返回 0
   */
  readVarint(): number {
    let result = 0;
    let shift = 1;
    while (this.cursor < this.buf.length) {
      const byte = this.buf[this.cursor++];
      result += (byte & 0x7f) * shift;
      if ((byte & 0x80) === 0) {
        return result;
      }
      shift *= 128;
      if (shift > 0x100000000000000) {
        break;
      }
    }
    return result;
  }

  /**
   * 边界检查，越界即视为截断。还原自 m1371h0。
   */
  private requireBytes(count: number): void {
    if (count < 0 || this.cursor > this.buf.length - count) {
      throw new Error('truncated protobuf response');
    }
  }

  /**
   * 解码为「字段号 -> 值」映射（重复字段取最后一个）。还原自 m1374j。
   */
  decode(): Map<number, number | Uint8Array> {
    const fields = new Map<number, number | Uint8Array>();
    while (this.cursor < this.buf.length) {
      const tag = this.readVarint();
      const fieldNumber = Math.floor(tag / 8);
      const wireType = tag % 8;
      if (fieldNumber <= 0) {
        throw new Error('invalid protobuf field number');
      }
      let value: number | Uint8Array;
      switch (wireType) {
        case 0:
          value = this.readVarint();
          break;
        case 1:
          this.requireBytes(8);
          value = this.buf.slice(this.cursor, this.cursor + 8);
          this.cursor += 8;
          break;
        case 2: {
          const len = this.readVarint();
          if (len > 2147483647) {
            throw new Error('protobuf field too large');
          }
          this.requireBytes(len);
          value = this.buf.slice(this.cursor, this.cursor + len);
          this.cursor += len;
          break;
        }
        case 5:
          this.requireBytes(4);
          value = this.buf.slice(this.cursor, this.cursor + 4);
          this.cursor += 4;
          break;
        default:
          throw new Error(`protobuf wire type ${wireType}`);
      }
      fields.set(fieldNumber, value);
    }
    return fields;
  }

  /**
   * 解码为「字段号 -> 值列表」映射（保留重复字段）。还原自 m1376k。
   */
  decodeAll(): Map<number, (number | Uint8Array)[]> {
    const fields = new Map<number, (number | Uint8Array)[]>();
    while (this.cursor < this.buf.length) {
      const tag = this.readVarint();
      const fieldNumber = Math.floor(tag / 8);
      const wireType = tag % 8;
      if (fieldNumber <= 0) {
        throw new Error('invalid protobuf field');
      }
      let value: number | Uint8Array;
      switch (wireType) {
        case 0:
          value = this.readVarint();
          break;
        case 1:
          this.requireBytes(8);
          value = this.buf.slice(this.cursor, this.cursor + 8);
          this.cursor += 8;
          break;
        case 2: {
          const len = this.readVarint();
          if (len > 2147483647) {
            throw new Error('protobuf field too large');
          }
          this.requireBytes(len);
          value = this.buf.slice(this.cursor, this.cursor + len);
          this.cursor += len;
          break;
        }
        case 5:
          this.requireBytes(4);
          value = this.buf.slice(this.cursor, this.cursor + 4);
          this.cursor += 4;
          break;
        default:
          throw new Error(`protobuf wire type ${wireType}`);
      }
      const list = fields.get(fieldNumber);
      if (list === undefined) {
        fields.set(fieldNumber, [value]);
      } else {
        list.push(value);
      }
    }
    return fields;
  }
}

/**
 * protobuf 取值辅助方法集合 —— 对应 Android 端 ga0 的静态辅助方法。
 */
export class ProtoValue {
  /**
   * 取单值字段（重复字段取最后一个）。还原自 m1349F 的取值语义。
   */
  static get(fields: Map<number, number | Uint8Array>, fieldNumber: number):
    number | Uint8Array | undefined {
    if (fields === undefined) {
      return undefined;
    }
    return fields.get(fieldNumber);
  }

  /**
   * 取单值字段的第一个元素。还原自 m1390t。
   */
  static first(fields: Map<number, (number | Uint8Array)[]>, fieldNumber: number):
    number | Uint8Array | undefined {
    const list = fields.get(fieldNumber);
    if (list === undefined || list.length === 0) {
      return undefined;
    }
    return list[0];
  }

  /**
   * 把字节数组按 UTF-8 解码，非字节数组返回空串。还原自 m1391t0。
   */
  static decodeString(value: number | Uint8Array | undefined): string {
    if (value instanceof Uint8Array) {
      return ProtoReaderDecode.utf8Decode(value);
    }
    return '';
  }

  /**
   * 按小端序把 4 字节解释为 float。还原自 m1352I / m1372i 的 float 分支。
   */
  static asFloat(value: number | Uint8Array | undefined): number {
    if (value instanceof Uint8Array) {
      if (value.length === 4) {
        return new DataView(value.buffer, value.byteOffset, 4).getFloat32(0, true);
      }
      return NaN;
    }
    if (typeof value === 'number') {
      return value;
    }
    return NaN;
  }

  /**
   * 按小端序把 8 字节解释为 double。还原自 m1372i 的 double 分支。
   */
  static asDouble(value: number | Uint8Array | undefined): number {
    if (value instanceof Uint8Array) {
      if (value.length === 8) {
        return new DataView(value.buffer, value.byteOffset, 8).getFloat64(0, true);
      }
      return NaN;
    }
    if (typeof value === 'number') {
      return value;
    }
    return NaN;
  }

  /**
   * 读取整数，兼容 Number / 4 字节 float / 8 字节 double。还原自 m1352I。
   */
  static asInteger(value: number | Uint8Array | undefined): number | undefined {
    if (typeof value === 'number') {
      return Math.trunc(value);
    }
    if (value instanceof Uint8Array) {
      if (value.length === 4) {
        return Math.trunc(new DataView(value.buffer, value.byteOffset, 4).getFloat32(0, true));
      }
      if (value.length === 8) {
        return Math.trunc(new DataView(value.buffer, value.byteOffset, 8).getFloat64(0, true));
      }
    }
    return undefined;
  }

  /**
   * 读取浮点数，NaN / Infinity 视为无效。还原自 m1384q。
   */
  static asFiniteDouble(value: number | Uint8Array | undefined): number | undefined {
    const d = ProtoValue.asDouble(value);
    if (Number.isNaN(d) || !Number.isFinite(d)) {
      return undefined;
    }
    return d;
  }

  /**
   * 读取浮点数，兼容 4 字节 float 与 8 字节 double。
   *
   * 还原自 m1372i：既接受 wire type 1（8 字节 double），
   * 也接受 wire type 5（4 字节 float）。经纬度就是用 float 编码的，
   * 只认 8 字节会把它们全部读成 NaN。
   */
  static asFiniteNumber(value: number | Uint8Array | undefined): number | undefined {
    if (typeof value === 'number') {
      return Number.isFinite(value) ? value : undefined;
    }
    if (value instanceof Uint8Array) {
      let d = NaN;
      if (value.length === 8) {
        d = new DataView(value.buffer, value.byteOffset, 8).getFloat64(0, true);
      } else if (value.length === 4) {
        d = new DataView(value.buffer, value.byteOffset, 4).getFloat32(0, true);
      }
      if (!Number.isNaN(d) && Number.isFinite(d)) {
        return d;
      }
    }
    return undefined;
  }

  /**
   * 读取非负浮点数，负值返回 undefined。还原自 m1350G。
   *
   * m1350G 内部走 m1384q → m1372i，因此同样要兼容 4 字节 float。
   */
  static asNonNegative(value: number | Uint8Array | undefined): number | undefined {
    const d = ProtoValue.asFiniteNumber(value);
    if (d === undefined || d < 0) {
      return undefined;
    }
    return d;
  }
}

/**
 * UTF-8 解码辅助。
 */
class ProtoReaderDecode {
  static utf8Decode(bytes: Uint8Array): string {
    let result = '';
    let i = 0;
    while (i < bytes.length) {
      const byte = bytes[i++];
      if (byte < 0x80) {
        result += String.fromCharCode(byte);
      } else if (byte >= 0xc0 && byte < 0xe0) {
        const b2 = bytes[i++] & 0x3f;
        result += String.fromCharCode(((byte & 0x1f) << 6) | b2);
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
}
