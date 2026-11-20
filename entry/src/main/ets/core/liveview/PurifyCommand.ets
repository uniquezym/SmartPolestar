import { common } from '@kit.AbilityKit';
import { VehicleRepository } from '../vehicle/VehicleRepository';
import { ControlCoordinator } from '../vehicle/ControlCoordinator';
import { VehicleCommands } from '../net/VehicleCommands';
import { LiveViewManager } from './LiveViewManager';
import { BusinessError, Log } from '../../common/Log';

/**
 * 实况窗「停止净化」的静默执行链路。
 *
 * 流程：
 *   加载会话 → 拉车辆列表 → 下发关闭指令 → 轮询车端确认 → 销毁实况窗
 *
 * 【为什么不走指纹与二次确认】
 * 空气净化只是车内循环过滤，停掉的代价很低；
 * 而实况窗是「随手点一下」的快捷操作，
 * 弹指纹框会把用户从当前界面拉走，体验反而更差。
 *
 * 【销毁时机】
 * 必须等车端确认已关闭才销毁实况窗 ——
 * 指令刚发出去就销毁的话，用户会以为关掉了，
 * 但车还在继续净化，且失去了实况窗这个唯一的反馈出口。
 */
export class PurifyCommand {
  /** 轮询确认的最长等待时长（毫秒）。 */
  private static readonly BUDGET_MS: number = 12000;

  /** 是否正在执行关闭，防止连点造成重复下发。 */
  private static running: boolean = false;

  /**
   * 执行「停止净化」。
   *
   * @param context UIAbility 上下文
   */
  static async stop(context: common.UIAbilityContext): Promise<void> {
    if (PurifyCommand.running) {
      return;
    }
    PurifyCommand.running = true;
    try {
      await PurifyCommand.execute(context);
    } finally {
      PurifyCommand.running = false;
    }
  }

  /**
   * 关闭流程本体。
   */
  private static async execute(context: common.UIAbilityContext): Promise<void> {
    const repository = new VehicleRepository(context);

    // 1. 会话与车辆
    let vin: string = '';
    try {
      await repository.loadSession();
      const vins = await repository.fetchVehicles();
      if (vins.length === 0) {
        Log.warn('实况窗停止净化：账号下没有车辆');
        return;
      }
      vin = vins[0];
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`实况窗停止净化：会话不可用 code=${e.code} ${e.message}`);
      return;
    }

    const session = repository.getSession();
    const client = repository.getClient();
    if (session === undefined || client === undefined) {
      Log.warn('实况窗停止净化：会话未就绪');
      return;
    }

    // 2. 下发关闭指令
    let sent: boolean = false;
    try {
      const coordinator = new ControlCoordinator(context, session, client);
      await coordinator.execute(vin, VehicleCommands.ACTION_AIR_STOP, (success: boolean, message: string) => {
        sent = success;
        if (!success) {
          Log.warn(`实况窗停止净化：指令下发失败 ${message}`);
        }
      });
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`实况窗停止净化：指令下发异常 code=${e.code} ${e.message}`);
      return;
    }
    if (!sent) {
      // 指令没发出去 —— 保持实况窗存在，让用户还能再试一次
      return;
    }

    // 3. 轮询确认车端已关闭
    const confirmed = await PurifyCommand.confirmClosed(repository, vin);
    if (!confirmed) {
      // 车端还没推进到终态 —— 指令确实已下发，实况窗先留着
      Log.info('实况窗停止净化：指令已发送，等待车端确认');
      return;
    }

    // 4. 确认关闭 —— 销毁实况窗
    await LiveViewManager.stop(context);
    Log.info('实况窗停止净化：车端已关闭，实况窗已销毁');
  }

  /**
   * 轮询车端直到确认净化已关闭。
   *
   * @param repository 仓储
   * @param vin        车辆 VIN
   * @returns 车端是否已确认关闭
   */
  private static async confirmClosed(repository: VehicleRepository, vin: string): Promise<boolean> {
    const startedAt: number = Date.now();
    let interval: number = 300;
    while (Date.now() - startedAt < PurifyCommand.BUDGET_MS) {
      await PurifyCommand.delay(interval);
      interval = Math.min(1200, interval + 250);
      try {
        const state = await repository.readDomain('air', vin);
        if (state.air === '关闭') {
          return true;
        }
      } catch (err) {
        Log.warn(`实况窗停止净化：状态读取失败 ${(err as Error).message}`);
      }
    }
    return false;
  }

  /**
   * 延时。
   */
  private static delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}
