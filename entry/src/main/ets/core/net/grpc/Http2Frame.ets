/**
 * HTTP/2 帧编解码 —— gRPC 传输层的底层。
 *
 * 只实现 gRPC 所需子集：
 *   - 帧类型：DATA(0)、HEADERS(1)、RST_STREAM(3)、PING(6)、GOAWAY(7)、WINDOW_UPDATE(8)、SETTINGS(4)
 *   - HPACK：仅支持"静态表索引 + 字面量（不做 Huffman 编码）"两种表示
 *   - 不做 HPACK 动态表维护（服务端 metadata 数量固定且极少）
 *
 * 参考：RFC 7540（HTTP/2）、RFC 7541（HPACK）、RFC 9113（gRPC over HTTP/2）
 */

/** HTTP/2 帧类型。 */
export enum FrameType {
  DATA = 0x00,
  HEADERS = 0x01,
  PRIORITY = 0x02,
  RST_STREAM = 0x03,
  SETTINGS = 0x04,
  PUSH_PROMISE = 0x05,
  PING = 0x06,
  GOAWAY = 0x07,
  WINDOW_UPDATE = 0x08,
  CONTINUATION = 0x09
}

/** HTTP/2 帧标志位。 */
export enum FrameFlag {
  END_STREAM = 0x01,
  END_HEADERS = 0x04,
  PADDED = 0x08,
  PRIORITY = 0x20
}

/** HPACK 索引表示形式。 */
export enum HpackIndexType {
  /** 静态表索引（1xxxxxxx）。 */
  STATIC = 1,
  /** 带字面量索引（01xxxxxx）。 */
  LITERAL_WITH_INDEX = 2,
  /** 不带字面量索引（0000xxxx）。 */
  LITERAL_WITHOUT_INDEX = 3,
  /** 动态表索引（1xxxxxxx）。 */
  DYNAMIC = 4
}

/**
 * HTTP/2 header 字段。
 *
 * ArkTS 不允许用对象字面量作为类型声明，必须显式定义接口。
 */
export interface HttpHeader {
  name: string;
  value: string;
}

/**
 * 帧解码结果。
 */
export interface FrameDecodeResult {
  frame: Http2FrameInfo;
  consumed: number;
}

/**
 * HPACK 解码结果。
 */
export interface HpackDecodeResult {
  headers: HttpHeader[];
  consumed: number;
}

/**
 * 字符串字面量解码结果。
 */
export interface LiteralDecodeResult {
  value: string;
  next: number;
}

/**
 * HPACK 整数解码结果。
 */
export interface IntegerDecodeResult {
  value: number;
  next: number;
}

/**
 * Huffman 码字。
 */
export interface HuffmanCode {
  /** 码长（位）。 */
  length: number;
  /** 码值。 */
  code: number;
}

/**
 * HTTP/2 帧头（9 字节）。
 */
export class FrameHeader {
  length: number = 0;
  type: number = 0;
  flags: number = 0;
  streamId: number = 0;

  constructor(length: number = 0, type: number = 0, flags: number = 0, streamId: number = 0) {
    this.length = length;
    this.type = type;
    this.flags = flags;
    this.streamId = streamId;
  }
}

/**
 * HTTP/2 帧数据。
 *
 * 与静态工具类 Http2Frame 分离，避免同名冲突。
 */
export class Http2FrameInfo {
  header: FrameHeader = new FrameHeader();
  payload: Uint8Array = new Uint8Array(0);

  constructor(type: number, flags: number, streamId: number, payload?: Uint8Array) {
    this.header = new FrameHeader(payload ? payload.length : 0, type, flags, streamId);
    this.payload = payload ?? new Uint8Array(0);
  }
}

/**
 * HPACK 静态表（RFC 7541 附录 A）。
 * 索引 1..61 为静态表，索引 0 保留。
 */
const STATIC_TABLE: string[] = [
  '', // 0 保留
  ':authority', // 1,
  ':method: GET', // 2,
  ':method: POST', // 3,
  ':path: /', // 4,
  ':path: /index.html', // 5,
  ':scheme: http', // 6,
  ':scheme: https', // 7,
  ':status: 200', // 8,
  ':status: 204', // 9,
  ':status: 206', // 10,
  ':status: 304', // 11,
  ':status: 400', // 12,
  ':status: 404', // 13,
  ':status: 500', // 14,
  'accept-charset', // 15,
  'accept-encoding: gzip, deflate', // 16,
  'accept-language', // 17,
  'accept-ranges', // 18,
  'accept', // 19,
  'access-control-allow-origin', // 20,
  'age', // 21,
  'allow', // 22,
  'authorization', // 23,
  'cache-control', // 24,
  'content-disposition', // 25,
  'content-encoding', // 26,
  'content-language', // 27,
  'content-length', // 28,
  'content-location', // 29,
  'content-range', // 30,
  'content-type', // 31,
  'cookie', // 32,
  'date', // 33,
  'etag', // 34,
  'expect', // 35,
  'expires', // 36,
  'from', // 37,
  'host', // 38,
  'if-match', // 39,
  'if-modified-since', // 40,
  'if-none-match', // 41,
  'if-range', // 42,
  'if-unmodified-since', // 43,
  'last-modified', // 44,
  'link', // 45,
  'location', // 46,
  'max-forwards', // 47,
  'proxy-authenticate', // 48,
  'proxy-authorization', // 49,
  'range', // 50,
  'referer', // 51,
  'refresh', // 52,
  'retry-after', // 53,
  'server', // 54,
  'set-cookie', // 55,
  'strict-transport-security', // 56,
  'transfer-encoding', // 57,
  'user-agent', // 58,
  'vary', // 59,
  'via', // 60,
  'www-authenticate', // 61
];

/**
 * HTTP/2 帧工具类。
 */
export class Http2Frame {
  /**
   * 把 HTTP/2 帧头 + 负载序列化为字节流。
   */
  static encode(frame: Http2FrameInfo): Uint8Array {
    const out = new Uint8Array(9 + frame.payload.length);
    const view = new DataView(out.buffer);
    const length = frame.payload.length;
    // 24 位长度，3 字节大端
    out[0] = (length >> 16) & 0xff;
    out[1] = (length >> 8) & 0xff;
    out[2] = length & 0xff;
    out[3] = frame.header.type & 0xff;
    out[4] = frame.header.flags & 0xff;
    // streamId 的最高位保留，31 位大端
    out[5] = (frame.header.streamId >> 24) & 0x7f;
    out[6] = (frame.header.streamId >> 16) & 0xff;
    out[7] = (frame.header.streamId >> 8) & 0xff;
    out[8] = frame.header.streamId & 0xff;
    out.set(frame.payload, 9);
    return out;
  }

  /**
   * 从字节流解析出一个帧。
   *
   * @returns 帧；数据不足时返回 undefined
   */
  static decode(buf: Uint8Array, offset: number): FrameDecodeResult | undefined {
    if (buf.length - offset < 9) {
      return undefined;
    }
    const length = (buf[offset] << 16) | (buf[offset + 1] << 8) | buf[offset + 2];
    const type = buf[offset + 3];
    const flags = buf[offset + 4];
    const streamId = ((buf[offset + 5] & 0x7f) * 0x1000000) +
      (buf[offset + 6] << 16) + (buf[offset + 7] << 8) + buf[offset + 8];
    if (buf.length - offset - 9 < length) {
      return undefined;
    }
    const payload = buf.slice(offset + 9, offset + 9 + length);
    const frame = new Http2FrameInfo(type, flags, streamId, payload);
    return { frame: frame, consumed: 9 + length };
  }

  /**
   * 编码一个 SETTINGS 帧。
   *
   * @param settings 键值对列表
   */
  static encodeSettings(settings: number[]): Http2FrameInfo {
    // 每个设置项为 6 字节：2 字节标识 + 4 字节值
    const payload = new Uint8Array((settings.length / 2) * 6);
    const view = new DataView(payload.buffer);
    for (let i = 0; i < settings.length; i += 2) {
      view.setUint16(i * 3, settings[i], false);
      view.setUint32(i * 3 + 2, settings[i + 1], false);
    }
    return new Http2FrameInfo(FrameType.SETTINGS, 0, 0, payload);
  }

  /**
   * 解析 SETTINGS 帧负载。
   */
  static decodeSettings(payload: Uint8Array): number[] {
    const result: number[] = [];
    const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
    for (let i = 0; i + 6 <= payload.length; i += 6) {
      result.push(view.getUint16(i, false));
      result.push(view.getUint32(i + 2, false));
    }
    return result;
  }

  /**
   * 编码 WINDOW_UPDATE 帧。
   */
  static encodeWindowUpdate(streamId: number, increment: number): Http2FrameInfo {
    const payload = new Uint8Array(4);
    const view = new DataView(payload.buffer);
    view.setUint32(0, increment & 0x7fffffff, false);
    return new Http2FrameInfo(FrameType.WINDOW_UPDATE, 0, streamId, payload);
  }

  /**
   * 编码 PING 帧。
   */
  static encodePing(payload?: Uint8Array): Http2FrameInfo {
    const data = payload ?? new Uint8Array(8);
    return new Http2FrameInfo(FrameType.PING, 0, 0, data);
  }

  /**
   * 编码 GOAWAY 帧。
   */
  static encodeGoAway(lastStreamId: number, errorCode: number, debugData?: Uint8Array): Http2FrameInfo {
    const debug = debugData ?? new Uint8Array(0);
    const payload = new Uint8Array(8 + debug.length);
    const view = new DataView(payload.buffer);
    view.setUint32(0, lastStreamId & 0x7fffffff, false);
    view.setUint32(4, errorCode, false);
    payload.set(debug, 8);
    return new Http2FrameInfo(FrameType.GOAWAY, 0, 0, payload);
  }

  /**
   * 编码 RST_STREAM 帧。
   */
  static encodeRstStream(streamId: number, errorCode: number): Http2FrameInfo {
    const payload = new Uint8Array(4);
    const view = new DataView(payload.buffer);
    view.setUint32(0, errorCode, false);
    return new Http2FrameInfo(FrameType.RST_STREAM, 0, streamId, payload);
  }
}

/**
 * HPACK 编码器 / 解码器（gRPC 精简版）。
 *
 * 编码策略：
 *   - 若头名在静态表中且值也完全匹配，使用静态索引（最紧凑）
 *   - 否则使用"不带字面量索引"（0000xxxx）表示，不做 Huffman 编码
 *
 * 解码策略：
 *   - 支持静态表索引、字面量（带/不带索引）
 *   - 遇到 Huffman 编码的字面量会解码（gRPC 服务端可能对部分值使用 Huffman）
 */
export class Hpack {
  /**
   * 查找静态表中「名称 + 值」完全匹配的索引。
   *
   * 静态表条目有两种形态：
   *   - "name"        —— 仅有名称，值为空
   *   - "name: value" —— 名称与值成对
   *
   * @returns 索引；未找到返回 -1
   */
  static staticIndex(name: string, value: string): number {
    for (let i = 1; i < STATIC_TABLE.length; i++) {
      const entry = STATIC_TABLE[i];
      const sep = entry.indexOf(': ');
      if (sep < 0) {
        // 仅名称的条目，值必须也为空
        if (entry === name && value.length === 0) {
          return i;
        }
        continue;
      }
      if (entry.substring(0, sep) === name && entry.substring(sep + 2) === value) {
        return i;
      }
    }
    return -1;
  }

  /**
   * 查找静态表中「仅名称」匹配的索引（用于字面量名称引用）。
   *
   * 语义与 RFC 7541 及参考实现一致：返回**第一个**名称匹配的条目。
   * 注意含值的条目（如索引 2 = ":method: GET"）同样算名称匹配，
   * 因为引用位置只用到条目的名称部分。
   */
  static staticNameIndex(name: string): number {
    for (let i = 1; i < STATIC_TABLE.length; i++) {
      const entry = STATIC_TABLE[i];
      const sep = entry.indexOf(': ');
      const entryName = sep < 0 ? entry : entry.substring(0, sep);
      if (entryName === name) {
        return i;
      }
    }
    return -1;
  }

  /**
   * 编码一组 header 为 HPACK 字节串。
   *
   * @param headers 头字段列表
   */
  static encode(headers: HttpHeader[]): Uint8Array {
    const chunks: Uint8Array[] = [];
    for (const header of headers) {
      const valueIndex = Hpack.staticIndex(header.name, header.value);

      if (valueIndex > 0) {
        // 完全匹配静态表条目 —— 带索引表示（1xxxxxxx），7 位前缀
        chunks.push(new Uint8Array([0x80 | (valueIndex & 0x7f)]));
        continue;
      }

      const nameIndex = Hpack.staticNameIndex(header.name);
      if (nameIndex > 0) {
        // 名称命中静态表 —— 带增量索引的字面量名称（01xxxxxx），6 位前缀
        chunks.push(Http2FrameCodec.encodeInteger(6, 0x40, nameIndex));
      } else {
        // 名称为字面量 —— 带增量索引的字面量名称（01xxxxxx），6 位前缀
        chunks.push(Http2FrameCodec.encodeInteger(6, 0x40, 0));
        const nameBytes = Hpack.huffmanEncode(header.name);
        chunks.push(Http2FrameCodec.encodeInteger(7, 0x80, nameBytes.length));
        chunks.push(nameBytes);
      }
      chunks.push(Hpack.encodeStringLiteral(header.value));
    }
    return Http2FrameCodec.concat(chunks);
  }

  /**
   * 编码字面量值（长度前缀 + Huffman 编码字节）。
   *
   * 长度前缀最高位置 1 表示后续使用 Huffman 编码。
   */
  private static encodeStringLiteral(value: string): Uint8Array {
    const encoded = Hpack.huffmanEncode(value);
    // 最高位置 1 表示 Huffman
    const lenBytes = Http2FrameCodec.encodeInteger(7, 0x80, encoded.length);
    return Http2FrameCodec.concat([lenBytes, encoded]);
  }

  /**
   * 解码 HPACK 字节串为 header 列表。
   *
   * @param buf   字节串
   * @param offset 起始偏移
   * @returns 解析出的 header 列表与消耗的字节数
   */
  static decode(buf: Uint8Array, offset: number): HpackDecodeResult {
    const headers: HttpHeader[] = [];
    let pos = offset;

    while (pos < buf.length) {
      const first = buf[pos];

      if ((first & 0x80) !== 0) {
        // 带索引表示（1xxxxxxx）—— 7 位前缀，直接引用静态表
        const result = Http2FrameCodec.decodeInteger(buf, pos, 7);
        pos = result.next;
        const entry = result.value < STATIC_TABLE.length ? STATIC_TABLE[result.value] : '';
        const sep = entry.indexOf(': ');
        if (sep >= 0) {
          headers.push({ name: entry.substring(0, sep), value: entry.substring(sep + 2) });
        } else {
          headers.push({ name: entry, value: '' });
        }
        continue;
      }

      if ((first & 0xc0) === 0x40) {
        // 带增量索引的字面量（01xxxxxx）—— 6 位前缀
        const result = Http2FrameCodec.decodeInteger(buf, pos, 6);
        pos = result.next;
        let name = '';
        if (result.value === 0) {
          // 名称本身是字面量
          const nameResult = Hpack.decodeStringLiteral(buf, pos);
          pos = nameResult.next;
          name = nameResult.value;
        } else {
          const entry = result.value < STATIC_TABLE.length ? STATIC_TABLE[result.value] : '';
          const sep = entry.indexOf(': ');
          name = sep >= 0 ? entry.substring(0, sep) : entry;
        }
        const valueResult = Hpack.decodeStringLiteral(buf, pos);
        pos = valueResult.next;
        headers.push({ name: name, value: valueResult.value });
        continue;
      }

      if ((first & 0xf0) === 0x00) {
        // 不带索引的字面量（0000xxxx）—— 4 位前缀，名称与值均为字面量
        const nameIndexResult = Http2FrameCodec.decodeInteger(buf, pos, 4);
        pos = nameIndexResult.next;
        let name = '';
        if (nameIndexResult.value === 0) {
          const nameResult = Hpack.decodeStringLiteral(buf, pos);
          pos = nameResult.next;
          name = nameResult.value;
        } else {
          const entry = nameIndexResult.value < STATIC_TABLE.length ?
            STATIC_TABLE[nameIndexResult.value] : '';
          const sep = entry.indexOf(': ');
          name = sep >= 0 ? entry.substring(0, sep) : entry;
        }
        const valueResult = Hpack.decodeStringLiteral(buf, pos);
        pos = valueResult.next;
        headers.push({ name: name, value: valueResult.value });
        continue;
      }

      if ((first & 0xe0) === 0x20) {
        // 动态表大小更新（001xxxxx）—— 5 位前缀，忽略
        const result = Http2FrameCodec.decodeInteger(buf, pos, 5);
        pos = result.next;
        continue;
      }

      // 不带索引的字面量（0000xxxx）—— 名称与值均为字面量
      const nameResult = Hpack.decodeStringLiteral(buf, pos);
      pos = nameResult.next;
      const valueResult = Hpack.decodeStringLiteral(buf, pos);
      pos = valueResult.next;
      headers.push({ name: nameResult.value, value: valueResult.value });
    }

    return { headers: headers, consumed: pos - offset };
  }

  /**
   * 解码一个字符串字面量（长度前缀 + 可能的 Huffman）。
   */
  private static decodeStringLiteral(buf: Uint8Array, offset: number): LiteralDecodeResult {
    const first = buf[offset];
    const huffman = (first & 0x80) !== 0;
    const result = Http2FrameCodec.decodeInteger(buf, offset, 7);
    let pos = result.next;
    const length = result.value;
    const bytes = buf.slice(pos, pos + length);
    pos += length;
    const value = huffman ? Hpack.huffmanDecode(bytes) : Http2FrameCodec.utf8Decode(bytes);
    return { value: value, next: pos };
  }

  /**
   * Huffman 编码（RFC 7541 附录 B）。
   *
   * 与参考实现（Python hpack / grpc-java）逐字节一致，
   * 字符串字面量优先使用 Huffman 以获得与官方客户端相同的编码结果。
   *
   * @param text 待编码文本
   * @returns Huffman 编码后的字节
   */
  static huffmanEncode(text: string): Uint8Array {
    const bytes = Http2FrameCodec.utf8(text);
    const out: number[] = [];
    let acc = 0;
    let accBits = 0;

    for (let i = 0; i < bytes.length; i++) {
      const symbol = bytes[i];
      const entry = Hpack.HUFFMAN_CODES.get(symbol);
      if (entry === undefined) {
        continue;
      }
      acc = (acc << entry.length) | entry.code;
      accBits += entry.length;

      while (accBits >= 8) {
        accBits -= 8;
        out.push((acc >> accBits) & 0xff);
      }
    }

    if (accBits > 0) {
      // 末尾用 1 填充至字节边界（RFC 7541 5.2）
      const padding = 8 - accBits;
      out.push(((acc << padding) | ((1 << padding) - 1)) & 0xff);
    }
    return new Uint8Array(out);
  }

  /**
   * Huffman 解码（RFC 7541 附录 B）。
   *
   * 采用逐位读取 + 码表匹配的实现。
   */
  static huffmanDecode(bytes: Uint8Array): string {
    let result = '';
    let code = 0;
    let bits = 0;
    const table = Hpack.decodeTable();

    for (let i = 0; i < bytes.length; i++) {
      const byte = bytes[i];
      for (let bit = 7; bit >= 0; bit--) {
        code = (code << 1) | ((byte >> bit) & 1);
        bits++;
        const matched = table.get(bits + ':' + code);
        if (matched !== undefined) {
          result += matched;
          code = 0;
          bits = 0;
        }
      }
    }
    // 剩余位为 EOS 前缀，按规范补 1 忽略
    return result;
  }

  /**
   * Huffman 编码表：符号 -> { length, code }。
   * 数据来自 RFC 7541 附录 B。
   */
  private static readonly HUFFMAN_CODES: Map<number, HuffmanCode> = Hpack.buildHuffmanCodes();

  /**
   * Huffman 解码表：键为 "位数:码值"，值为对应字符。
   * 由 HUFFMAN_CODES 反向推导，保证编解码使用同一份数据。
   * 采用惰性初始化，避免静态字段初始化顺序问题。
   */
  private static huffmanTable: Map<string, string> | undefined = undefined;

  /**
   * 获取 Huffman 解码表。
   */
  private static decodeTable(): Map<string, string> {
    if (Hpack.huffmanTable === undefined) {
      const table = new Map<string, string>();
      Hpack.HUFFMAN_CODES.forEach((entry: HuffmanCode, symbol: number) => {
        table.set(entry.length + ':' + entry.code, String.fromCharCode(symbol));
      });
      Hpack.huffmanTable = table;
    }
    return Hpack.huffmanTable;
  }

  /**
   * 构建 Huffman 编码表。
   */
  private static buildHuffmanCodes(): Map<number, HuffmanCode> {
    const map = new Map<number, HuffmanCode>();
    // RFC 7541 附录 B 的 Huffman 码字表（256 个符号）
    map.set(0, { length: 13, code: 8184 });
    map.set(1, { length: 23, code: 8388568 });
    map.set(2, { length: 28, code: 268435426 });
    map.set(3, { length: 28, code: 268435427 });
    map.set(4, { length: 28, code: 268435428 });
    map.set(5, { length: 28, code: 268435429 });
    map.set(6, { length: 28, code: 268435430 });
    map.set(7, { length: 28, code: 268435431 });
    map.set(8, { length: 28, code: 268435432 });
    map.set(9, { length: 24, code: 16777194 });
    map.set(10, { length: 30, code: 1073741820 });
    map.set(11, { length: 28, code: 268435433 });
    map.set(12, { length: 28, code: 268435434 });
    map.set(13, { length: 30, code: 1073741821 });
    map.set(14, { length: 28, code: 268435435 });
    map.set(15, { length: 28, code: 268435436 });
    map.set(16, { length: 28, code: 268435437 });
    map.set(17, { length: 28, code: 268435438 });
    map.set(18, { length: 28, code: 268435439 });
    map.set(19, { length: 28, code: 268435440 });
    map.set(20, { length: 28, code: 268435441 });
    map.set(21, { length: 28, code: 268435442 });
    map.set(22, { length: 30, code: 1073741822 });
    map.set(23, { length: 28, code: 268435443 });
    map.set(24, { length: 28, code: 268435444 });
    map.set(25, { length: 28, code: 268435445 });
    map.set(26, { length: 28, code: 268435446 });
    map.set(27, { length: 28, code: 268435447 });
    map.set(28, { length: 28, code: 268435448 });
    map.set(29, { length: 28, code: 268435449 });
    map.set(30, { length: 28, code: 268435450 });
    map.set(31, { length: 28, code: 268435451 });
    map.set(32, { length: 6, code: 20 });
    map.set(33, { length: 10, code: 1016 });
    map.set(34, { length: 10, code: 1017 });
    map.set(35, { length: 12, code: 4090 });
    map.set(36, { length: 13, code: 8185 });
    map.set(37, { length: 6, code: 21 });
    map.set(38, { length: 8, code: 248 });
    map.set(39, { length: 11, code: 2042 });
    map.set(40, { length: 10, code: 1018 });
    map.set(41, { length: 10, code: 1019 });
    map.set(42, { length: 8, code: 249 });
    map.set(43, { length: 11, code: 2043 });
    map.set(44, { length: 8, code: 250 });
    map.set(45, { length: 6, code: 22 });
    map.set(46, { length: 6, code: 23 });
    map.set(47, { length: 6, code: 24 });
    map.set(48, { length: 5, code: 0 });
    map.set(49, { length: 5, code: 1 });
    map.set(50, { length: 5, code: 2 });
    map.set(51, { length: 6, code: 25 });
    map.set(52, { length: 6, code: 26 });
    map.set(53, { length: 6, code: 27 });
    map.set(54, { length: 6, code: 28 });
    map.set(55, { length: 6, code: 29 });
    map.set(56, { length: 6, code: 30 });
    map.set(57, { length: 6, code: 31 });
    map.set(58, { length: 7, code: 92 });
    map.set(59, { length: 8, code: 251 });
    map.set(60, { length: 15, code: 32764 });
    map.set(61, { length: 6, code: 32 });
    map.set(62, { length: 12, code: 4091 });
    map.set(63, { length: 10, code: 1020 });
    map.set(64, { length: 13, code: 8186 });
    map.set(65, { length: 6, code: 33 });
    map.set(66, { length: 7, code: 93 });
    map.set(67, { length: 7, code: 94 });
    map.set(68, { length: 7, code: 95 });
    map.set(69, { length: 7, code: 96 });
    map.set(70, { length: 7, code: 97 });
    map.set(71, { length: 7, code: 98 });
    map.set(72, { length: 7, code: 99 });
    map.set(73, { length: 7, code: 100 });
    map.set(74, { length: 7, code: 101 });
    map.set(75, { length: 7, code: 102 });
    map.set(76, { length: 7, code: 103 });
    map.set(77, { length: 7, code: 104 });
    map.set(78, { length: 7, code: 105 });
    map.set(79, { length: 7, code: 106 });
    map.set(80, { length: 7, code: 107 });
    map.set(81, { length: 7, code: 108 });
    map.set(82, { length: 7, code: 109 });
    map.set(83, { length: 7, code: 110 });
    map.set(84, { length: 7, code: 111 });
    map.set(85, { length: 7, code: 112 });
    map.set(86, { length: 7, code: 113 });
    map.set(87, { length: 7, code: 114 });
    map.set(88, { length: 8, code: 252 });
    map.set(89, { length: 7, code: 115 });
    map.set(90, { length: 8, code: 253 });
    map.set(91, { length: 13, code: 8187 });
    map.set(92, { length: 19, code: 524272 });
    map.set(93, { length: 13, code: 8188 });
    map.set(94, { length: 14, code: 16380 });
    map.set(95, { length: 6, code: 34 });
    map.set(96, { length: 15, code: 32765 });
    map.set(97, { length: 5, code: 3 });
    map.set(98, { length: 6, code: 35 });
    map.set(99, { length: 5, code: 4 });
    map.set(100, { length: 6, code: 36 });
    map.set(101, { length: 5, code: 5 });
    map.set(102, { length: 6, code: 37 });
    map.set(103, { length: 6, code: 38 });
    map.set(104, { length: 6, code: 39 });
    map.set(105, { length: 5, code: 6 });
    map.set(106, { length: 7, code: 116 });
    map.set(107, { length: 7, code: 117 });
    map.set(108, { length: 6, code: 40 });
    map.set(109, { length: 6, code: 41 });
    map.set(110, { length: 6, code: 42 });
    map.set(111, { length: 5, code: 7 });
    map.set(112, { length: 6, code: 43 });
    map.set(113, { length: 7, code: 118 });
    map.set(114, { length: 6, code: 44 });
    map.set(115, { length: 5, code: 8 });
    map.set(116, { length: 5, code: 9 });
    map.set(117, { length: 6, code: 45 });
    map.set(118, { length: 7, code: 119 });
    map.set(119, { length: 7, code: 120 });
    map.set(120, { length: 7, code: 121 });
    map.set(121, { length: 7, code: 122 });
    map.set(122, { length: 7, code: 123 });
    map.set(123, { length: 15, code: 32766 });
    map.set(124, { length: 11, code: 2044 });
    map.set(125, { length: 14, code: 16381 });
    map.set(126, { length: 13, code: 8189 });
    map.set(127, { length: 28, code: 268435452 });
    map.set(128, { length: 20, code: 1048550 });
    map.set(129, { length: 22, code: 4194258 });
    map.set(130, { length: 20, code: 1048551 });
    map.set(131, { length: 20, code: 1048552 });
    map.set(132, { length: 22, code: 4194259 });
    map.set(133, { length: 22, code: 4194260 });
    map.set(134, { length: 22, code: 4194261 });
    map.set(135, { length: 23, code: 8388569 });
    map.set(136, { length: 22, code: 4194262 });
    map.set(137, { length: 23, code: 8388570 });
    map.set(138, { length: 23, code: 8388571 });
    map.set(139, { length: 23, code: 8388572 });
    map.set(140, { length: 23, code: 8388573 });
    map.set(141, { length: 23, code: 8388574 });
    map.set(142, { length: 24, code: 16777195 });
    map.set(143, { length: 23, code: 8388575 });
    map.set(144, { length: 24, code: 16777196 });
    map.set(145, { length: 24, code: 16777197 });
    map.set(146, { length: 22, code: 4194263 });
    map.set(147, { length: 23, code: 8388576 });
    map.set(148, { length: 24, code: 16777198 });
    map.set(149, { length: 23, code: 8388577 });
    map.set(150, { length: 23, code: 8388578 });
    map.set(151, { length: 23, code: 8388579 });
    map.set(152, { length: 23, code: 8388580 });
    map.set(153, { length: 21, code: 2097116 });
    map.set(154, { length: 22, code: 4194264 });
    map.set(155, { length: 23, code: 8388581 });
    map.set(156, { length: 22, code: 4194265 });
    map.set(157, { length: 23, code: 8388582 });
    map.set(158, { length: 23, code: 8388583 });
    map.set(159, { length: 24, code: 16777199 });
    map.set(160, { length: 22, code: 4194266 });
    map.set(161, { length: 21, code: 2097117 });
    map.set(162, { length: 20, code: 1048553 });
    map.set(163, { length: 22, code: 4194267 });
    map.set(164, { length: 22, code: 4194268 });
    map.set(165, { length: 23, code: 8388584 });
    map.set(166, { length: 23, code: 8388585 });
    map.set(167, { length: 21, code: 2097118 });
    map.set(168, { length: 23, code: 8388586 });
    map.set(169, { length: 22, code: 4194269 });
    map.set(170, { length: 22, code: 4194270 });
    map.set(171, { length: 24, code: 16777200 });
    map.set(172, { length: 21, code: 2097119 });
    map.set(173, { length: 22, code: 4194271 });
    map.set(174, { length: 23, code: 8388587 });
    map.set(175, { length: 23, code: 8388588 });
    map.set(176, { length: 21, code: 2097120 });
    map.set(177, { length: 21, code: 2097121 });
    map.set(178, { length: 22, code: 4194272 });
    map.set(179, { length: 21, code: 2097122 });
    map.set(180, { length: 23, code: 8388589 });
    map.set(181, { length: 22, code: 4194273 });
    map.set(182, { length: 23, code: 8388590 });
    map.set(183, { length: 23, code: 8388591 });
    map.set(184, { length: 20, code: 1048554 });
    map.set(185, { length: 22, code: 4194274 });
    map.set(186, { length: 22, code: 4194275 });
    map.set(187, { length: 22, code: 4194276 });
    map.set(188, { length: 23, code: 8388592 });
    map.set(189, { length: 22, code: 4194277 });
    map.set(190, { length: 22, code: 4194278 });
    map.set(191, { length: 23, code: 8388593 });
    map.set(192, { length: 26, code: 67108832 });
    map.set(193, { length: 26, code: 67108833 });
    map.set(194, { length: 20, code: 1048555 });
    map.set(195, { length: 19, code: 524273 });
    map.set(196, { length: 22, code: 4194279 });
    map.set(197, { length: 23, code: 8388594 });
    map.set(198, { length: 22, code: 4194280 });
    map.set(199, { length: 25, code: 33554412 });
    map.set(200, { length: 26, code: 67108834 });
    map.set(201, { length: 26, code: 67108835 });
    map.set(202, { length: 26, code: 67108836 });
    map.set(203, { length: 27, code: 134217694 });
    map.set(204, { length: 27, code: 134217695 });
    map.set(205, { length: 26, code: 67108837 });
    map.set(206, { length: 24, code: 16777201 });
    map.set(207, { length: 25, code: 33554413 });
    map.set(208, { length: 19, code: 524274 });
    map.set(209, { length: 21, code: 2097123 });
    map.set(210, { length: 26, code: 67108838 });
    map.set(211, { length: 27, code: 134217696 });
    map.set(212, { length: 27, code: 134217697 });
    map.set(213, { length: 26, code: 67108839 });
    map.set(214, { length: 27, code: 134217698 });
    map.set(215, { length: 24, code: 16777202 });
    map.set(216, { length: 21, code: 2097124 });
    map.set(217, { length: 21, code: 2097125 });
    map.set(218, { length: 26, code: 67108840 });
    map.set(219, { length: 26, code: 67108841 });
    map.set(220, { length: 28, code: 268435453 });
    map.set(221, { length: 27, code: 134217699 });
    map.set(222, { length: 27, code: 134217700 });
    map.set(223, { length: 27, code: 134217701 });
    map.set(224, { length: 20, code: 1048556 });
    map.set(225, { length: 24, code: 16777203 });
    map.set(226, { length: 20, code: 1048557 });
    map.set(227, { length: 21, code: 2097126 });
    map.set(228, { length: 22, code: 4194281 });
    map.set(229, { length: 21, code: 2097127 });
    map.set(230, { length: 21, code: 2097128 });
    map.set(231, { length: 23, code: 8388595 });
    map.set(232, { length: 22, code: 4194282 });
    map.set(233, { length: 22, code: 4194283 });
    map.set(234, { length: 25, code: 33554414 });
    map.set(235, { length: 25, code: 33554415 });
    map.set(236, { length: 24, code: 16777204 });
    map.set(237, { length: 24, code: 16777205 });
    map.set(238, { length: 26, code: 67108842 });
    map.set(239, { length: 23, code: 8388596 });
    map.set(240, { length: 26, code: 67108843 });
    map.set(241, { length: 27, code: 134217702 });
    map.set(242, { length: 26, code: 67108844 });
    map.set(243, { length: 26, code: 67108845 });
    map.set(244, { length: 27, code: 134217703 });
    map.set(245, { length: 27, code: 134217704 });
    map.set(246, { length: 27, code: 134217705 });
    map.set(247, { length: 27, code: 134217706 });
    map.set(248, { length: 27, code: 134217707 });
    map.set(249, { length: 28, code: 268435454 });
    map.set(250, { length: 27, code: 134217708 });
    map.set(251, { length: 27, code: 134217709 });
    map.set(252, { length: 27, code: 134217710 });
    map.set(253, { length: 27, code: 134217711 });
    map.set(254, { length: 27, code: 134217712 });
    map.set(255, { length: 26, code: 67108846 });
    return map;
  }

  /**
   * 构建 Huffman 码表。
   *
   * 数据来源：RFC 7541 附录 B 的 (码长, 码值, 字符) 三元组。
   */
}

/**
 * 字节工具（供 Http2Frame 与 Hpack 共用）。
 */
export class Http2FrameCodec {
  /**
   * 拼接字节片段。
   */
  static concat(parts: Uint8Array[]): Uint8Array {
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
   * HPACK 整数编码（RFC 7541 第 5.1 节）。
   *
   * @param prefixBits 前缀位数
   * @param prefixValue 前缀中的标志位
   * @param value      待编码的整数值
   */
  static encodeInteger(prefixBits: number, prefixValue: number, value: number): Uint8Array {
    const maxPrefix = (1 << prefixBits) - 1;
    if (value < maxPrefix) {
      return new Uint8Array([prefixValue | value]);
    }
    const out: number[] = [prefixValue | maxPrefix];
    let remaining = value - maxPrefix;
    while (remaining >= 128) {
      out.push((remaining % 128) + 128);
      remaining = Math.floor(remaining / 128);
    }
    out.push(remaining);
    return new Uint8Array(out);
  }

  /**
   * HPACK 整数解码。
   *
   * @returns 解码值与下一个读取位置
   */
  static decodeInteger(buf: Uint8Array, offset: number, prefixBits: number): IntegerDecodeResult {
    const maxPrefix = (1 << prefixBits) - 1;
    let value = buf[offset] & maxPrefix;
    let pos = offset + 1;
    if (value < maxPrefix) {
      return { value: value, next: pos };
    }
    let shift = 0;
    while (pos < buf.length) {
      const byte = buf[pos++];
      value += (byte & 0x7f) * Math.pow(2, shift);
      shift += 7;
      if ((byte & 0x80) === 0) {
        break;
      }
    }
    return { value: value, next: pos };
  }

  /**
   * UTF-8 编码。
   */
  static utf8(text: string): Uint8Array {
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
   * UTF-8 解码。
   */
  static utf8Decode(bytes: Uint8Array): string {
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
}
