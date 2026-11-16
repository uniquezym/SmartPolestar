import { GrpcClient } from '../net/grpc/GrpcClient';
import { VehicleStateReader } from '../net/VehicleStateReader';
import { VehicleState } from '../model/VehicleState';
import { Log } from '../../common/Log';

/**
 * 状态域标识。
 */
export type StateDomain =
  'exterior' | 'climate' | 'air' | 'battery' | 'odometer' | 'health' | 'location';

/**
 * 单个状态域的流式订阅描述。
 */
interface StreamSpec {
  domain: StateDomain;
  /** gRPC 服务全名。 */
  service: string;
  /** SERVER_STREAMING 方法名。 */
  method: string;
  /** 把响应映射到状态对象。 */
  apply: (response: Uint8Array, state: VehicleState) => void;
  /** 是否走 LBS 主机（定位类接口在 LBS 主机上）。 */
  useLbs?: boolean;
  /** 请求体是否只带 VIN（dtlinternet 系接口用这种格式）。 */
  vinOnly?: boolean;
}

/**
 * 车辆状态流式订阅器。
 *
 * 对应原版 Android 的 `PccsController.cliinstanceof()`：
 * 每个状态域挂一条 SERVER_STREAMING 长连接，服务端在车端状态变化时
 * 主动往流里写新的一帧，客户端收到就更新 UI。
 *
 * 与原版的差别：
 *   - 原版用 Coroutine Flow + `flatMapLatest` 合流；这里用回调 +
 *     一个共享的 VehicleState，因为我们的状态是「聚合后一次性映射到 UI」，
 *     不需要流级别的操作符组合。
 *   - 原版每个域独立一个 StateFlow；这里所有域写进同一个 VehicleState，
 *     由上层决定何时取用。
 */
export class VehicleStateStream {
  /** 所有域的订阅描述。 */
  private static readonly SPECS: StreamSpec[] = [
    {
      domain: 'exterior',
      service: GrpcClient.SERVICE_EXTERIOR,
      method: GrpcClient.STREAM_METHOD_EXTERIOR,
      apply: (response: Uint8Array, state: VehicleState) =>
        VehicleStateReader.applyExterior(response, state)
    },
    {
      domain: 'climate',
      service: GrpcClient.SERVICE_CLIMATIZATION,
      method: GrpcClient.STREAM_METHOD_CLIMATIZATION,
      apply: (response: Uint8Array, state: VehicleState) =>
        VehicleStateReader.applyClimate(response, state)
    },
    {
      domain: 'air',
      service: GrpcClient.SERVICE_PRECLEANING,
      method: GrpcClient.STREAM_METHOD_PRECLEANING,
      apply: (response: Uint8Array, state: VehicleState) =>
        VehicleStateReader.applyAir(response, state)
    },
    {
      domain: 'battery',
      service: GrpcClient.SERVICE_BATTERY,
      method: GrpcClient.STREAM_METHOD_BATTERY,
      apply: (response: Uint8Array, state: VehicleState) =>
        VehicleStateReader.applyBattery(response, state)
    },
    {
      domain: 'odometer',
      service: GrpcClient.SERVICE_ODOMETER,
      method: GrpcClient.STREAM_METHOD_ODOMETER,
      apply: (response: Uint8Array, state: VehicleState) =>
        VehicleStateReader.applyOdometer(response, state)
    },
    {
      domain: 'health',
      service: GrpcClient.SERVICE_HEALTH,
      method: GrpcClient.STREAM_METHOD_HEALTH,
      apply: (response: Uint8Array, state: VehicleState) =>
        VehicleStateReader.applyHealth(response, state)
    },
    {
      // 最后停车位置。走 dtlinternet 服务 + LBS 主机，
      // 车端停车后服务端主动推送新坐标 —— 原版 Android 同款。
      domain: 'location',
      service: GrpcClient.SERVICE_DTL_INTERNET,
      method: GrpcClient.STREAM_METHOD_PARKED_LOCATION,
      apply: (response: Uint8Array, state: VehicleState) =>
        VehicleStateReader.applyParkedLocation(response, state),
      useLbs: true,
      vinOnly: true
    }
  ];

  private client: GrpcClient;
  private vin: string;
  /** 共享的状态对象。 */
  private state: VehicleState;
  /** 各域的取消函数。 */
  private cancels: Map<StateDomain, () => void> = new Map();
  /** 是否已订阅。 */
  private started: boolean = false;
  /** 已彻底断开的域（重试用尽或鉴权失效）。 */
  private brokenDomains: StateDomain[] = [];

  /**
   * 状态更新回调。参数为本次更新的域。
   */
  onUpdate?: (domain: StateDomain, state: VehicleState) => void;

  /**
   * 某个域的流断开时回调（正在安排重连）。
   */
  onStreamError?: (domain: StateDomain, message: string) => void;

  /**
   * 某个域的流彻底不可用时回调（重试用尽或鉴权失效）。
   */
  onStreamFatal?: (domain: StateDomain, message: string) => void;

  constructor(client: GrpcClient, vin: string, state: VehicleState) {
    this.client = client;
    this.vin = vin;
    this.state = state;
  }

  /**
   * 订阅所有状态域。
   *
   * 幂等 —— 重复调用不会重复订阅。
   */
  start(): void {
    if (this.started) {
      return;
    }
    this.started = true;
    this.brokenDomains = [];

    for (const spec of VehicleStateStream.SPECS) {
      const cancel = this.client.callStream(spec.service, spec.method, this.vin,
        (message: Uint8Array) => {
          try {
            spec.apply(message, this.state);
            this.onUpdate?.(spec.domain, this.state);
          } catch (err) {
            const e = err as Error;
            Log.warn(`流式状态解析失败(${spec.domain}): ${e.message}`);
          }
        },
        (message: string) => {
          this.onStreamError?.(spec.domain, message);
        },
        (message: string) => {
          this.markBroken(spec.domain);
          this.onStreamFatal?.(spec.domain, message);
        },
        spec.useLbs === true,
        spec.vinOnly === true);
      this.cancels.set(spec.domain, cancel);
    }

    Log.info(`已订阅 ${this.cancels.size} 个状态流`);
  }

  /**
   * 标记某个域的流已彻底断开。
   *
   * 同一个域可能重复上报（重连耗尽后每次重试都会回调），去重后再统计。
   */
  private markBroken(domain: StateDomain): void {
    if (this.brokenDomains.indexOf(domain) < 0) {
      this.brokenDomains.push(domain);
    }
  }

  /**
   * 取消所有订阅。
   */
  stop(): void {
    if (!this.started) {
      return;
    }
    this.started = false;
    this.cancels.forEach((cancel: () => void) => {
      cancel();
    });
    this.cancels.clear();
    this.brokenDomains = [];
    Log.info('已取消全部状态流订阅');
  }

  /**
   * 是否正在订阅。
   */
  isRunning(): boolean {
    return this.started;
  }

  /**
   * 是否所有状态流都已断开。
   *
   * 全部断开说明流式通道整体不可用，页面应退回定时轮询。
   */
  isAllBroken(): boolean {
    return this.brokenDomains.length >= VehicleStateStream.SPECS.length;
  }

  /**
   * 共享的状态对象。
   */
  getState(): VehicleState {
    return this.state;
  }
}
