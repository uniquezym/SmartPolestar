import { rcp } from '@kit.RemoteCommunicationKit';
import { connection } from '@kit.NetworkKit';
import { BusinessError, Log } from '../../../common/Log';

/**
 * gRPC unary 调用的 RCP 传输层。
 *
 * 为什么用 RCP（Remote Communication Kit）而不是 @ohos.net.http：
 *
 *   OpenHarmony 7.0 的 netstack curl 与 native tls_socket 都不协商 ALPN，
 *   设备上所有 HTTPS 请求实测都是 HTTP/1.1（httpVer:2）。C3 后端前面是
 *   AWS ELB（Server: awselb/2.0），目标组为 gRPC/HTTP2，用 HTTP/1.1 语义
 *   发送会被直接拒绝并返回 464：
 *     "Load Balancer received an incompatible request protocol"
 *
 *   RCP 是华为自研的远场通信 HTTP 栈，独立于 netstack curl，内建
 *   HTTP/2 帧层（错误码 1007900016 "Error in the HTTP2 framing layer"），
 *   因此可以与该 gRPC 后端正常通信。
 *
 * gRPC 一元调用在 HTTP/2 上的约定：
 *   POST /<service>/<method>
 *   content-type: application/grpc
 *   te: trailers
 *   请求体 = 1 字节压缩标志(0) + 4 字节大端长度 + protobuf
 *   响应体 = 同格式的一帧（可能为空）
 */
export class GrpcRcpChannel {
  /** gRPC 服务端口（服务发现返回 grpcPort = 443）。 */
  private static readonly GRPC_PORT: number = 443;

  /** 建连超时（毫秒）。 */
  private static readonly CONNECT_TIMEOUT_MS: number = 15000;

  /**
   * 传输层错误码 —— 发生后可换 IP 重试。
   *   1007900005 Couldn't resolve proxy name
   *   1007900006 Couldn't resolve host name
   *   1007900007 Couldn't connect to server
   *   1007900028 Timeout was reached
   *   1007900035 SSL connect error
   */
  private static readonly TRANSPORT_ERRORS: number[] =
    [1007900005, 1007900006, 1007900007, 1007900028, 1007900035];

  private host: string;
  private session: rcp.Session | undefined = undefined;
  /** 系统解析得到的 IP 列表，重试时轮换首位以避开坏节点。 */
  private resolvedIps: string[] = [];

  constructor(host: string) {
    this.host = host;
  }

  /**
   * HTTP 传输无需预建连接，始终视为就绪。
   */
  isReady(): boolean {
    return true;
  }

  /**
   * 无需显式建链，保留方法以兼容调用方。
   */
  async connect(): Promise<void> {
    return;
  }

  /**
   * 取出响应头中的单个字符串值。
   *
   * ResponseHeaders 的值可能是 string / string[] / undefined，需归一化。
   */
  private static headerValue(value: string | string[] | undefined): string {
    if (value === undefined) {
      return '';
    }
    if (typeof value === 'string') {
      return value;
    }
    return value.length > 0 ? value[0] : '';
  }

  /**
   * 判断异常是否为传输层错误（可换 IP 重试）。
   */
  private static isTransportError(code: number): boolean {
    return GrpcRcpChannel.TRANSPORT_ERRORS.indexOf(code) >= 0;
  }

  /**
   * 用系统解析器（netstack）解析主机名。
   *
   * RCP 自带的解析器（真机日志 dnsFromNetsys:0）返回过 28.0.x.x 这类
   * 不可达地址，而系统解析器稳定返回 3 个 AWS ELB 节点。
   * 因此统一以系统解析结果为准。
   */
  private async resolve(): Promise<void> {
    if (this.resolvedIps.length > 0) {
      return;
    }
    try {
      const addresses = await connection.getAddressesByName(this.host);
      const v4: string[] = [];
      const v6: string[] = [];
      for (const item of addresses) {
        const address = item.address;
        if (address === undefined || address.length === 0) {
          continue;
        }
        if (item.family === 1) {
          v4.push(address);
        } else {
          v6.push(address);
        }
      }
      const ips: string[] = v4.length > 0 ? v4 : v6;
      if (ips.length > 0) {
        this.resolvedIps = ips;
        Log.info(`RCP DNS ${this.host} => ${ips.join(', ')}`);
      }
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`RCP DNS 解析失败 ${this.host}: code=${e.code} ${e.message}`);
    }
  }

  /**
   * 将 IP 列表首位轮转到末尾，使下次重试优先使用另一个节点。
   */
  private rotateIps(): void {
    if (this.resolvedIps.length < 2) {
      return;
    }
    const first = this.resolvedIps.shift();
    if (first !== undefined) {
      this.resolvedIps.push(first);
    }
  }

  /**
   * 关闭会话。
   */
  close(): void {
    if (this.session !== undefined) {
      this.session.close();
      this.session = undefined;
    }
  }

  /**
   * 构造请求配置。
   *
   * dns.dnsRules 把已解析的 IP 固定给 RCP，绕开它自带的解析器；
   * happyEyeballOnDnsRule 让 RCP 并行尝试多个 IP。
   */
  private buildConfiguration(timeoutMs: number): rcp.Configuration {
    const configuration: rcp.Configuration = {
      transfer: {
        autoRedirect: false,
        timeout: {
          connectMs: GrpcRcpChannel.CONNECT_TIMEOUT_MS,
          transferMs: timeoutMs
        }
      },
      security: {
        // 后端证书由 Amazon RSA 签发且链完整，走系统信任链校验即可。
        remoteValidation: 'system'
      }
    };

    if (this.resolvedIps.length > 0) {
      const rules: rcp.StaticDnsRule[] = [{
        host: this.host,
        port: GrpcRcpChannel.GRPC_PORT,
        ipAddresses: this.resolvedIps
      }];
      configuration.dns = {
        dnsRules: rules,
        happyEyeballOnDnsRule: true
      };
    }

    return configuration;
  }

  /**
   * 获取（必要时创建）会话。
   *
   * Session 负责连接复用与 HTTP/2 多路复用，必须在整个调用序列中保持不变，
   * 否则每个请求都会新建连接、重新协商协议。
   */
  private ensureSession(): rcp.Session {
    if (this.session !== undefined) {
      return this.session;
    }
    const configuration: rcp.SessionConfiguration = {
      requestConfiguration: this.buildConfiguration(GrpcRcpChannel.CONNECT_TIMEOUT_MS)
    };
    this.session = rcp.createSession(configuration);
    return this.session;
  }

  /**
   * 发起一次一元 gRPC 调用。
   *
   * @param fullMethod `<service>/<method>`
   * @param token      Bearer access token
   * @param vin        车辆 VIN，作为 gRPC metadata 传递
   * @param payload    protobuf 请求负载
   * @param timeoutMs  超时
   */
  async call(fullMethod: string, token: string, vin: string,
    payload: Uint8Array, timeoutMs: number): Promise<Uint8Array> {
    // 组装 gRPC 消息帧：1 字节压缩标志 + 4 字节大端长度 + protobuf
    const frame = new Uint8Array(5 + payload.length);
    frame[0] = 0;
    frame[1] = (payload.length >>> 24) & 0xff;
    frame[2] = (payload.length >>> 16) & 0xff;
    frame[3] = (payload.length >>> 8) & 0xff;
    frame[4] = payload.length & 0xff;
    frame.set(payload, 5);

    const headers: rcp.RequestHeaders = {
      'content-type': 'application/grpc',
      'te': 'trailers',
      'grpc-encoding': 'identity',
      'grpc-accept-encoding': 'identity',
      'authorization': `Bearer ${token}`,
      'vin': vin,
      'user-agent': 'grpc-java-okhttp/1.85.1'
    };

    const url = `https://${this.host}/${fullMethod}`;

    let lastError: BusinessError | undefined = undefined;
    for (let attempt = 0; attempt < 2; attempt++) {
      await this.resolve();

      const session = this.ensureSession();
      const request = new rcp.Request(url, 'POST', headers, frame.buffer as ArrayBuffer,
        undefined, undefined, this.buildConfiguration(timeoutMs));
      request.destination = 'array-buffer';

      try {
        const response = await session.fetch(request);
        const status = response.statusCode;
        const grpcStatus = GrpcRcpChannel.headerValue(response.headers['grpc-status']);
        const grpcMessage = GrpcRcpChannel.headerValue(response.headers['grpc-message']);
        Log.info(`gRPC(RCP) ${fullMethod} status=${status} httpVer=${response.httpVersion ?? 'unknown'} grpcStatus=${grpcStatus} grpcMessage=${grpcMessage}`);

        // gRPC 一元调用：HTTP 200 + grpc-status 0 才算成功。
        // grpc-status 正常由 HTTP/2 trailers 携带，RCP 会合并进 headers。
        if (status === 200 && grpcStatus.length > 0 && grpcStatus !== '0') {
          throw new BusinessError(200, `gRPC 错误: status=${grpcStatus} ${grpcMessage}`);
        }

        if (status !== 200) {
          Log.error(`gRPC(RCP) ${fullMethod} status=${status} 响应头=${JSON.stringify(response.headers)}`);
          if (status === 401 || status === 403) {
            throw new BusinessError(status, `UNAUTHENTICATED: HTTP ${status}`);
          }
          throw new BusinessError(status, `gRPC HTTP 错误: ${status} ${grpcMessage}`);
        }

        const body = response.body;
        if (body === undefined || body.byteLength === 0) {
          // 服务端只回了 trailers（grpc-status 0）而没有消息体
          Log.warn(`gRPC(RCP) ${fullMethod} 响应体为空（grpc-status=${grpcStatus}）`);
          return new Uint8Array(0);
        }

        const raw = new Uint8Array(body);
        // gRPC 消息帧 = 1 字节压缩标志 + 4 字节大端长度 + protobuf。
        // RCP 可能已经剥掉帧头，也可能原样返回，因此按帧头特征判定，
        // 不能无条件 slice(5)——那会砍掉真实 protobuf 的前 5 字节。
        if (raw[0] === 0) {
          const declared = (raw[1] << 24) | (raw[2] << 16) | (raw[3] << 8) | raw[4];
          if (declared + 5 === raw.length) {
            return raw.slice(5);
          }
          // 不是帧头，按裸 protobuf 处理
          Log.warn(`gRPC(RCP) ${fullMethod} 帧头长度不符: 声明 ${declared} 实际 ${raw.length}，按裸 protobuf 解析`);
        }
        return raw;
      } catch (err) {
        const e = err as BusinessError;
        if (!GrpcRcpChannel.isTransportError(e.code)) {
          throw new BusinessError(e.code, e.message);
        }
        // 传输层故障：换一个 IP 重建会话再试一次
        lastError = e;
        Log.warn(`gRPC(RCP) ${fullMethod} 传输失败 code=${e.code} ${e.message}，更换节点重试`);
        this.close();
        // 轮换 IP 顺序后重建会话，让下一次尝试优先连另一个节点
        this.rotateIps();
      }
    }

    throw lastError !== undefined
      ? lastError
      : new BusinessError(1007900028, 'gRPC 调用超时');
  }
}
