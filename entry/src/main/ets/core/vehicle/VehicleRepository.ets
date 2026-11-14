import { common } from '@kit.AbilityKit';
import { GrpcClient } from '../net/grpc/GrpcClient';
import { HttpClient } from '../net/HttpClient';
import { ServiceDiscovery } from '../net/ServiceDiscovery';
import { VehicleStateReader } from '../net/VehicleStateReader';
import { SessionState } from '../model/SessionState';
import { SessionStore } from '../session/SessionStore';
import { AuthService } from '../session/AuthService';
import { VehicleState } from '../model/VehicleState';
import { BusinessError, Log } from '../../common/Log';

/**
 * 车辆数据仓储 —— 负责会话生命周期、服务发现与状态聚合。
 *
 * 对应 Android 端 ga0 的会话管理与 m1417m（拉取车辆列表）流程。
 */
export class VehicleRepository {
  private context: common.UIAbilityContext;
  private session: SessionState | undefined = undefined;
  private client: GrpcClient | undefined = undefined;
  /** 账号下的车辆 VIN 列表。 */
  private vins: string[] = [];

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  /**
   * 加载本地会话。若不存在则抛出「需重新登录」错误。
   *
   * 已有会话时**就地更新**而不是替换对象：GrpcClient 持有的是构造时传入的
   * SessionState 引用，若换成新对象，续期后写入的新 token 到不了 gRPC 通道手里。
   */
  async loadSession(): Promise<SessionState> {
    const stored = await SessionStore.load(this.context);
    if (stored === undefined) {
      throw new BusinessError(401, '登录状态已失效，请重新登录');
    }

    if (this.session === undefined) {
      this.session = stored;
      return stored;
    }

    this.session.accessToken = stored.accessToken;
    this.session.refreshToken = stored.refreshToken;
    this.session.expiresAt = stored.expiresAt;
    return this.session;
  }

  /**
   * 完成服务发现并创建 gRPC 客户端。
   */
  async prepare(): Promise<GrpcClient> {
    if (this.session === undefined) {
      await this.loadSession();
    }
    const session = this.session as SessionState;

    // 服务发现（仅在主机缺失时发起）
    await ServiceDiscovery.resolveHosts(session);
    Log.info(`C3 主机: ${session.c3Host} / LBS 主机: ${session.c3LbsHost}`);

    if (this.client === undefined) {
      this.client = new GrpcClient(this.context, session);
    }
    return this.client;
  }

  /**
   * 拉取账号下的车辆列表。
   *
   * 对应 Android 端 ga0.m1417m 的调用链：
   *   m1412e0(session, false)  先按需续期 token
   *   m1417m(session)          再拉列表（内部对 401 强制续期后重试一次）
   *
   * 早期实现把异常吞掉返回空列表，导致「账号下没有发现车辆」掩盖了真实的
   * 鉴权失败。现在异常向上抛出，由页面区分「会话失效」与「确实没有车」。
   */
  async fetchVehicles(): Promise<string[]> {
    const client = await this.prepare();
    const session = client.getSession();

    // ① 先按需续期，避免 access token 过期
    await AuthService.refreshIfNeeded(this.context, session, false);

    // ② 拉列表；服务端若判定 bearer 失效则强制续期后重试一次
    try {
      this.vins = await VehicleRepository.listVehicles(session);
    } catch (err) {
      const e = err as BusinessError;
      if (e.code === 401) {
        Log.info('车辆列表被拒（401），强制续期后重试一次');
        await AuthService.refreshIfNeeded(this.context, session, true);
        this.vins = await VehicleRepository.listVehicles(session);
      } else {
        throw new BusinessError(e.code, e.message);
      }
    }

    if (this.vins.length === 0) {
      Log.warn('车辆列表为空：账号下确实没有车辆');
    }
    return this.vins;
  }

  /**
   * 通过 C3 REST 接口获取车辆 VIN 列表。
   *
   * 还原自 ga0.m1417m：GET {c3Host}/car-information/car，递归搜索 VIN 字段。
   */
  static async listVehicles(session: SessionState): Promise<string[]> {
    const url = `https://${session.c3Host}/car-information/car`;
    const response = await HttpClient.request(url, 'GET', undefined, 'application/json', session.accessToken);
    return VehicleRepository.extractVins(response);
  }

  /**
   * 从响应中递归提取 VIN。
   *
   * 还原自 ga0.m1368f：递归遍历，匹配 vin / vehicleVin / vehicleIdentificationNumber 字段，
   * VIN 需满足正则 [A-HJ-NPR-Z0-9]{17}。
   */
  static extractVins(node: Object): string[] {
    const result: string[] = [];

    const visit = (current: Object): void => {
      if (Array.isArray(current)) {
        for (const item of current as Object[]) {
          visit(item);
        }
        return;
      }
      if (current === null || typeof current !== 'object') {
        return;
      }
      const obj = current as Record<string, Object>;
      for (const key of Object.keys(obj)) {
        const value = obj[key];
        if (key === 'vin' || key === 'vehicleVin' || key === 'vehicleIdentificationNumber') {
          const vin = value as string;
          if (vin !== undefined && vin.match(/^[A-HJ-NPR-Z0-9]{17}$/)) {
            result.push(vin);
          }
        } else if (value !== null && typeof value === 'object') {
          visit(value);
        }
      }
    };

    visit(node);
    return result;
  }

  /**
   * 读取单个状态域。用于车控指令下发后的生效确认（避免轮询全量状态）。
   *
   * 对应 Android 端 m1411d0 的分支：按动作前缀只读相关的那一个域。
   *
   * @param domain 'exterior' | 'climate' | 'air' | 'battery'
   * @param vin    车辆 VIN
   */
  async readDomain(domain: string, vin: string): Promise<VehicleState> {
    const client = await this.prepare();
    const state = new VehicleState();
    state.vin = vin;
    switch (domain) {
      case 'climate':
        await VehicleStateReader.readClimate(client, vin, state);
        break;
      case 'air':
        await VehicleStateReader.readAir(client, vin, state);
        break;
      case 'battery':
        await VehicleStateReader.readBattery(client, vin, state);
        break;
      default:
        await VehicleStateReader.readExterior(client, vin, state);
        break;
    }
    return state;
  }

  /**
   * 读取全部车辆状态。
   */
  async readAllStates(): Promise<VehicleState[]> {
    const client = await this.prepare();
    const vins = await this.fetchVehicles();
    const states: VehicleState[] = [];
    for (const vin of vins) {
      const state = new VehicleState();
      state.vin = vin;
      await VehicleStateReader.readAll(client, vin, state);
      states.push(state);
    }
    return states;
  }

  /**
   * 读取单辆车的状态。
   */
  async readState(vin: string): Promise<VehicleState> {
    const client = await this.prepare();
    const state = new VehicleState();
    state.vin = vin;
    await VehicleStateReader.readAll(client, vin, state);
    return state;
  }

  /**
   * 当前会话。
   */
  getSession(): SessionState | undefined {
    return this.session;
  }

  /**
   * gRPC 客户端。
   */
  getClient(): GrpcClient | undefined {
    return this.client;
  }

  /**
   * 退出登录。
   */
  async logout(): Promise<void> {
    if (this.client !== undefined) {
      this.client.close();
      this.client = undefined;
    }
    this.session = undefined;
    this.vins = [];
    await SessionStore.clear(this.context);
  }
}
