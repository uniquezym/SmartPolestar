import { http } from '@kit.NetworkKit';
import { BusinessError, Log } from '../../../common/Log';

/**
 * gRPC unary 调用的 HTTP 传输层。
 *
 * 背景：HarmonyOS 的 TLSSocket 访问 C3 后端时，netstack 的 secure_data 构建失败
 * （[secure_data.cpp:30] memcpy_s failed!），SNI/ALPN 一并丢失，服务端收到数据后
 * 直接断开，收不到任何响应。改用系统 HTTP 栈（已验证可连该后端并协商 HTTP/2）。
 *
 * gRPC 一元调用在 HTTP/2 上的约定：
 *   POST /<service>/<method>
 *   content-type: application/grpc
 *   te: trailers
 *   请求体 = 1 字节压缩标志(0) + 4 字节大端长度 + protobuf
 *   响应体 = 同格式的一帧（可能为空）
 */
export class GrpcHttpChannel {
  private host: string;

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
    // 组装 gRPC 消息帧
    const frame = new Uint8Array(5 + payload.length);
    frame[0] = 0;
    frame[1] = (payload.length >>> 24) & 0xff;
    frame[2] = (payload.length >>> 16) & 0xff;
    frame[3] = (payload.length >>> 8) & 0xff;
    frame[4] = payload.length & 0xff;
    frame.set(payload, 5);

    const headers: Record<string, string> = {
      'content-type': 'application/grpc',
      'te': 'trailers',
      'grpc-encoding': 'identity',
      'grpc-accept-encoding': 'identity',
      'authorization': `Bearer ${token}`,
      'vin': vin,
      'user-agent': 'grpc-java-okhttp/1.85.1'
    };

    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.POST,
        header: headers,
        extraData: frame.buffer as ArrayBuffer,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        /**
         * 必须强制 HTTP/2。
         *
         * 该后端前面是 AWS ELB（Server: awselb/2.0），目标组为 gRPC/HTTP2。
         * 若客户端用 HTTP/1.1 语义发送，ELB 会直接返回 464
         * （"Load Balancer received an incompatible request protocol"），
         * 请求根本进不到 gRPC 业务层。
         */
        usingProtocol: http.HttpProtocol.HTTP2,
        connectTimeout: timeoutMs,
        readTimeout: timeoutMs,
        usingCache: false
      };
      const url = `https://${this.host}/${fullMethod}`;
      const resp = await request.request(url, options);
      const status = resp.responseCode as number;
      Log.info(`gRPC(HTTP) ${fullMethod} status=${status}`);

      if (status !== 200) {
        // 打印响应头，服务端拒绝时通常在 header 里给出原因
        Log.error(`gRPC 响应头: ${JSON.stringify(resp.header)}`);
        const raw = resp.result;
        if (raw instanceof ArrayBuffer) {
          const body = new Uint8Array(raw);
          Log.error(`gRPC 响应体 ${body.length} 字节: ${GrpcHttpChannel.hexPreview(body)}`);
        } else if (typeof raw === 'string') {
          Log.error(`gRPC 响应体: ${raw}`);
        }
        if (status === 401 || status === 403) {
          throw new BusinessError(status, `UNAUTHENTICATED: HTTP ${status}`);
        }
        throw new BusinessError(status, `gRPC HTTP 错误: ${status}`);
      }

      const result = resp.result;
      if (!(result instanceof ArrayBuffer)) {
        throw new BusinessError(-1, 'gRPC 响应体不是二进制');
      }
      const bytes = new Uint8Array(result);
      if (bytes.length < 5) {
        return new Uint8Array(0);
      }
      const length = ((bytes[1] << 24) | (bytes[2] << 16) | (bytes[3] << 8) | bytes[4]) >>> 0;
      if (length === 0 || 5 + length > bytes.length) {
        return bytes.slice(5);
      }
      return bytes.slice(5, 5 + length);
    } catch (err) {
      if (err instanceof Error) {
        throw err;
      }
      const e = err as BusinessError;
      throw new BusinessError(e.code, `gRPC(HTTP) 调用失败: ${e.message}`);
    } finally {
      request.destroy();
    }
  }

  /**
   * HTTP 传输无长连接需要关闭。
   */
  close(): void {
    return;
  }

  /**
   * 十六进制预览，用于日志定位。
   */
  private static hexPreview(data: Uint8Array): string {
    const max = Math.min(data.length, 96);
    let out = '';
    for (let i = 0; i < max; i++) {
      const v = data[i];
      out += (v < 16 ? '0' : '') + v.toString(16);
    }
    return out;
  }
}
