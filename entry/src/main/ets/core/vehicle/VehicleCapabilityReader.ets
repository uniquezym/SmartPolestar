import { SessionState } from '../model/SessionState';
import { HttpClient } from '../net/HttpClient';
import { VehicleCapability } from './VehicleCapability';
import { BusinessError, Log } from '../../common/Log';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'VehicleCapabilityReader';

/**
 * 车辆能力探测 —— 读取 car-information 接口里的能力字段。
 *
 * 接口：`GET {c3Host}/car-information/car`
 *
 * 响应是一个数组，每一项是一辆车的完整档案。
 * 其中一组 `supports*` / `reports*` 布尔字段就是官方 App 用来决定
 * 「某个功能按钮是否出现」的能力开关 ——
 * 还原自官方 `CarInformationGsonDeserializer`。
 *
 * 另有 12 个数值型限制（上限、电流范围、温度范围、计时器数量…）
 * 与若干档案字段（车型、车牌、驱动位、数字钥匙类型…）。
 *
 * 我们现有工程已经调过这个接口，但只从里面提取 VIN ——
 * 现在把完整档案留下来，能力字段就有了。
 */
export class VehicleCapabilityReader {
  /**
   * 车辆档案接口的路径（相对于 c3Host）。
   */
  static readonly PATH_CAR_INFORMATION: string = 'car-information/car';

  /**
   * 探测一台车的能力。
   *
   * @param session 会话上下文
   * @param vin     目标车辆 VIN；空串表示取第一辆
   */
  static async detect(session: SessionState, vin: string): Promise<VehicleCapability> {
    const cap = new VehicleCapability();
    cap.detectedAt = Date.now();

    try {
      const url = `https://${session.c3Host}/${VehicleCapabilityReader.PATH_CAR_INFORMATION}`;
      const response = await HttpClient.request(
        url, 'GET', undefined, 'application/json', session.accessToken);

      const cars = VehicleCapabilityReader.extractCars(response);
      if (cars.length === 0) {
        cap.error = '车辆列表为空';
        Log.warn(TAG, cap.error);
        return cap;
      }
      let entry: Record<string, Object> | undefined = undefined;
      if (vin.length > 0) {
        for (const car of cars) {
          const carVin = (car['vin'] as string) ?? '';
          if (carVin.toLowerCase() === vin.toLowerCase()) {
            entry = car;
            break;
          }
        }
      }
      if (entry === undefined) {
        entry = cars[0];
      }

      VehicleCapabilityReader.apply(entry, cap);
      cap.fetched = true;
      Log.info(TAG, `能力探测完成: ${cap.vin} ${cap.modelName} · ` +
        `已开启 ${VehicleCapabilityReader.enabledCount(cap)} 项`);
    } catch (err) {
      const e = err as BusinessError;
      cap.error = e.message ?? '未知错误';
      Log.warn(TAG, `能力探测失败: ${cap.error}`);
    }
    return cap;
  }

  /**
   * 把车辆档案映射到能力对象（供单元测试）。
   */
  static apply(entry: Record<string, Object>, cap: VehicleCapability): void {
    cap.vin = (entry['vin'] as string) ?? cap.vin;
    cap.modelName = (entry['modelName'] as string) ?? '';
    cap.modelYear = (entry['modelYear'] as string) ?? '';
    cap.market = (entry['market'] as string) ?? '';
    cap.modelCode = (entry['modelCode'] as string) ?? '';
    cap.registrationPlate = (entry['registrationPlate'] as string) ?? '';
    cap.driverSide = (entry['driverSide'] as string) ?? '';
    cap.remoteControlType = (entry['remoteControlType'] as string) ?? '';
    cap.digitalKeyType = (entry['digitalKeyType'] as string) ?? '';
    cap.electricInletDcLocation = (entry['electricInletDcLocation'] as string) ?? '';
    cap.plugAndChargePcid = (entry['plugAndChargePcid'] as string) ?? '';
    cap.chargeTimerType = (entry['chargeTimerType'] as string) ?? '';
    cap.userIsOwner = (entry['userIsOwner'] as boolean) ?? false;
    cap.userIsLinked = (entry['userIsLinked'] as boolean) ?? false;
    cap.structureWeek = (entry['structureWeek'] as number) ?? 0;
    cap.consumerSoftwareVersion = (entry['consumerSoftwareVersion'] as string) ?? '';
    cap.steeringWheelHeatingLevel = VehicleCapabilityReader.heatingLevel(
      entry['parkingClimatizationSteeringWheelSettingLevels']);
    cap.frontSeatsHeatingLevel = VehicleCapabilityReader.heatingLevel(
      entry['parkingClimatizationFrontSeatsSettingLevels']);
    cap.rearSeatsHeatingLevel = VehicleCapabilityReader.heatingLevel(
      entry['parkingClimatizationRearSeatsSettingLevels']);

    // 原始字段表 —— 布尔、数值与文本都保留。
    // 文本型档案字段（软件版本、加热档位）要靠它取值。
    const raw: Record<string, boolean | number | string> = {};
    for (const key of Object.keys(entry)) {
      const value = entry[key];
      if (typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string') {
        raw[key] = value;
      }
    }
    cap.raw = raw;

    // 加热档位在原始表里是英文枚举（Level2），展示要用中文 ——
    // 这里把翻译结果写回原始表，让模型层的取值逻辑保持统一。
    if (cap.steeringWheelHeatingLevel.length > 0) {
      cap.raw['parkingClimatizationSteeringWheelSettingLevels'] = cap.steeringWheelHeatingLevel;
    }
    if (cap.frontSeatsHeatingLevel.length > 0) {
      cap.raw['parkingClimatizationFrontSeatsSettingLevels'] = cap.frontSeatsHeatingLevel;
    }
    if (cap.rearSeatsHeatingLevel.length > 0) {
      cap.raw['parkingClimatizationRearSeatsSettingLevels'] = cap.rearSeatsHeatingLevel;
    }
  }

  /**
   * 把加热档位枚举转成中文文案。
   *
   * 服务端给的是字符串（`Off` / `Level1` / `Level2` / `Level3`），
   * 但也可能是数字枚举值，两种都兼容。
   */
  private static heatingLevel(value: Object | undefined): string {
    if (value === undefined || value === null) {
      return '';
    }
    if (typeof value === 'number') {
      return VehicleCapabilityReader.heatingLevelName(value);
    }
    if (typeof value === 'string') {
      const text = value.trim();
      if (text.length === 0) {
        return '';
      }
      if (text === 'Off') {
        return '关闭';
      }
      if (text.startsWith('Level')) {
        const num = Number(text.substring(5));
        if (!Number.isNaN(num)) {
          return `${num} 档`;
        }
      }
      return text;
    }
    return '';
  }

  /**
   * 数字枚举值对应的加热档位名。
   */
  private static heatingLevelName(value: number): string {
    if (value === 0) {
      return '关闭';
    }
    return `${value} 档`;
  }

  /**
   * 从响应里取出车辆列表。
   *
   * 服务端有两种可能的形态，两种都要兼容：
   *   1. 顶层就是数组（官方 Retrofit 声明是 `Response<List<CarInformation>>`）
   *   2. 对象包一层 `items` / `data`
   */
  private static extractCars(response: Object): Record<string, Object>[] {
    if (Array.isArray(response)) {
      return VehicleCapabilityReader.asArray(response as Object);
    }
    if (response === null || typeof response !== 'object') {
      return [];
    }
    const record = response as Record<string, Object>;
    const items = record['items'] ?? record['data'];
    return VehicleCapabilityReader.asArray(items);
  }

  /**
   * 把任意值转成数组 —— 服务端返回的集合字段有时是数组、有时是单对象。
   */
  private static asArray(value: Object | undefined): Record<string, Object>[] {
    if (value === undefined || value === null) {
      return [];
    }
    if (Array.isArray(value)) {
      const result: Record<string, Object>[] = [];
      for (const item of value as Object[]) {
        if (item !== null && typeof item === 'object') {
          result.push(item as Record<string, Object>);
        }
      }
      return result;
    }
    if (typeof value === 'object') {
      return [value as Record<string, Object>];
    }
    return [];
  }

  /**
   * 统计已开启的能力数。
   */
  static enabledCount(cap: VehicleCapability): number {
    let count = 0;
    const entries = VehicleCapability.entries(cap);
    for (const entry of entries) {
      if (entry.supported === true) {
        count++;
      }
    }
    return count;
  }
}
