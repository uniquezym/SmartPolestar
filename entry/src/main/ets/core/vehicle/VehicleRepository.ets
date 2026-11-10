import { common } from '@kit.AbilityKit';
import { GrpcClient } from '../net/grpc/GrpcClient';
import { HttpClient } from '../net/HttpClient';
import { ServiceDiscovery } from '../net/ServiceDiscovery';
import { VehicleStateReader } from '../net/VehicleStateReader';
import { SessionState } from '../model/SessionState';
import { SessionStore } from '../session/SessionStore';
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
   */
  async loadSession(): Promise<SessionState> {
    const session = await SessionStore.load(this.context);
    if (session === undefined) {
      throw new BusinessError(401, '登录状态已失效，请重新登录');
    }
    this.session = session;
    return session;
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
   */
  async fetchVehicles(): Promise<string[]> {
    const client = await this.prepare();
    try {
      this.vins = await VehicleRepository.listVehicles(client.getSession());
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`拉取车辆列表失败: ${e.message}`);
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
