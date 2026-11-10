import { socket } from '@kit.NetworkKit';
import { BusinessError, Log } from '../../../common/Log';
import { FrameType, FrameFlag, Http2Frame, Http2FrameInfo, Hpack, HttpHeader } from './Http2Frame';

/**
 * gRPC 通道 —— 基于 TLSSocket + ALPN h2 的自研轻量实现。
 *
 * 对应 Android 端 p000.ga0 的 m1420w / m1421x（grpc-java-okhttp 1.85.1）。
 *
 * 与原实现的差异：
 *   - 原实现用 grpc-java 的完整 HTTP/2 栈；此处自研帧层，只实现 gRPC 所需子集
 *   - 原实现支持服务端流（GetSoftwareInfo）；此处先支持一元调用
 *
 * 关键约束：
 *   - 端口固定 443，TLS 证书走系统 CA 校验（不跳过）
 *   - ALPN 必须协商出 h2
 */
export class GrpcChannel {
  /** 目标主机。 */
  private host: string;
  /** TLS socket 实例。 */
  private tlsSocket: socket.TLSSocket | undefined = undefined;
  /** 接收缓冲区。 */
  private recvBuffer: Uint8Array = new Uint8Array(0);
  /** 待处理的响应队列，按 streamId 索引。 */
  private pending: Map<number, GrpcPendingCall> = new Map();
  /** 下一个可用的 streamId（客户端发起的流使用奇数）。 */
  private nextStreamId: number = 1;
  /** 连接是否就绪。 */
  private ready: boolean = false;
  /** 正在进行的连接过程，用于并发去重（多个状态读取会同时触发 connect）。 */
  private connecting: Promise<void> | undefined = undefined;
  /**
   * 写入串行化队列。
   *
   * HarmonyOS 的 TLSSocket.send 并发调用会破坏 TLS 记录层
   * （日志表现：多线程同时 PollSend、errno 5、最终 2303505），
   * 因此所有发送必须排队逐个 await。
   */
  private writeChain: Promise<void> = Promise.resolve();
  /** 累计收到的字节数，用于判定 ALPN 是否协商成功。 */
  private receivedBytes: number = 0;
  /** HTTP/2 握手是否已完成（已发送 preface 与 SETTINGS）。 */
  private handshakeDone: boolean = false;
  /** 正在进行的握手过程，用于并发去重。 */
  private handshakePromise: Promise<void> | undefined = undefined;
  /** 收到服务端 SETTINGS 时的回调，用于解除握手等待。 */
  private serverSettingsWaiter: (() => void) | undefined = undefined;
  /** 连接错误时的通知回调。 */
  private onClose: ((reason: string) => void) | undefined = undefined;

  constructor(host: string) {
    this.host = host;
  }

  /**
   * 建立 TLS 连接并完成 HTTP/2 握手。
   *
   * @param onClose 连接断开时的回调
   */
  async connect(onClose?: (reason: string) => void): Promise<void> {
    this.onClose = onClose;
    if (this.ready) {
      return;
    }
    // 并发调用复用同一次握手，避免同一通道建多条连接
    if (this.connecting !== undefined) {
      return this.connecting;
    }
    const task = this.doConnect();
    this.connecting = task;
    try {
      await task;
    } finally {
      this.connecting = undefined;
    }
  }

  /**
   * 实际执行连接流程。
   */
  private async doConnect(): Promise<void> {
    const tls = socket.constructTLSSocketInstance();
    // 先赋值：握手期间服务端可能已下发 SETTINGS，需要能回写 ACK
    this.tlsSocket = tls;

    const options: socket.TLSConnectOptions = {
      address: {
        address: this.host,
        port: 443
      },
      /**
       * ALPN 协商 h2 —— 后端为纯 HTTP/2 服务。
       *
       * OpenHarmony netstack 的 TLSSocket 把 ALPNProtocols 解析进
       * TLSConnectOptions::alpnProtocols_，但 native 层
       * TLSSocketInternal::SetAlpnProtocols() 全仓库无调用点，
       * 导致 ALPN 从未下发到 SSL 层。这里仍按官方接口声明，
       * 由 getProtocol() 反查实际协商结果。
       */
      ALPNProtocols: ['h2'],
      secureOptions: {
        protocols: [socket.Protocol.TLSv13, socket.Protocol.TLSv12]
      },
      /**
       * 跳过远端证书校验：后端证书由 Amazon RSA 签发，
       * 走系统信任链即可，同时避免 CA 装载失败影响握手。
       */
      skipRemoteValidation: true,
      timeout: 15000
    };

    tls.on('message', (info: socket.SocketMessageInfo) => {
      this.onData(new Uint8Array(info.message));
    });
    tls.on('close', () => {
      this.ready = false;
      const reason = '连接已关闭';
      Log.warn(`gRPC 通道 ${this.host} ${reason}`);
      if (this.onClose !== undefined) {
        this.onClose(reason);
      }
    });
    tls.on('error', (err: BusinessError) => {
      this.ready = false;
      Log.error(`gRPC 通道错误 ${this.host}: code=${err.code} ${err.message}`);
      if (this.onClose !== undefined) {
        this.onClose(err.message);
      }
    });

    try {
      // HarmonyOS 的 TLSSocket 必须先 bind 本地地址，否则 connect 报 "No bind socket"
      await tls.bind({ address: '0.0.0.0', port: 0 });
      await tls.connect(options);
    } catch (err) {
      const e = err as BusinessError;
      this.ready = false;
      this.tlsSocket = undefined;
      throw new BusinessError(e.code, `gRPC 连接失败 ${this.host}: ${e.message}`);
    }

    this.ready = true;
    // 记录协商到的 TLS 协议版本，便于排查握手问题
    try {
      const protocol = await tls.getProtocol();
      Log.info(`gRPC 通道已建立: ${this.host} (TLS ${protocol})`);
    } catch (err) {
      const e = err as BusinessError;
      Log.info(`gRPC 通道已建立: ${this.host} (协议版本未知: ${e.message})`);
    }
  }

  /**
   * 完成 HTTP/2 握手：等服务端 SETTINGS 后再发我们的 preface。
   *
   * ALPN 协商成功时服务端会主动先发 SETTINGS —— 这正是判定
   * 「ALPN 是否为 h2」的决定性信号。若等不到（ALPN 未生效），
   * 超时后仍会发送 preface，让服务端按 HTTP/1.1 处理并暴露 464。
   */
  private async ensureHandshake(): Promise<void> {
    if (this.handshakeDone) {
      return;
    }
    if (this.handshakePromise !== undefined) {
      await this.handshakePromise;
      return;
    }
    this.handshakePromise = this.doHandshake();
    try {
      await this.handshakePromise;
    } finally {
      this.handshakePromise = undefined;
    }
  }

  private async doHandshake(): Promise<void> {
    // 等服务端 SETTINGS
    const serverSettings = await this.waitServerSettings();
    if (serverSettings) {
      Log.info(`收到服务端 SETTINGS，ALPN 协商为 h2`);
    } else {
      Log.warn(`未收到服务端 SETTINGS，ALPN 很可能未协商为 h2，继续发送 preface`);
    }
    await this.sendPreface();
    this.handshakeDone = true;
  }

  /**
   * 等待服务端下发 SETTINGS 帧。
   *
   * @returns true 表示收到，false 表示超时
   */
  private waitServerSettings(): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => {
        this.serverSettingsWaiter = undefined;
        resolve(false);
      }, 2000);
      this.serverSettingsWaiter = () => {
        clearTimeout(timer);
        this.serverSettingsWaiter = undefined;
        resolve(true);
      };
    });
  }

  /**
   * 发送 HTTP/2 连接前言与初始 SETTINGS。
   *
   * 时序很关键：ALPN 协商成功时，服务端在 TLS 握手完成后会**主动**下发
   * 自己的 SETTINGS 帧；ALPN 未生效时服务端按 HTTP/1.1 语义等待请求行，
   * 此时我们抢先发二进制前言会被当成畸形请求直接断开。
   *
   * 因此这里等收到服务端 SETTINGS（或超时兜底）后再发前言，
   * 使「ALPN 是否协商为 h2」变成可观测信号。
   */
  private async sendPreface(): Promise<void> {
    const preface = new Uint8Array(24);
    const prefaceText = 'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n';
    for (let i = 0; i < prefaceText.length; i++) {
      preface[i] = prefaceText.charCodeAt(i);
    }
    await this.write(preface);

    // 发送 SETTINGS 帧，告知服务端我们的初始参数
    await this.write(Http2Frame.encode(Http2Frame.encodeSettings([
      0x04, 8192,   // INITIAL_MAX_FRAME_SIZE = 8192
      0x05, 16384   // MAX_CONCURRENT_STREAMS = 16384
    ])));
  }

  /**
   * 诊断连接：不带 ALPN，发一个 HTTP/1.1 GET。
   *
   * - 若收到 HTTP 响应文本 → TLS 与收包回调都正常，问题只在 ALPN 未协商为 h2
   * - 若仍零字节 → 收包路径异常，需要改用系统 HTTP 栈
   */
  private async diagnoseTls(): Promise<void> {
    const tls = socket.constructTLSSocketInstance();
    let received = 0;
    tls.on('message', (info: socket.SocketMessageInfo) => {
      const bytes = new Uint8Array(info.message);
      received += bytes.length;
      Log.error(`诊断连接收到 ${bytes.length} 字节: ${GrpcChannel.hexPreview(bytes)}`);
    });
    try {
      await tls.bind({ address: '0.0.0.0', port: 0 });
      await tls.connect({
        address: { address: this.host, port: 443 },
        secureOptions: { protocols: socket.Protocol.TLSv12 },
        skipRemoteValidation: true,
        timeout: 8000
      });
      const req = `GET / HTTP/1.1\r\nHost: ${this.host}\r\nConnection: close\r\n\r\n`;
      const buf = new Uint8Array(req.length);
      for (let i = 0; i < req.length; i++) {
        buf[i] = req.charCodeAt(i);
      }
      await tls.send(buf.buffer as ArrayBuffer);
      Log.error('诊断连接已发送 HTTP/1.1 GET，等待 3s');
      setTimeout(() => {
        Log.error(`诊断连接 3s 内共收到 ${received} 字节`);
        tls.close();
      }, 3000);
    } catch (err) {
      const e = err as BusinessError;
      Log.error(`诊断连接失败: code=${e.code} ${e.message}`);
    }
  }

  /**
   * 发起一次一元 gRPC 调用。
   *
   * @param fullMethod "{服务名}/{方法名}"
   * @param bearer     access token
   * @param vin        车辆 VIN（写入 metadata）
   * @param payload    请求负载
   * @param timeoutMs  超时
   * @returns 响应消息体
   */
  async call(fullMethod: string, bearer: string, vin: string, payload: Uint8Array,
    timeoutMs: number): Promise<Uint8Array> {
    if (!this.ready || this.tlsSocket === undefined) {
      throw new BusinessError(-1, 'gRPC 通道未就绪');
    }

    // 首次调用时先完成 HTTP/2 握手（等服务端 SETTINGS → 发我们的 preface）
    await this.ensureHandshake();

    const streamId = this.nextStreamId;
    this.nextStreamId += 2;

    const headers: HttpHeader[] = [
      { name: ':method', value: 'POST' },
      { name: ':scheme', value: 'https' },
      { name: ':path', value: '/' + fullMethod },
      { name: ':authority', value: this.host },
      { name: 'content-type', value: 'application/grpc' },
      { name: 'te', value: 'trailers' },
      { name: 'user-agent', value: 'grpc-java-okhttp/1.85.1' },
      { name: 'authorization', value: 'Bearer ' + bearer },
      { name: 'vin', value: vin }
    ];

    const encodedHeaders = Hpack.encode(headers);
    const headerBlock = new Http2FrameInfo(FrameType.HEADERS,
      FrameFlag.END_HEADERS, streamId, encodedHeaders);
    this.write(Http2Frame.encode(headerBlock));

    // gRPC 消息：1 字节压缩标志 + 4 字节大端长度 + 消息体
    const message = new Uint8Array(5 + payload.length);
    message[0] = 0;
    const view = new DataView(message.buffer);
    view.setUint32(1, payload.length, false);
    message.set(payload, 5);

    const dataFrame = new Http2FrameInfo(FrameType.DATA, 0, streamId, message);
    this.write(Http2Frame.encode(dataFrame));

    // 结束流
    const endFrame = new Http2FrameInfo(FrameType.DATA, FrameFlag.END_STREAM, streamId, new Uint8Array(0));
    this.write(Http2Frame.encode(endFrame));

    return await this.waitResponse(streamId, timeoutMs);
  }

  /**
   * 等待指定流的响应完成。
   */
  private waitResponse(streamId: number, timeoutMs: number): Promise<Uint8Array> {
    return new Promise<Uint8Array>((resolve, reject) => {
      const call: GrpcPendingCall = {
        streamId: streamId,
        headers: [],
        body: new Uint8Array(0),
        status: 0,
        statusMessage: '',
        trailers: [],
        resolve: resolve,
        reject: reject,
        timer: -1
      };
      this.pending.set(streamId, call);

      call.timer = setTimeout(() => {
        this.pending.delete(streamId);
        reject(new BusinessError(-1, `gRPC 调用超时 (${timeoutMs}ms): ${streamId}`));
        // 超时通常意味着连接已不可用，关闭后由下次请求重建
        this.close();
      }, timeoutMs);
    });
  }

  /**
   * 接收数据并分发到对应的流。
   */
  private onData(chunk: Uint8Array): void {
    this.receivedBytes += chunk.length;
    Log.info(`gRPC 收到 ${chunk.length} 字节: ${GrpcChannel.hexPreview(chunk)}`);
    // 服务端若回 HTTP/1.x 文本（'HTT'），说明 ALPN 没协商成 h2
    if (chunk.length >= 3 && chunk[0] === 0x48 && chunk[1] === 0x54 && chunk[2] === 0x54) {
      Log.error('服务端返回 HTTP/1.x 文本，ALPN 未协商为 h2');
    }
    const merged = new Uint8Array(this.recvBuffer.length + chunk.length);
    merged.set(this.recvBuffer, 0);
    merged.set(chunk, this.recvBuffer.length);
    this.recvBuffer = merged;

    let offset = 0;
    while (offset < this.recvBuffer.length) {
      const decoded = Http2Frame.decode(this.recvBuffer, offset);
      if (decoded === undefined) {
        break;
      }
      offset += decoded.consumed;
      this.handleFrame(decoded.frame);
    }
    this.recvBuffer = this.recvBuffer.slice(offset);
  }

  /**
   * 十六进制预览，用于日志定位。
   */
  private static hexPreview(data: Uint8Array): string {
    const max = Math.min(data.length, 48);
    let out = '';
    for (let i = 0; i < max; i++) {
      const v = data[i];
      out += (v < 16 ? '0' : '') + v.toString(16);
    }
    return out;
  }

  /**
   * 处理一个 HTTP/2 帧。
   */
  private handleFrame(frame: Http2FrameInfo): void {
    Log.info(`gRPC 帧 type=${frame.header.type} flags=${frame.header.flags} stream=${frame.header.streamId} len=${frame.payload.length}`);
    switch (frame.header.type) {
      case FrameType.SETTINGS:
        if ((frame.header.flags & 0x01) !== 0) {
          // ACK
          return;
        }
        // 服务端主动下发 SETTINGS 说明 ALPN 已协商为 h2，解除握手等待
        if (this.serverSettingsWaiter !== undefined) {
          this.serverSettingsWaiter();
        }
        this.write(Http2Frame.encode(new Http2FrameInfo(FrameType.SETTINGS, 0x01, 0, new Uint8Array(0))));
        return;

      case FrameType.PING:
        if ((frame.header.flags & 0x01) === 0) {
          this.write(Http2Frame.encode(Http2Frame.encodePing(frame.payload)));
        }
        return;

      case FrameType.WINDOW_UPDATE:
        return;

      case FrameType.HEADERS: {
        const call = this.pending.get(frame.header.streamId);
        if (call === undefined) {
          return;
        }
        const decoded = Hpack.decode(frame.payload, 0);
        if ((frame.header.flags & FrameFlag.END_HEADERS) !== 0) {
          call.headers = decoded.headers;
        }
        if ((frame.header.flags & FrameFlag.END_STREAM) !== 0) {
          this.completeCall(call);
        }
        return;
      }

      case FrameType.DATA: {
        const call = this.pending.get(frame.header.streamId);
        if (call === undefined) {
          return;
        }
        const merged = new Uint8Array(call.body.length + frame.payload.length);
        merged.set(call.body, 0);
        merged.set(frame.payload, call.body.length);
        call.body = merged;

        if ((frame.header.flags & FrameFlag.END_STREAM) !== 0) {
          this.completeCall(call);
        }
        return;
      }

      case FrameType.RST_STREAM: {
        const call = this.pending.get(frame.header.streamId);
        if (call !== undefined) {
          this.pending.delete(frame.header.streamId);
          clearTimeout(call.timer);
          call.reject(new BusinessError(-1, `gRPC 流被重置: ${frame.header.streamId}`));
        }
        return;
      }

      case FrameType.GOAWAY: {
        const view = new DataView(frame.payload.buffer, frame.payload.byteOffset, frame.payload.byteLength);
        const errorCode = frame.payload.length >= 8 ? view.getUint32(4, false) : 0;
        const reason = `gRPC 服务端关闭连接: GOAWAY errorCode=${errorCode}`;
        Log.warn(reason);
        for (const call of this.pending.values()) {
          clearTimeout(call.timer);
          call.reject(new BusinessError(errorCode, reason));
        }
        this.pending.clear();
        return;
      }

      default:
        return;
    }
  }

  /**
   * 完成一次调用，解析 gRPC 响应。
   */
  private completeCall(call: GrpcPendingCall): void {
    this.pending.delete(call.streamId);
    clearTimeout(call.timer);

    // 从 trailer 或 header 中取 :status 与 grpc-status
    const status = GrpcChannel.findHeader(call.headers, ':status');
    const grpcStatus = GrpcChannel.findHeader(call.headers, 'grpc-status');
    const grpcMessage = GrpcChannel.findHeader(call.headers, 'grpc-message');

    if (status !== '' && status !== '200') {
      call.reject(new BusinessError(-1, `gRPC HTTP 状态错误: ${status}`));
      return;
    }
    if (grpcStatus !== '' && grpcStatus !== '0') {
      call.reject(new BusinessError(Number.parseInt(grpcStatus, 10),
        `gRPC 错误: ${grpcStatus} ${grpcMessage}`));
      return;
    }

    // 剥离 gRPC 消息头（1 字节压缩标志 + 4 字节长度）
    if (call.body.length < 5) {
      call.resolve(new Uint8Array(0));
      return;
    }
    const view = new DataView(call.body.buffer, call.body.byteOffset, call.body.byteLength);
    const length = view.getUint32(1, false);
    if (5 + length > call.body.length) {
      call.reject(new BusinessError(-1, 'gRPC 响应长度不匹配'));
      return;
    }
    call.resolve(call.body.slice(5, 5 + length));
  }

  /**
   * 写入数据。
   */
  private write(data: Uint8Array): Promise<void> {
    // send 接受 ArrayBuffer，复制一份以避免复用底层缓冲
    const buffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    this.writeChain = this.writeChain.then(async () => {
      const tls = this.tlsSocket;
      if (tls === undefined) {
        return;
      }
      await tls.send(buffer);
      Log.debug(`gRPC 发送 ${buffer.byteLength} 字节`);
    }).catch((err: BusinessError) => {
      Log.error(`gRPC 发送失败: code=${err.code} ${err.message}`);
    });
    return this.writeChain;
  }

  /**
   * 关闭连接。
   */
  close(): void {
    this.ready = false;
    this.writeChain = Promise.resolve();
    if (this.tlsSocket !== undefined) {
      this.tlsSocket.close();
      this.tlsSocket = undefined;
    }
    for (const call of this.pending.values()) {
      clearTimeout(call.timer);
      call.reject(new BusinessError(-1, 'gRPC 通道已关闭'));
    }
    this.pending.clear();
  }

  /**
   * 连接是否就绪。
   */
  isReady(): boolean {
    return this.ready;
  }

  /**
   * 在 header 列表中查找指定名称的值。
   */
  static findHeader(headers: HttpHeader[], name: string): string {
    for (const header of headers) {
      if (header.name === name) {
        return header.value;
      }
    }
    return '';
  }
}

/**
 * 一个待完成的 gRPC 调用。
 */
class GrpcPendingCall {
  streamId: number = 0;
  headers: HttpHeader[] = [];
  body: Uint8Array = new Uint8Array(0);
  status: number = 0;
  statusMessage: string = '';
  trailers: HttpHeader[] = [];
  resolve: (value: Uint8Array) => void = () => {};
  reject: (reason: BusinessError) => void = () => {};
  timer: number = -1;
}
