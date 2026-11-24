import { common } from '@kit.AbilityKit';
import { VehicleRepository } from './VehicleRepository';
import { VehicleCapability } from './VehicleCapability';
import { VehicleCapabilityReader } from './VehicleCapabilityReader';
import { VehicleCapabilityStore } from './VehicleCapabilityStore';
import { Log } from '../../common/Log';

const TAG: string = 'VehicleCapabilityService';

/**
 * 车辆能力探测的编排入口。
 *
 * 负责：调用探测 → 落盘 → 供页面读取。
 */
export class VehicleCapabilityService {
  private context: common.Context;
  private repository: VehicleRepository;

  constructor(context: common.Context, repository: VehicleRepository) {
    this.context = context;
    this.repository = repository;
  }

  /**
   * 读取已持久化的能力快照（不发起网络请求）。
   *
   * 冷启动首帧用这个 —— 避免页面先显示「未知」再跳变。
   */
  loadCached(): VehicleCapability | undefined {
    return VehicleCapabilityStore.loadSync(this.context);
  }

  /**
   * 读取已持久化的能力快照（指定 VIN）。
   */
  async load(vin: string): Promise<VehicleCapability | undefined> {
    return await VehicleCapabilityStore.load(this.context, vin);
  }

  /**
   * 探测并持久化能力快照。
   *
   * @param vin 车辆 VIN；空串表示取账号下第一辆车
   * @returns 探测结果；网络异常时返回带错误信息的对象
   */
  async detect(vin: string): Promise<VehicleCapability | undefined> {
    try {
      const client = await this.repository.prepare();
      const session = client.getSession();
      const capability = await VehicleCapabilityReader.detect(session, vin);
      if (capability.fetched) {
        await VehicleCapabilityStore.save(this.context, capability);
      }
      return capability;
    } catch (err) {
      Log.error(TAG, `能力探测失败: ${(err as Error).message}`);
      return undefined;
    }
  }
}
