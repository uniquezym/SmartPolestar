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
 * 服务与方法：
 *   chronos.services.v1.TargetSocService
 *     GetTargetSoc (SERVER_STREAMING) 读当前充电上限
 *     SetTargetSoc (SERVER_STREAMING) 写充电上限
 *   chronos.services.v1.AmpLimitService
 *     GetAmpLimit  (SERVER_STREAMING) 读当前电流上限
 *     SetAmpLimit  (SERVER_STREAMING) 写电流上限
 *   chronos.services.v2.GlobalChargeTimerService
 *     GetGlobalChargeTimerStream (SERVER_STREAMING) 读预约充电时段
 *     SetGlobalChargeTimer        (UNARY)           写预约充电时段
 *
 * 三个服务全部走 **LBS 主机**（c3Lbs）—— 与同族的 ParkingClimateTimerService
 * 同一条路径。官方 App 的路由类 clisuper 持有两个 channel，
 * 这三个服务用的都是 lbsChannel。
 *
 * ── 请求体结构 ──
 *
 * chronos 系的请求体是**两层**：
 *
 *   外层（各 Set/Get 请求的 field 1）
 *     field 1 = bytes( ChronosRequest )
 *
 *   ChronosRequest
 *     field 1 = 请求 UUID
 *     field 2 = VIN
 *     field 3 = source（固定 "RCS"）
 *     field 4 = TimeZone{ field 1 = 相对 UTC 的分钟偏移 }
 *
 * ── 响应体结构 ──
 *
 * 也是两层：
 *
 *   外层
 *     field 2 = VIN（回显，用于校验）
 *     field 3 = bytes( 真正的数据 )
 *
 *   数据层
 *     target / amperage： field 1 = 数值本身（目标电量百分比 / 电流上限）
 *     chargeTimer：       field 1 = GlobalChargeTimer
 *                         field 1 = start(DailyTime) field 2 = stop(DailyTime)
 *                         field 3 = activated
 *
 * ── 为什么读方法必须走服务端流 ──
 *
 * `GetAmpLimit` / `GetTargetSoc` / `GetGlobalChargeTimerStream` 在官方 proto 里
 * 都是 SERVER_STREAMING：服务端持续推送直到流被取消。用一元调用去读，
 * 响应体永远不结束，只能等到传输超时 —— 表现为「下拉刷新卡十几秒然后报超时」。
 * 所以读方法走 `callStreamFirst`，取到第一帧就断开。
 *
 * ── DailyTime 里的时区 ──
 *
 * `DailyTime` 的 field 3 是 TimeZone，装着相对 UTC 的分钟偏移。
 * 少了这个字段，车端无法把「22:00」换算成绝对时刻，预约时段会偏。
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

  /**
   * 充电上限档位：40 ~ 100，每 5% 一档。
   *
   * 下限 40 来自车辆元数据 `targetChargeLevelPercentageMinLimit`
   * （官方 App 用同一下限，缺省时也按 40 处理）。
   */
  static readonly SOC_LEVELS: number[] = [
    40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95, 100
  ];

  /** 电流上限档位（安培），全偶数。 */
  static readonly AMP_LEVELS: number[] = [6, 8, 10, 12, 16, 20, 24, 32];

  /**
   * 构造 ChronosRequest。
   *
   * @param vin          车辆 VIN
   * @param offsetMinutes 相对 UTC 的分钟偏移，东八区为 +480
   */
  private static chronosRequest(vin: string, offsetMinutes: number): Uint8Array {
    const writer = new ProtoWriter();
    writer.writeStringField(1, ChargeConfig.newUuid());
    writer.writeStringField(2, vin);
    writer.writeStringField(3, ChargeConfig.SOURCE);
    // field 4 = TimeZone，其内部 field 1 = 相对 UTC 的分钟偏移。
    writer.writeBytesField(4, ProtoWriter.writeVarintField(1, offsetMinutes));
    return writer.toUint8Array();
  }

  /**
   * 构造请求体（外层 field 1 包一层 ChronosRequest）。
   *
   * @param vin           车辆 VIN
   * @param offsetMinutes 相对 UTC 的分钟偏移
   */
  private static request(vin: string, offsetMinutes: number): Uint8Array {
    return ProtoWriter.writeBytesField(1, ChargeConfig.chronosRequest(vin, offsetMinutes));
  }

  /**
   * 构造**读**请求体。
   *
   * 读取时时区偏移固定传 0 —— 对齐参考实现（官方 App 的
   * `chronos_request` 也是 offset=0，只有写预约充电才带真实时区）。
   * 读取是「拿车端已有的设置」，不需要做时区换算；传真实偏移反而
   * 可能让车端按该时区去匹配定时任务，匹配不上就返回空。
   *
   * @param vin 车辆 VIN
   */
  private static readRequest(vin: string): Uint8Array {
    return ChargeConfig.request(vin, 0);
  }

  /**
   * 当前本地时区相对 UTC 的分钟偏移。
   *
   * `getTimezoneOffset()` 返回的是「UTC 减本地」的分钟数（东八区为 -480），
   * 取反才是协议要的「本地相对 UTC 的偏移」。
   */
  static timezoneOffsetMinutes(): number {
    return -new Date().getTimezoneOffset();
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
   * 拆开响应的外层包装，取出数据层。
   *
   * 外层：field 2 = VIN 回显，field 3 = bytes( 数据 )。
   * 拿不到 field 3 时退回直接解顶层 —— 有些服务的包装层数不一致。
   *
   * @returns 数据层的字段映射
   */
  private static unwrap(response: Uint8Array): Map<number, number | Uint8Array> {
    const outer = new ProtoReader(response).decode();
    const inner = ProtoValue.get(outer, 3);
    if (inner instanceof Uint8Array) {
      return new ProtoReader(inner).decode();
    }
    return outer;
  }

  /**
   * 解析预约充电时段。
   *
   * `GetGlobalChargeTimerStream` 的响应**不走上面那层 field 3 包装** ——
   * 顶层 field 1 直接就是 `GlobalChargeTimer`。两种结构并存，
   * 所以这里先按「顶层 field 1」解析，取不到再退回两层结构。
   *
   * @param response 服务端流的第一帧
   */
  private static parseChargeTimer(response: Uint8Array): ChargeConfigSnapshot {
    const result: ChargeConfigSnapshot = {
      targetSoc: -1,
      ampLimit: -1,
      timerStart: '',
      timerStop: '',
      timerActivated: false
    };

    const outer = new ProtoReader(response).decode();
    let timer = ProtoValue.get(outer, 1);

    // 顶层 field 1 不是消息时，按「field 3 包一层」的结构再找一次
    if (!(timer instanceof Uint8Array)) {
      const inner = ProtoValue.get(outer, 3);
      if (inner instanceof Uint8Array) {
        timer = ProtoValue.get(new ProtoReader(inner).decode(), 1);
      }
    }

    if (timer instanceof Uint8Array) {
      const fields = new ProtoReader(timer).decode();
      result.timerActivated = ProtoValue.asInteger(ProtoValue.get(fields, 3)) === 1;
      result.timerStart = ChargeConfig.readDailyTime(ProtoValue.get(fields, 1));
      result.timerStop = ChargeConfig.readDailyTime(ProtoValue.get(fields, 2));
    }

    // 诊断日志：把顶层与 timer 内部的字段都打出来，
    // 一眼能区分「车端就是没配定时任务」与「结构对不上解析错了」。
    Log.info(`预约充电原始: 顶层字段=[${ChargeConfig.fieldKeys(outer)}] ` +
      `timer字段=[${timer instanceof Uint8Array ? ChargeConfig.fieldKeys(new ProtoReader(timer).decode()) : '无'}] ` +
      `解析结果 start=${result.timerStart} stop=${result.timerStop} 启用=${result.timerActivated}`);
    return result;
  }

  /**
   * 列出消息里有哪些字段号，用于诊断。
   */
  private static fieldKeys(fields: Map<number, number | Uint8Array>): string {
    const keys: string[] = [];
    fields.forEach((value: number | Uint8Array, key: number) => {
      keys.push(`${key}:${value instanceof Uint8Array ? `bytes(${value.length})` : value}`);
    });
    return keys.join(',');
  }

  /**
   * 读当前充电上限。
   *
   * @returns 目标电量百分比；读取失败返回 -1
   */
  static async readTargetSoc(client: GrpcClient, vin: string): Promise<number> {
    try {
      const payload = ChargeConfig.readRequest(vin);
      const response = await client.callStreamFirst(GrpcClient.SERVICE_TARGET_SOC, 'GetTargetSoc',
        vin, payload, GrpcClient.DEFAULT_TIMEOUT_MS, true);
      const fields = ChargeConfig.unwrap(response);
      // 数据层 field 1 = 目标电量百分比
      const level = ProtoValue.asInteger(ProtoValue.get(fields, 1));
      return level === undefined ? -1 : level;
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
      const payload = ChargeConfig.readRequest(vin);
      const response = await client.callStreamFirst(GrpcClient.SERVICE_AMP_LIMIT, 'GetAmpLimit',
        vin, payload, GrpcClient.DEFAULT_TIMEOUT_MS, true);
      const fields = ChargeConfig.unwrap(response);
      // 数据层 field 1 = 电流上限（安培）
      const level = ProtoValue.asInteger(ProtoValue.get(fields, 1));
      return level === undefined ? -1 : level;
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
    try {
      const payload = ChargeConfig.readRequest(vin);
      const response = await client.callStreamFirst(GrpcClient.SERVICE_CHARGE_TIMER,
        'GetGlobalChargeTimerStream', vin, payload, GrpcClient.DEFAULT_TIMEOUT_MS, true);
      return ChargeConfig.parseChargeTimer(response);
    } catch (err) {
      Log.warn(`读取预约充电设置失败: ${(err as Error).message}`);
      return {
        targetSoc: -1,
        ampLimit: -1,
        timerStart: '',
        timerStop: '',
        timerActivated: false
      };
    }
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
    writer.writeBytesField(1, ChargeConfig.chronosRequest(vin, ChargeConfig.timezoneOffsetMinutes()));
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
    writer.writeBytesField(1, ChargeConfig.chronosRequest(vin, ChargeConfig.timezoneOffsetMinutes()));
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
    const offset = ChargeConfig.timezoneOffsetMinutes();
    const writer = new ProtoWriter();
    writer.writeBytesField(1, ChargeConfig.chronosRequest(vin, offset));

    // field 2 = chargeTimer (GlobalChargeTimer)
    const timer = new ProtoWriter();
    timer.writeBytesField(1, ChargeConfig.dailyTime(start, offset));
    timer.writeBytesField(2, ChargeConfig.dailyTime(stop, offset));
    timer.writeVarintField(3, activated ? 1 : 0);
    writer.writeBytesField(2, timer.toUint8Array());

    // field 3 = timeIsUtc0：false —— 我们传的是**本地时间**，
    // 配合 ChronosRequest 与 DailyTime 里的时区偏移由车端换算。
    writer.writeVarintField(3, 0);

    return await ChargeConfig.write(client, vin, GrpcClient.SERVICE_CHARGE_TIMER, 'SetGlobalChargeTimer',
      writer.toUint8Array(), '预约充电');
  }

  /**
   * 构造 DailyTime。
   *
   * field 3 = TimeZone{ field 1 = offsetMinutes } —— 时区不能省，
   * 少了车端就没法把「22:00」换算成绝对时刻。
   *
   * @param text          "HH:MM"
   * @param offsetMinutes 相对 UTC 的分钟偏移
   */
  private static dailyTime(text: string, offsetMinutes: number): Uint8Array {
    const minutes = ChargeConfig.parseMinutes(text);
    const writer = new ProtoWriter();
    writer.writeVarintField(1, Math.floor(minutes / 60));
    writer.writeVarintField(2, minutes % 60);
    writer.writeBytesField(3, ProtoWriter.writeVarintField(1, offsetMinutes));
    return writer.toUint8Array();
  }

  /**
   * 统一的写调用 + 结果判定。
   *
   * **写方法同样走服务端流**：`SetTargetSoc` / `SetAmpLimit` 在官方 proto 里
   * 也是 SERVER_STREAMING，用一元调用会等到传输超时。取第一帧就够 ——
   * 响应里只有 status / message 一帧状态。
   *
   * 响应结构：field 2/3 = status/message（不同服务字段号略有出入，
   * 这里把两者都取一遍），Status 枚举 3 = SUCCESS。
   */
  private static async write(client: GrpcClient, vin: string, service: string, method: string,
    payload: Uint8Array, label: string): Promise<ChargeConfigResult> {
    try {
      const response = await client.callStreamFirst(service, method, vin, payload,
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
