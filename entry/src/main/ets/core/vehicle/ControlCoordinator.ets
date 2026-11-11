import { common } from '@kit.AbilityKit';
import { GrpcClient } from '../net/grpc/GrpcClient';
import { VehicleCommands } from '../net/VehicleCommands';
import { SessionState } from '../model/SessionState';
import { AuthService } from '../session/AuthService';
import { BusinessError, Log } from '../../common/Log';

/**
 * 车控协调器 —— 串起「鉴权续期 -> 下发指令 -> 结果反馈」。
 *
 * 对应 Android 端 MainActivity 的车控调用链：
 *   m1412e0（token 续期）-> ga0.m1414h（下发指令）
 *
 * 关于生物识别：指纹验证**不在每次车控时触发**，而是集中在
 * 「应用从后台切回前台」这一个时机（见 ForegroundLock）。
 * 应用停留在前台期间，车控直接下发，不再打断用户。
 */
export class ControlCoordinator {
  private context: common.UIAbilityContext;
  private session: SessionState;
  private client: GrpcClient;

  constructor(context: common.UIAbilityContext, session: SessionState, client: GrpcClient) {
    this.context = context;
    this.session = session;
    this.client = client;
  }

  /**
   * 执行一次车辆控制。
   *
   * @param vin        车辆 VIN
   * @param action     动作标识
   * @param onResult   结果回调（true 表示成功）
   */
  async execute(vin: string, action: string, onResult: (success: boolean, message: string) => void): Promise<void> {
    const label = VehicleCommands.label(action);

    try {
      // 1. token 续期（对应 Android 端 m1412e0）
      await AuthService.refreshIfNeeded(this.context, this.session, false);
    } catch (err) {
      const e = err as BusinessError;
      onResult(false, e.message.length > 0 ? e.message : '登录状态已失效，请重新登录');
      return;
    }

    // 2. 下发指令
    try {
      await VehicleCommands.execute(this.client, vin, action);
      Log.info(`车控指令已执行: ${label} VIN…${vin.substring(vin.length - 6)}`);
      onResult(true, `${label}指令已发送`);
    } catch (err) {
      const e = err as BusinessError;
      Log.error(`车控指令失败: ${label} ${e.message}`);
      onResult(false, e.message.length > 0 ? e.message : `${label}失败`);
    }
  }
}
