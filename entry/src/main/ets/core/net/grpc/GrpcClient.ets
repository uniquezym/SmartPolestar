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

  /** 单次调用默认超时（毫秒）。 */
  static readonly DEFAULT_TIMEOUT_MS: number = 12000;

  /** 空调定时相关调用的超时（毫秒）。 */
  static readonly TIMER_TIMEOUT_MS: number = 20000;

  private context: common.UIAbilityContext | undefined = undefined;
  private session: SessionState | undefined = undefined;
  /** 按主机缓存的通道。 */
  private channels: Map<string, GrpcRcpChannel> = new Map();

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
          // 续期后仍被拒：清空本地登录态
          if (this.context !== undefined) {
            await AuthService.refreshIfNeeded(this.context, this.session, true);
          }
          throw new BusinessError(401, '登录状态已失效，请重新登录');
        }
        // token 被拒：强制续期后重试一次
        Log.info('C3 拒绝 access token，刷新后重试一次');
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
   * 判断异常是否为 UNAUTHENTICATED。
   */
  static isUnauthenticated(err: BusinessError): boolean {
    return err.message !== undefined && err.message.indexOf('UNAUTHENTICATED') >= 0;
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
