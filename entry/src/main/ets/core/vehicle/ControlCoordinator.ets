import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { GrpcClient } from '../net/grpc/GrpcClient';
import { VehicleCommands } from '../net/VehicleCommands';
import { BiometricGuard, BiometricResult } from './BiometricGuard';
import { SessionState } from '../model/SessionState';
import { AuthService } from '../session/AuthService';
import { BusinessError, Log } from '../../common/Log';

/**
 * 车控协调器 —— 串起「鉴权续期 -> 生物识别确认 -> 下发指令 -> 结果反馈」。
 *
 * 对应 Android 端 MainActivity 的车控调用链：
 *   m1412e0（token 续期）-> C0126d5/C0353jd（指纹确认）-> ga0.m1414h（下发指令）
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
   * 执行一次带确认的车辆控制。
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

    // 2. 生物识别确认
    const capability = await BiometricGuard.checkAvailable();
    if (capability !== BiometricResult.SUCCESS) {
      // 指纹不可用时降级为二次确认（对应 Android 端 m485p）
      const confirmed = await ControlCoordinator.confirmFallback(label, capability);
      if (!confirmed) {
        onResult(false, '已取消');
        return;
      }
    } else {
      const verifyResult = await BiometricGuard.verify(`确认车辆操作：${label}`);
      if (verifyResult !== BiometricResult.SUCCESS) {
        onResult(false, '已取消');
        return;
      }
    }

    // 3. 下发指令
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

  /**
   * 指纹不可用时的降级确认框。
   */
  private static async confirmFallback(label: string, capability: number): Promise<boolean> {
    const message = BiometricGuard.fallbackMessage(capability);
    return await new Promise<boolean>((resolve) => {
      try {
        promptAction.showDialog({
          title: '确认车辆操作',
          message: `${message}\n\n即将执行：${label}`,
          buttons: [
            { text: '取消', color: '#6f675c' },
            { text: '确认并执行', color: '#b8442a' }
          ]
        }).then((result) => {
          resolve(result.index === 1);
        }).catch(() => {
          resolve(false);
        });
      } catch (err) {
        resolve(false);
      }
    });
  }
}
