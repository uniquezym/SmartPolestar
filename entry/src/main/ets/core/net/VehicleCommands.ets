import { GrpcClient } from './grpc/GrpcClient';
import { ProtoWriter } from '../proto/ProtoWriter';
import { BusinessError } from '../../common/Log';

/**
 * 车辆远程控制指令 —— 对应 Android 端 p000.ga0.m1414h。
 *
 * 统一走 invocation.InvocationService，按动作名分派到不同 RPC，
 * 并在请求体中写入对应的枚举字段。
 *
 * 请求体结构（还原自 m1414h）：
 *   field 1 (string)  VIN
 *   field 2 (varint)  动作枚举
 *   field 3 (fixed32) 目标温度，仅 ClimatizationStart 使用（22.0f）
 */
export class VehicleCommands {
  /** 全部支持的动作标识。对应 p000.qr0.f4358d。 */
  static readonly ACTION_IDS: string[] = [
    'unlock', 'lock', 'unlock-trunk', 'lock-trunk', 'trunk-open', 'trunk-close',
    'windows-open', 'windows-close'
  ];

  /** 动作的中文文案。对应 p000.qr0.f4359e。 */
  static readonly ACTION_LABELS: string[] = [
    '解锁车辆', '锁定车辆', '解锁尾门', '锁定尾门',
    '打开尾门', '关闭尾门', '打开全部车窗', '关闭全部车窗'
  ];

  /** 车锁动作。 */
  static readonly ACTION_UNLOCK: string = 'unlock';
  static readonly ACTION_LOCK: string = 'lock';
  static readonly ACTION_UNLOCK_TRUNK: string = 'unlock-trunk';
  static readonly ACTION_LOCK_TRUNK: string = 'lock-trunk';

  /** 驻车空调与空气净化动作。 */
  static readonly ACTION_CLIMATE_START: string = 'climate-start';
  static readonly ACTION_CLIMATE_STOP: string = 'climate-stop';
  static readonly ACTION_AIR_START: string = 'air-purification-start';
  static readonly ACTION_AIR_STOP: string = 'air-purification-stop';

  /** 寻车动作。 */
  static readonly ACTION_HONK: string = 'honk';
  static readonly ACTION_FLASH: string = 'flash';
  static readonly ACTION_HONK_FLASH: string = 'honk-flash';

  /** 尾门控制动作。 */
  static readonly ACTION_TRUNK_OPEN: string = 'trunk-open';
  static readonly ACTION_TRUNK_CLOSE: string = 'trunk-close';

  /** 车窗控制动作。 */
  static readonly ACTION_WINDOWS_OPEN: string = 'windows-open';
  static readonly ACTION_WINDOWS_CLOSE: string = 'windows-close';

  /** 空调启动的目标温度（固定 22.0，与 Android 端一致）。 */
  static readonly CLIMATE_TARGET_TEMPERATURE: number = 22.0;

  /**
   * 执行一次车辆控制指令。
   *
   * @param client    gRPC 客户端
   * @param vin       车辆 VIN
   * @param action    动作标识
   * @param timeoutMs 超时
   */
  static async execute(client: GrpcClient, vin: string, action: string,
    timeoutMs: number = GrpcClient.DEFAULT_TIMEOUT_MS): Promise<void> {
    const writer = new ProtoWriter();
    // field 1 = 嵌套消息，其内部 field 1 = VIN
    // 还原自 Android 端 m1364c(1, m1389s0(vin, 1))：外层 field 1 是一段
    // length-delimited 字节，字节内容才是「field 1 = VIN」。与状态查询接口
    // 直接把 VIN 放在 field 2 的写法不同，两种结构不可混用。
    const vinBytes = ProtoWriter.encodeUtf8(vin);
    const inner = ProtoWriter.concat(
      ProtoWriter.writeVarint(0x0a),
      ProtoWriter.writeVarint(vinBytes.length),
      vinBytes
    );
    writer.writeBytesField(1, inner);

    let rpcMethod = '';

    switch (action) {
      case VehicleCommands.ACTION_HONK:
      case VehicleCommands.ACTION_FLASH:
      case VehicleCommands.ACTION_HONK_FLASH: {
        // 0=鸣笛并闪灯, 1=仅鸣笛, 2=仅闪灯
        const honkFlash = action === VehicleCommands.ACTION_HONK ? 1 :
          (action === VehicleCommands.ACTION_FLASH ? 2 : 0);
        writer.writeVarintField(2, honkFlash);
        rpcMethod = 'HonkFlash';
        break;
      }

      case VehicleCommands.ACTION_TRUNK_OPEN:
      case VehicleCommands.ACTION_TRUNK_CLOSE:
        writer.writeVarintField(2, action === VehicleCommands.ACTION_TRUNK_OPEN ? 1 : 2);
        rpcMethod = 'TailgateControl';
        break;

      case VehicleCommands.ACTION_AIR_START:
      case VehicleCommands.ACTION_AIR_STOP:
        writer.writeVarintField(2, action.endsWith('start') ? 1 : 0);
        rpcMethod = 'PreCleaning';
        break;

      case VehicleCommands.ACTION_UNLOCK:
        // 整车解锁：不带 field 2。
        // 还原自 ga0.m1414h 的 case 3 —— 原版只有 unlock-trunk 才追加
        // field 2 = 1。写了未知枚举值服务端会报
        // "Can't get the number of an unknown enum value"。
        rpcMethod = 'Unlock';
        break;

      case VehicleCommands.ACTION_LOCK:
        // 整车锁：Lock RPC + 动作枚举 0
        writer.writeVarintField(2, 0);
        rpcMethod = 'Lock';
        break;

      case VehicleCommands.ACTION_LOCK_TRUNK:
        // 尾门锁：Lock RPC + 动作枚举 1
        writer.writeVarintField(2, 1);
        rpcMethod = 'Lock';
        break;

      case VehicleCommands.ACTION_UNLOCK_TRUNK:
        writer.writeVarintField(2, 1);
        rpcMethod = 'Unlock';
        break;

      case VehicleCommands.ACTION_WINDOWS_OPEN:
      case VehicleCommands.ACTION_WINDOWS_CLOSE:
        writer.writeVarintField(2, action === VehicleCommands.ACTION_WINDOWS_OPEN ? 1 : 2);
        rpcMethod = 'WindowControl';
        break;

      case VehicleCommands.ACTION_CLIMATE_START:
        // 目标温度固定 22.0f（field 3, fixed32）
        // 还原自 ga0.m1414h 的 case 8：先写 field 2 = 1，再写 field 3。
        writer.writeVarintField(2, 1);
        writer.writeFixed32Field(3, VehicleCommands.CLIMATE_TARGET_TEMPERATURE);
        rpcMethod = 'ClimatizationStart';
        break;

      case VehicleCommands.ACTION_CLIMATE_STOP:
        rpcMethod = 'ClimatizationStop';
        break;

      default:
        throw new BusinessError(-1, `不支持的控制动作：${action}`);
    }

    await client.call(GrpcClient.SERVICE_INVOCATION, rpcMethod, vin, writer.toUint8Array(), timeoutMs);
  }

  /**
   * 把控制动作 ID 映射为中文文案。
   */
  static label(action: string): string {
    for (let i = 0; i < VehicleCommands.ACTION_IDS.length; i++) {
      if (VehicleCommands.ACTION_IDS[i] === action) {
        return VehicleCommands.ACTION_LABELS[i];
      }
    }
    switch (action) {
      case VehicleCommands.ACTION_CLIMATE_START:
        return '开启空调';
      case VehicleCommands.ACTION_CLIMATE_STOP:
        return '关闭空调';
      case VehicleCommands.ACTION_AIR_START:
        return '开启空气净化';
      case VehicleCommands.ACTION_AIR_STOP:
        return '关闭空气净化';
      case VehicleCommands.ACTION_HONK:
        return '鸣笛';
      case VehicleCommands.ACTION_FLASH:
        return '闪灯';
      case VehicleCommands.ACTION_HONK_FLASH:
        return '鸣笛并闪灯';
      default:
        return action;
    }
  }
}
