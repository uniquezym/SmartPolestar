import { GrpcRcpChannel } from './GrpcRcpChannel';
import { SessionState } from '../../model/SessionState';
import { AuthService } from '../../session/AuthService';
import { common } from '@kit.AbilityKit';
import { BusinessError, Log } from '../../../common/Log';

/**
 * gRPC 调用门面 —— 管理通道生命周期与鉴权重试。
 *
 * 对应 Android 端 p000.ga0 的 m1420w / m1421x：
 *   - 按 host 缓存通道（同一主机复用同一条 HTTP/2 连接）
 *   - UNAUTHENTICATED 时强制续期 token 并重试一次
 */
export class GrpcClient {
  /** C3 gRPC 服务全名。 */
  static readonly SERVICE_BATTERY: string = 'services.vehiclestates.battery.BatteryService';
  static readonly SERVICE_EXTERIOR: string = 'services.vehiclestates.exterior.ExteriorService';
  static readonly SERVICE_CLIMATIZATION: string =
    'services.vehiclestates.parkingclimatization.ParkingClimatizationService';
  static readonly SERVICE_PRECLEANING: string = 'services.vehiclestates.precleaning.PreCleaningService';
  static readonly SERVICE_ODOMETER: string = 'services.vehiclestates.odometer.OdometerService';
  static readonly SERVICE_HEALTH: string = 'services.vehiclestates.health.HealthService';
  static readonly SERVICE_CAR_INFO: string = 'car_information.CarInformation';
  static readonly SERVICE_INVOCATION: string = 'invocation.InvocationService';
  static readonly SERVICE_CLIMATE_TIMER: string = 'chronos.services.v1.ParkingClimateTimerService';
  static readonly SERVICE_DTL_INTERNET: string = 'dtlinternet.DtlInternetService';

  /**
   * 服务端流方法名 —— 对应各服务的 SERVER_STREAMING 方法。
   *
   * 每个状态服务都有「流式 + 快照」两条路：
   *   GetExterior          (SERVER_STREAMING) —— 车端状态一变就推一帧
   *   GetLatestExterior   (UNARY)           —— 一次性快照
   *
   * 原版 Android 走的是流式那条路，因此能秒级感知车端变化，
   * 不必像我们这样靠定时轮询。
   */
  static readonly STREAM_METHOD_EXTERIOR: string = 'GetExterior';
  static readonly STREAM_METHOD_BATTERY: string = 'GetBattery';
  static readonly STREAM_METHOD_CLIMATIZATION: string = 'GetParkingClimatization';
  static readonly STREAM_METHOD_PRECLEANING: string = 'GetPreCleaning';
  static readonly STREAM_METHOD_ODOMETER: string = 'GetOdometer';
  static readonly STREAM_METHOD_HEALTH: string = 'GetHealth';

  /** 单次调用默认超时（毫秒）。 */
  static readonly DEFAULT_TIMEOUT_MS: number = 12000;

  /**
   * 服务端流重连参数 —— 对齐原版 RetryPolicyKt。
   *
   * 原版：最大 3 次尝试，初始延迟 1000ms，退避倍数 2。
   */
  static readonly STREAM_MAX_ATTEMPTS: number = 3;
  static readonly STREAM_RETRY_BASE_MS: number = 1000;
  static readonly STREAM_RETRY_MULTIPLIER: number = 2;

  /** 空调定时相关调用的超时（毫秒）。 */
  static readonly TIMER_TIMEOUT_MS: number = 20000;

  private context: common.UIAbilityContext | undefined = undefined;
  private session: SessionState | undefined = undefined;
  /** 按主机缓存的通道。 */
  private channels: Map<string, GrpcRcpChannel> = new Map();
  /** 正在进行的 token 续期，用于串行化并发续期。 */
  private refreshing: Promise<void> | undefined = undefined;
  /**
   * 流彻底不可用时的回调（重试用尽或鉴权失效）。
   *
   * 由上层（VehicleRepository）设置，用来决定是放弃还是提示用户。
   */
  onStreamFatal?: (fullMethod: string, message: string) => void;

  constructor(context: common.UIAbilityContext, session: SessionState) {
    this.context = context;
    this.session = session;
  }

  /**
   * 获取（必要时建立）指定主机的通道。
   *
   * RCP 的 Session 内部维护连接池与 HTTP/2 多路复用，必须按主机复用同一 Session，
   * 否则每个请求都要重新握手。
   */
  private channel(host: string): GrpcRcpChannel {
    const existing = this.channels.get(host);
    if (existing !== undefined) {
      return existing;
    }
    const channel = new GrpcRcpChannel(host);
    this.channels.set(host, channel);
    return channel;
  }

  /**
   * 调用一个 gRPC 方法。
   *
   * @param service   服务全名
   * @param method    方法名
   * @param vin       车辆 VIN
   * @param payload   请求负载
   * @param timeoutMs 超时
   * @param useLbs    是否走 LBS 主机
   */
  async call(service: string, method: string, vin: string, payload: Uint8Array,
    timeoutMs: number = GrpcClient.DEFAULT_TIMEOUT_MS, useLbs: boolean = false): Promise<Uint8Array> {
    if (this.session === undefined) {
      throw new BusinessError(-1, '会话未初始化');
    }

    const host = useLbs ? this.session.c3LbsHost : this.session.c3Host;
    if (host.length === 0) {
      throw new BusinessError(-1, 'C3 主机未解析，请先完成服务发现');
    }

    const fullMethod = `${service}/${method}`;

    for (let attempt = 0; attempt < 2; attempt++) {
      const channel = this.channel(host);
      try {
        return await channel.call(fullMethod, this.session.accessToken, vin, payload, timeoutMs);
      } catch (err) {
        const e = err as BusinessError;
        if (!GrpcClient.isUnauthenticated(e)) {
          if (err instanceof Error) {
            throw err;
          }
          throw new BusinessError(e.code, e.message);
        }
        if (attempt !== 0) {
          // 已经续期过一次仍被拒：登录态确实失效了，交给调用方处理。
          // 这里**不再续期** —— 刷新接口会轮换 refresh token，
          // 用同一个 refresh token 连续调两次可能让服务端把旧的那个作废，
          // 反而把用户踢出登录。
          throw new BusinessError(401, '登录状态已失效，请重新登录');
        }
        // token 被拒：强制续期后重试一次
        Log.info(`C3 拒绝 access token（${e.message}），刷新后重试一次`);
        if (this.context !== undefined) {
          await AuthService.refreshIfNeeded(this.context, this.session, true);
        }
      }
    }
    throw new BusinessError(401, '登录状态已失效，请重新登录');
  }

  /**
   * 调用一个状态查询接口（请求体仅含 VIN，field 2 = VIN）。
   *
   * 对应 Android 端 ga0.m1418m0 -> m1389s0(vin, 2)：tag = (2 << 3) | 2 = 0x12。
   *
   * 注意 field 1 不是 VIN：Android 端 field 1 存的是请求 UUID 或语言码
   * （见 m1366d / m1408W），VIN 一律放 field 2。放错字段服务端会返回
   * grpc-status 7 (PERMISSION_DENIED)。
   */
  async callStatus(service: string, method: string, vin: string): Promise<Uint8Array> {
    const vinBytes = GrpcClient.utf8(vin);
    // tag 0x12 = field 2, wire type 2 (length-delimited)
    const payload = new Uint8Array(vinBytes.length + 2);
    payload[0] = 0x12;
    payload[1] = vinBytes.length;
    payload.set(vinBytes, 2);
    return await this.call(service, method, vin, payload);
  }

  /**
   * 订阅一个服务端流式状态。
   *
   * 与原版 Android 的 Flow 订阅等价：
   *   - 请求体与快照方法完全一致（field 1 = UUID，field 2 = VIN）
   *   - 服务端在车端状态变化时主动往同一条流里写新的一帧
   *   - 断流后按指数退避重连（对齐原版 RetryPolicy：3 次尝试，1s 起步，×2）
   *
   * 三种回调要分清：
   *   onMessage    收到一帧数据
   *   onDisconnect 流断开（可能是暂时的，正在安排重连）
   *   onFatal     重试用尽或鉴权续期仍失败，这条流不会再自动恢复
   *
   * @param service      服务全名，如 `services.vehiclestates.exterior.ExteriorService`
   * @param method       流式方法名，如 `GetExterior`
   * @param vin          车辆 VIN
   * @param onMessage    每收到一帧时回调（裸 protobuf）
   * @param onDisconnect 流断开时回调（会尝试重连）
   * @param onFatal      流彻底不可用时回调
   * @returns 取消订阅的函数
   */
  callStream(service: string, method: string, vin: string,
    onMessage: (message: Uint8Array) => void,
    onDisconnect: (message: string) => void,
    onFatal: (message: string) => void): () => void {
    if (this.session === undefined) {
      onFatal('会话未初始化');
      return (): void => {};
    }

    const host = this.session.c3Host;
    if (host.length === 0) {
      onFatal('C3 主机未解析，请先完成服务发现');
      return (): void => {};
    }

    const fullMethod = `${service}/${method}`;

    let cancelCurrent: (() => void) | undefined = undefined;
    let stopped = false;
    let attempt = 0;
    let retryTimer: number = -1;

    /**
     * 拉起一条流。
     */
    const start = (): void => {
      if (stopped) {
        return;
      }
      const channel = this.channel(host);
      const session = this.session;
      const token = session !== undefined ? session.accessToken : '';

      cancelCurrent = channel.callStream(fullMethod, token, vin,
        GrpcClient.buildStreamRequest(vin),
        (message: Uint8Array) => {
          // 收到数据说明流是活的，重置重试计数
          attempt = 0;
          onMessage(message);
        },
        (error: string | null) => {
          cancelCurrent = undefined;
          if (stopped) {
            return;
          }
          if (error === null) {
            // 服务端正常关闭了流，也要重连 —— 车端状态还需要持续跟踪
            Log.info(`gRPC 流 ${fullMethod} 被服务端关闭，准备重连`);
            onDisconnect('服务端关闭了流');
          } else {
            Log.warn(`gRPC 流 ${fullMethod} 断开: ${error}`);
            onDisconnect(error);
          }
          this.scheduleReconnect(fullMethod, start, error, attempt, (delay: number) => {
            retryTimer = setTimeout(() => {
              retryTimer = -1;
              attempt++;
              start();
            }, delay);
          }, onFatal);
        });
    };

    start();
    return (): void => {
      stopped = true;
      if (retryTimer !== -1) {
        clearTimeout(retryTimer);
        retryTimer = -1;
      }
      if (cancelCurrent !== undefined) {
        cancelCurrent();
        cancelCurrent = undefined;
      }
    };
  }

  /**
   * 流断开后的退避重连。
   *
   * 对齐原版 RetryPolicyKt：最多 3 次尝试，初始延迟 1 秒，倍数 2（1s → 2s → 4s）。
   * 超过上限后通知调用方，由上层决定是否放弃。
   *
   * 鉴权失败时先续期 token 再重连 —— 拿旧 token 重连只会连续被拒。
   * 续期也失败（登录态真的没了）才判定为彻底不可用。
   */
  private scheduleReconnect(fullMethod: string, start: () => void, error: string | null,
    attempt: number, schedule: (delay: number) => void, onFatal: (message: string) => void): void {
    if (error !== null && GrpcClient.isUnauthenticatedMessage(error)) {
      Log.warn(`gRPC 流 ${fullMethod} 鉴权失效，尝试续期 token`);
      this.refreshForStream(fullMethod, error, start, onFatal);
      return;
    }

    if (attempt >= GrpcClient.STREAM_MAX_ATTEMPTS) {
      Log.error(`gRPC 流 ${fullMethod} 重连 ${attempt} 次仍失败，放弃`);
      const message = error ?? '服务端关闭了流';
      onFatal(message);
      this.onStreamFatal?.(fullMethod, message);
      return;
    }

    const delay = GrpcClient.STREAM_RETRY_BASE_MS * Math.pow(GrpcClient.STREAM_RETRY_MULTIPLIER, attempt);
    Log.info(`gRPC 流 ${fullMethod} ${delay}ms 后重连（第 ${attempt + 1} 次）`);
    schedule(delay);
  }

  /**
   * 续期 token 后重连流。
   *
   * 长连接的 token 会被服务端在连接期间校验，token 过期时流会被断开。
   * 续期成功后用新 token 重连；续期失败说明登录态真的没了，
   * 这时通知上层退回轮询（轮询路径会走 401 处理，把用户带回登录页）。
   */
  private refreshForStream(fullMethod: string, error: string,
    start: () => void, onFatal: (message: string) => void): void {
    const context = this.context;
    const session = this.session;
    if (context === undefined || session === undefined) {
      onFatal(error);
      this.onStreamFatal?.(fullMethod, error);
      return;
    }

    this.refreshTokenOnce().then(() => {
      Log.info(`gRPC 流 ${fullMethod} token 已续期，立即重连`);
      start();
    }).catch((err: BusinessError) => {
      Log.error(`gRPC 流 ${fullMethod} token 续期失败: ${err.message}`);
      onFatal(err.message);
      this.onStreamFatal?.(fullMethod, err.message);
    });
  }

  /**
   * 强制续期 token，同一时刻只跑一次。
   *
   * 六个状态流会在同一刻先后被服务端判定鉴权失效。
   * 续期接口会轮换 refresh token，并发调用会让服务端把旧的那个作废，
   * 反而把用户踢出登录 —— 因此必须串行化。
   */
  private refreshTokenOnce(): Promise<void> {
    const context = this.context;
    const session = this.session;
    if (context === undefined || session === undefined) {
      return Promise.reject(new BusinessError(-1, '会话未初始化'));
    }
    if (this.refreshing !== undefined) {
      return this.refreshing;
    }
    const task = AuthService.refreshIfNeeded(context, session, true);
    this.refreshing = task;
    return task.finally(() => {
      this.refreshing = undefined;
    });
  }

  /**
   * 构造服务端流的请求体。
   *
   * 与快照方法一致：field 1 = 请求 UUID，field 2 = VIN。
   */
  private static buildStreamRequest(vin: string): Uint8Array {
    const uuidBytes = GrpcClient.utf8(GrpcClient.newUuid());
    const vinBytes = GrpcClient.utf8(vin);
    const payload = new Uint8Array(uuidBytes.length + vinBytes.length + 4);

    let offset = 0;
    // field 1 = request id
    payload[offset++] = 0x0a;
    payload[offset++] = uuidBytes.length;
    payload.set(uuidBytes, offset);
    offset += uuidBytes.length;
    // field 2 = VIN
    payload[offset++] = 0x12;
    payload[offset++] = vinBytes.length;
    payload.set(vinBytes, offset);

    return payload;
  }

  /**
   * 生成 UUID v4。
   */
  private static newUuid(): string {
    return 'xxxxxxxx-xxxx-4xxx-yyyy-xxxxxxxxxxxx'.replace(/[xy]/g, (c: string) => {
      const r = Math.random() * 16 | 0;
      const v = c === 'x' ? r : (r & 0x3 | 0x8);
      return v.toString(16);
    });
  }

  /**
   * 判断异常是否为鉴权失败（需要续期 token 后重试）。
   *
   * 两种表现都要认：
   *   1. HTTP 401 / 403 —— 通道层抛的 `UNAUTHENTICATED: HTTP 401`
   *   2. **gRPC `grpc-status 16`** —— 服务端的正常鉴权失败返回，
   *      消息形如 `gRPC 错误: status=16 Unauthorized: expired_token`
   *
   * 第 2 种是实际会遇到的：服务端用标准的 grpc-status 16 表示
   * token 过期，HTTP 层仍是 200。只认 `UNAUTHENTICATED` 字样的话，
   * 续期重试永远不触发，token 一过期所有请求就全部报错。
   */
  static isUnauthenticated(err: BusinessError): boolean {
    return GrpcClient.isUnauthenticatedMessage(err.message);
  }

  /**
   * 按消息文本判断是否为鉴权失败。
   *
   * 拆出来是因为流式重连拿到的是纯字符串，没有 BusinessError 包装。
   */
  static isUnauthenticatedMessage(message: string | undefined): boolean {
    if (message === undefined || message.length === 0) {
      return false;
    }
    // HTTP 层的 401 / 403
    if (message.indexOf('UNAUTHENTICATED') >= 0) {
      return true;
    }
    // gRPC status 16 = UNAUTHENTICATED（见 io.grpc.Status.Code）
    if (message.indexOf('status=16') >= 0) {
      return true;
    }
    // 服务端的过期措辞兜底
    if (message.indexOf('expired_token') >= 0 ||
      message.indexOf('Unauthorized') >= 0) {
      return true;
    }
    return false;
  }

  /**
   * 当前会话。
   */
  getSession(): SessionState {
    return this.session as SessionState;
  }

  /**
   * 关闭所有通道。
   */
  close(): void {
    this.channels.forEach((channel: GrpcRcpChannel) => {
      channel.close();
    });
    this.channels.clear();
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
}
