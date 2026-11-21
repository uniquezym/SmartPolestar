import { Log } from '../../../common/Log';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'GrpcMessageParser';

/**
 * gRPC 消息帧增量解析器。
 *
 * 服务端流（如 GetExterior）会持续推送多条 gRPC 消息，
 * 而 RCP 的 IncomingDataCallback 给出的字节块边界与消息边界无关，
 * 因此需要一个能跨块拼接的解析器。
 *
 * 帧格式（gRPC over HTTP/2，RFC 9113）：
 *   1 字节压缩标志 + 4 字节大端长度 + 消息体
 *
 * 关于「RCP 是否保留帧头」：
 *   实测两种都可能。保留时每条消息以压缩标志 0x00 开头；
 *   剥掉时每条消息是裸 protobuf，而合法 protobuf 的首字节必然 >= 8
 *   （tag = fieldNumber << 3 | wireType，fieldNumber >= 1），
 *   所以「首字节为 0」即可判定为带帧头，不存在歧义。
 */
export class GrpcMessageParser {
  /** 模式：尚未判定。 */
  private static readonly MODE_UNKNOWN: number = 0;
  /** 模式：数据保留 gRPC 帧头。 */
  private static readonly MODE_FRAMED: number = 1;
  /** 模式：数据是裸 protobuf，RCP 已剥掉帧头。 */
  private static readonly MODE_BARE: number = 2;

  /** 跨块拼接的缓冲区。 */
  private buffer: Uint8Array = new Uint8Array(0);
  /** 帧模式。 */
  private mode: number = GrpcMessageParser.MODE_UNKNOWN;
  /** 已解析出的消息条数，用于日志。 */
  private messageCount: number = 0;

  /**
   * 喂入一块数据，吐出其中完整的消息。
   *
   * @param chunk 收到的字节块
   * @returns 该块内解析出的完整消息（裸 protobuf，不含帧头）
   */
  feed(chunk: Uint8Array): Uint8Array[] {
    if (chunk.length === 0) {
      return [];
    }

    const merged = new Uint8Array(this.buffer.length + chunk.length);
    merged.set(this.buffer, 0);
    merged.set(chunk, this.buffer.length);
    this.buffer = merged;

    if (this.mode === GrpcMessageParser.MODE_UNKNOWN) {
      this.detectMode();
    }

    if (this.mode === GrpcMessageParser.MODE_BARE) {
      // 裸 protobuf：按 protobuf 自身的结构切分消息边界
      return this.splitBare();
    }
    return this.splitFramed();
  }

  /**
   * 判定帧模式。
   */
  private detectMode(): void {
    if (this.buffer.length === 0) {
      return;
    }
    if (this.buffer[0] === 0) {
      this.mode = GrpcMessageParser.MODE_FRAMED;
    } else {
      this.mode = GrpcMessageParser.MODE_BARE;
    }
    Log.info(TAG, `gRPC 流帧模式: ${this.mode === GrpcMessageParser.MODE_FRAMED ? '带帧头' : '裸 protobuf'}`);
  }

  /**
   * 按 gRPC 帧头切分。
   */
  private splitFramed(): Uint8Array[] {
    const messages: Uint8Array[] = [];
    let offset = 0;

    while (this.buffer.length - offset >= 5) {
      const compressed = this.buffer[offset];
      const length = (this.buffer[offset + 1] << 24) | (this.buffer[offset + 2] << 16) |
        (this.buffer[offset + 3] << 8) | this.buffer[offset + 4];

      if (this.buffer.length - offset - 5 < length) {
        // 消息体还没收全，等下一块
        break;
      }

      const payload = this.buffer.slice(offset + 5, offset + 5 + length);
      offset += 5 + length;

      if (compressed !== 0) {
        Log.warn(TAG, `gRPC 流收到压缩帧（标志=${compressed}），当前不支持`);
        continue;
      }
      messages.push(payload);
    }

    this.buffer = this.buffer.slice(offset);
    this.messageCount += messages.length;
    return messages;
  }

  /**
   * 按 protobuf 结构切分。
   *
   * RPC 剥掉帧头后，字节流里就是连续的 protobuf 消息，
   * 没有额外的分隔标记，只能靠解析 protobuf 结构算出每条消息的长度。
   */
  private splitBare(): Uint8Array[] {
    const messages: Uint8Array[] = [];
    let offset = 0;

    while (offset < this.buffer.length) {
      const size = GrpcMessageParser.scanProtobufLength(this.buffer, offset);
      if (size <= 0) {
        // 数据不完整，等下一块
        break;
      }
      messages.push(this.buffer.slice(offset, offset + size));
      offset += size;
    }

    this.buffer = this.buffer.slice(offset);
    this.messageCount += messages.length;
    return messages;
  }

  /**
   * 计算从 offset 开始的一条 protobuf 消息占用的字节数。
   *
   * @returns 完整消息的字节数；数据不足或畸形返回 -1
   */
  static scanProtobufLength(buf: Uint8Array, offset: number): number {
    let pos = offset;

    while (pos < buf.length) {
      // tag
      let tag = 0;
      let shift = 1;
      let tagDone = false;
      let tagBytes = 0;
      while (pos < buf.length) {
        const byte = buf[pos++];
        tag += (byte & 0x7f) * shift;
        tagBytes++;
        if ((byte & 0x80) === 0) {
          tagDone = true;
          break;
        }
        shift *= 128;
        if (tagBytes >= 10) {
          return -1;
        }
      }
      if (!tagDone) {
        return -1;
      }

      const fieldNumber = Math.floor(tag / 8);
      const wireType = tag % 8;
      if (fieldNumber <= 0) {
        return -1;
      }

      if (wireType === 0) {
        // varint
        let count = 0;
        let done = false;
        while (pos < buf.length) {
          const byte = buf[pos++];
          count++;
          if ((byte & 0x80) === 0) {
            done = true;
            break;
          }
          if (count >= 10) {
            return -1;
          }
        }
        if (!done) {
          return -1;
        }
      } else if (wireType === 1) {
        // 64 位
        if (buf.length - pos < 8) {
          return -1;
        }
        pos += 8;
      } else if (wireType === 2) {
        // 长度分隔
        let length = 0;
        let lengthShift = 1;
        let lengthDone = false;
        let lengthBytes = 0;
        while (pos < buf.length) {
          const byte = buf[pos++];
          length += (byte & 0x7f) * lengthShift;
          lengthShift *= 128;
          lengthBytes++;
          if ((byte & 0x80) === 0) {
            lengthDone = true;
            break;
          }
          if (lengthBytes >= 5) {
            return -1;
          }
        }
        if (!lengthDone) {
          return -1;
        }
        if (buf.length - pos < length) {
          return -1;
        }
        pos += length;
      } else if (wireType === 5) {
        // 32 位
        if (buf.length - pos < 4) {
          return -1;
        }
        pos += 4;
      } else {
        // wire type 3/4（分组）在本协议中不出现
        return -1;
      }
    }

    return pos - offset;
  }

  /**
   * 已解析出的消息总数。
   */
  getMessageCount(): number {
    return this.messageCount;
  }

  /**
   * 重置解析状态（重连时用）。
   */
  reset(): void {
    this.buffer = new Uint8Array(0);
    this.mode = GrpcMessageParser.MODE_UNKNOWN;
    this.messageCount = 0;
  }
}
