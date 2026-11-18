import { GrpcClient } from './grpc/GrpcClient';
import { ProtoWriter } from '../proto/ProtoWriter';
import { ProtoReader, ProtoValue } from '../proto/ProtoReader';
import { BusinessError, Log } from '../../common/Log';

/**
 * 充电配置读写 —— 对应官方 App 的三个 chronos 服务。
 *
 * 这三个服务与状态域（vehiclestates）**完全不同源**：
 *   目标电量 / 电流上限 / 预约时段都不在 battery domain 里，
 *   必须分别查这三个独立服务。
 *
 * 服务与方法（还原自官方 App 的 proto 生成类）：
 *   chronos.services.v1.TargetSocService
 *     GetLatestTargetSoc (UNARY)  读当前充电上限
 *     SetTargetSoc       (STREAM) 写充电上限
 *   chronos.services.v1.AmpLimitService
 *     GetAmpLimit        (STREAM) 读当前电流上限
 *     SetAmpLimit        (STREAM) 写电流上限
 *   chronos.services.v2.GlobalChargeTimerService
 *     GetGlobalChargeTimer (UNARY) 读预约充电时段
 *     SetGlobalChargeTimer (UNARY) 写预约充电时段
 *
 * 三个服务全部走 **LBS 主机**（c3Lbs）—— 与同族的 ParkingClimateTimerService
 * 同一条路径。官方 App 的路由类 clisuper 持有两个 channel，
 * 这三个服务用的都是 lbsChannel。
 *
 * 消息结构：
 *   ChronosRequest              field 1=id(uuid) 2=vin 3=source("RCS") 4=timeZone
 *     timeZone                   field 1=offsetMinutes
 *   SetTargetSocRequest         field 1=request 2=batteryChargeTargetLevel 3=settingType
 *   SetAmpLimitRequest          field 1=request 2=ampLimit
 *   SetGlobalChargeTimerRequest field 1=request 2=chargeTimer 3=timeIsUtc0
 *   GlobalChargeTimer           field 1=start(DailyTime) 2=stop(DailyTime) 3=activated
 *   DailyTime                   field 1=hour 2=minute 3=timeZone
 *
 * 注意 Set* 系列在官方 proto 里是 SERVER_STREAMING，但响应只有一帧
 * status/message，用普通一元调用即可（服务端推完就结束）。
 */

/**
 * 充电配置读回的结果。
 */
export interface ChargeConfigSnapshot {
  /** 充电上限（百分比），-1 表示未知。 */
  targetSoc: number;
  /** 电流上限（安培），-1 表示未知。 */
  ampLimit: number;
  /** 预约开始时刻，格式 "HH:MM"；空串表示未设置。 */
  timerStart: string;
  /** 预约结束时刻，格式 "HH:MM"；空串表示未设置。 */
  timerStop: string;
  /** 预约充电是否启用。 */
  timerActivated: boolean;
}

/**
 * 一次设置的结果。
 */
export interface ChargeConfigResult {
  success: boolean;
  message: string;
}

export class ChargeConfig {
  /** 官方 App 固定用 "RCS" 作为 source。 */
  static readonly SOURCE: string = 'RCS';

  /** 充电上限档位：30 ~ 100，每 5% 一档。 */
  static readonly SOC_LEVELS: number[] = [
    30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100
  ];

  /** 电流上限档位（安培），全偶数。 */
  static readonly AMP_LEVELS: number[] = [6, 8, 10, 12, 16, 20, 24, 32];

  /**
   * 构造 ChronosRequest。
   *
   * @param vin 车辆 VIN
   */
  private static chronosRequest(vin: string): Uint8Array {
    const writer = new ProtoWriter();
    writer.writeStringField(1, ChargeConfig.newUuid());
    writer.writeStringField(2, vin);
    writer.writeStringField(3, ChargeConfig.SOURCE);
    // field 4 = timeZone，其内部 field 1 = 相对 UTC 的分钟偏移。
    // 东八区是 +480 —— 用 getTimezoneOffset() 取出的值要取反。
    const offsetMinutes = -new Date().getTimezoneOffset();
    const timeZone = ProtoWriter.writeVarintField(1, offsetMinutes);
    writer.writeBytesField(4, timeZone);
    return writer.toUint8Array();
  }

  /**
   * 生成 UUID v4（与 GrpcClient 里的实现同构，这里不跨类引用）。
   */
  private static newUuid(): string {
    return 'xxxxxxxx-xxxx-4xxx-yyyy-xxxxxxxxxxxx'.replace(/[xy]/g, (c: string) => {
      const r = Math.random() * 16 | 0;
      const v = c === 'x' ? r : (r & 0x3 | 0x8);
      return v.toString(16);
    });
  }

  /**
   * 把 "HH:MM" 解析成分钟数。
   */
  private static parseMinutes(text: string): number {
    const parts = text.split(':');
    if (parts.length < 2) {
      return 0;
    }
    const hour = parseInt(parts[0], 10);
    const minute = parseInt(parts[1], 10);
    if (isNaN(hour) || isNaN(minute)) {
      return 0;
    }
    return hour * 60 + minute;
  }

  /**
   * 把分钟数格式化成 "HH:MM"。
   */
  static formatMinutes(minutes: number): string {
    const hour = Math.floor(minutes / 60) % 24;
    const minute = minutes % 60;
    return `${hour.toString().padStart(2, '0')}:${minute.toString().padStart(2, '0')}`;
  }

  /**
   * 把 "HH:MM" 转成分钟数；空串或非法值返回 -1。
   */
  static minutesOf(text: string): number {
    if (text.length === 0) {
      return -1;
    }
    const parts = text.split(':');
    if (parts.length < 2) {
      return -1;
    }
    const hour = parseInt(parts[0], 10);
    const minute = parseInt(parts[1], 10);
    if (isNaN(hour) || isNaN(minute)) {
      return -1;
    }
    return hour * 60 + minute;
  }

  /**
   * 读当前充电上限。
   *
   * @returns 目标电量百分比；读取失败返回 -1
   */
  static async readTargetSoc(client: GrpcClient, vin: string): Promise<number> {
    try {
      const request = ProtoWriter.writeBytesField(1, ChargeConfig.chronosRequest(vin));
      const response = await client.call(GrpcClient.SERVICE_TARGET_SOC, 'GetLatestTargetSoc',
        vin, request, GrpcClient.DEFAULT_TIMEOUT_MS, true);
      const fields = new ProtoReader(response).decode();
      // field 3 = targetSoc (TargetSoc)，其内部 field 1 = batteryChargeTargetLevel
      const targetSoc = ProtoValue.get(fields, 3);
      if (targetSoc instanceof Uint8Array) {
        const inner = new ProtoReader(targetSoc).decode();
        const level = ProtoValue.asInteger(ProtoValue.get(inner, 1));
        return level === undefined ? -1 : level;
      }
      return -1;
    } catch (err) {
      Log.warn(`读取充电上限失败: ${(err as Error).message}`);
      return -1;
    }
  }

  /**
   * 读当前电流上限。
   *
   * @returns 电流上限（安培）；读取失败返回 -1
   */
  static async readAmpLimit(client: GrpcClient, vin: string): Promise<number> {
    try {
      const request = ProtoWriter.writeBytesField(1, ChargeConfig.chronosRequest(vin));
      const response = await client.call(GrpcClient.SERVICE_AMP_LIMIT, 'GetAmpLimit',
        vin, request, GrpcClient.DEFAULT_TIMEOUT_MS, true);
      const fields = new ProtoReader(response).decode();
      // field 3 = ampLimit (AmpLimit)，其内部 field 1 = ampLimit
      const ampLimit = ProtoValue.get(fields, 3);
      if (ampLimit instanceof Uint8Array) {
        const inner = new ProtoReader(ampLimit).decode();
        const level = ProtoValue.asInteger(ProtoValue.get(inner, 1));
        return level === undefined ? -1 : level;
      }
      return -1;
    } catch (err) {
      Log.warn(`读取电流上限失败: ${(err as Error).message}`);
      return -1;
    }
  }

  /**
   * 读当前预约充电设置。
   *
   * @returns 预约设置；读取失败时 activated=false 且时段为空
   */
  static async readChargeTimer(client: GrpcClient, vin: string): Promise<ChargeConfigSnapshot> {
    const result: ChargeConfigSnapshot = {
      targetSoc: -1,
      ampLimit: -1,
      timerStart: '',
      timerStop: '',
      timerActivated: false
    };
    try {
      const request = ProtoWriter.writeBytesField(1, ChargeConfig.chronosRequest(vin));
      const response = await client.call(GrpcClient.SERVICE_CHARGE_TIMER, 'GetGlobalChargeTimer',
        vin, request, GrpcClient.DEFAULT_TIMEOUT_MS, true);
      const fields = new ProtoReader(response).decode();
      // field 1 = globalChargeTimer (GlobalChargeTimer)
      const timer = ProtoValue.get(fields, 1);
      if (timer instanceof Uint8Array) {
        const inner = new ProtoReader(timer).decode();
        result.timerActivated = ProtoValue.asInteger(ProtoValue.get(inner, 3)) === 1;
        result.timerStart = ChargeConfig.readDailyTime(ProtoValue.get(inner, 1));
        result.timerStop = ChargeConfig.readDailyTime(ProtoValue.get(inner, 2));
      }
    } catch (err) {
      Log.warn(`读取预约充电设置失败: ${(err as Error).message}`);
    }
    return result;
  }

  /**
   * 解析 DailyTime，输出 "HH:MM"。
   */
  private static readDailyTime(value: number | Uint8Array | undefined): string {
    if (!(value instanceof Uint8Array)) {
      return '';
    }
    const inner = new ProtoReader(value).decode();
    const hour = ProtoValue.asInteger(ProtoValue.get(inner, 1));
    const minute = ProtoValue.asInteger(ProtoValue.get(inner, 2));
    if (hour === undefined || minute === undefined) {
      return '';
    }
    return ChargeConfig.formatMinutes(hour * 60 + minute);
  }

  /**
   * 写充电上限。
   *
   * @param targetSoc 目标电量百分比
   */
  static async setTargetSoc(client: GrpcClient, vin: string, targetSoc: number): Promise<ChargeConfigResult> {
    const writer = new ProtoWriter();
    writer.writeBytesField(1, ChargeConfig.chronosRequest(vin));
    writer.writeVarintField(2, targetSoc);
    // field 3 = chargeTargetLevelSettingType：CUSTOM = 3
    // （官方 App 的 setTargetSoc 固定传 CUSTOM，表示用户自定义值）
    writer.writeVarintField(3, 3);
    return await ChargeConfig.write(client, vin, GrpcClient.SERVICE_TARGET_SOC, 'SetTargetSoc',
      writer.toUint8Array(), '充电上限');
  }

  /**
   * 写电流上限。
   *
   * @param ampLimit 电流上限（安培）
   */
  static async setAmpLimit(client: GrpcClient, vin: string, ampLimit: number): Promise<ChargeConfigResult> {
    const writer = new ProtoWriter();
    writer.writeBytesField(1, ChargeConfig.chronosRequest(vin));
    writer.writeVarintField(2, ampLimit);
    return await ChargeConfig.write(client, vin, GrpcClient.SERVICE_AMP_LIMIT, 'SetAmpLimit',
      writer.toUint8Array(), '电流上限');
  }

  /**
   * 写预约充电设置。
   *
   * 跨天（开始 > 结束）不需要特殊编码：车端按 start / stop 两个独立时刻
   * 自己判断，start > stop 即视为次日结束。
   *
   * @param activated 是否启用
   * @param start     开始时刻 "HH:MM"
   * @param stop      结束时刻 "HH:MM"
   */
  static async setChargeTimer(client: GrpcClient, vin: string, activated: boolean,
    start: string, stop: string): Promise<ChargeConfigResult> {
    const writer = new ProtoWriter();
    writer.writeBytesField(1, ChargeConfig.chronosRequest(vin));

    // field 2 = chargeTimer (GlobalChargeTimer)
    const timer = new ProtoWriter();
    timer.writeBytesField(1, ChargeConfig.dailyTime(start));
    timer.writeBytesField(2, ChargeConfig.dailyTime(stop));
    timer.writeVarintField(3, activated ? 1 : 0);
    writer.writeBytesField(2, timer.toUint8Array());

    // field 3 = timeIsUtc0：false —— 我们传的是**本地时间**，
    // 配合 ChronosRequest 里的时区偏移由车端换算。
    writer.writeVarintField(3, 0);

    return await ChargeConfig.write(client, vin, GrpcClient.SERVICE_CHARGE_TIMER, 'SetGlobalChargeTimer',
      writer.toUint8Array(), '预约充电');
  }

  /**
   * 构造 DailyTime。
   */
  private static dailyTime(text: string): Uint8Array {
    const minutes = ChargeConfig.parseMinutes(text);
    const writer = new ProtoWriter();
    writer.writeVarintField(1, Math.floor(minutes / 60));
    writer.writeVarintField(2, minutes % 60);
    return writer.toUint8Array();
  }

  /**
   * 统一的写调用 + 结果判定。
   *
   * 响应结构：field 2/3 = status/message（不同服务字段号略有出入，
   * 这里把两者都取一遍），Status 枚举 3 = SUCCESS。
   */
  private static async write(client: GrpcClient, vin: string, service: string, method: string,
    payload: Uint8Array, label: string): Promise<ChargeConfigResult> {
    try {
      const response = await client.call(service, method, vin, payload,
        GrpcClient.DEFAULT_TIMEOUT_MS, true);
      if (response.length === 0) {
        // 服务端只回了 trailers（grpc-status 0）没有消息体 —— 视为成功。
        Log.info(`充电配置已下发: ${label}`);
        return { success: true, message: `${label}已保存` };
      }
      const fields = new ProtoReader(response).decode();
      // SetTargetSocResponse: 3=status 4=message
      // SetAmpLimitResponse:  3=status 4=message
      // SetGlobalChargeTimerResponse: 2=status 3=message
      const status = ProtoValue.asInteger(ProtoValue.get(fields, 3)) ??
        ProtoValue.asInteger(ProtoValue.get(fields, 2));
      const message = ProtoValue.decodeString(ProtoValue.get(fields, 4)) ||
        ProtoValue.decodeString(ProtoValue.get(fields, 3));
      if (status === undefined || status === 3) {
        Log.info(`充电配置已下发: ${label}`);
        return { success: true, message: `${label}已保存` };
      }
      const detail = message.length > 0 ? message : `状态码 ${status}`;
      Log.warn(`充电配置下发失败: ${label} ${detail}`);
      return { success: false, message: `${label}保存失败：${detail}` };
    } catch (err) {
      const e = err as BusinessError;
      Log.error(`充电配置下发异常: ${label} ${e.message}`);
      return { success: false, message: `${label}保存失败：${e.message}` };
    }
  }
}
