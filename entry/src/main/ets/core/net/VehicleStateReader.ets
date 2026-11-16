import { GrpcClient } from './grpc/GrpcClient';
import { ProtoReader, ProtoValue } from '../proto/ProtoReader';
import {
  VehicleState, CHARGING_LABELS, CHARGER_CONNECTION_LABELS, CHARGING_TYPE_LABELS,
  CHARGER_POWER_LABELS, CLIMATE_LABELS, CLIMATE_RUN_MODE_LABELS, LOCK_LABELS,
  TAILGATE_LABELS, AIR_LABELS, MAINTENANCE_LABELS
} from '../model/VehicleState';
import { Log } from '../../common/Log';

/**
 * 单个状态域的读取任务。
 */
interface StateReadTask {
  name: string;
  run: () => Promise<void>;
}

/**
 * 车辆状态读取与字段映射 —— 对应 Android 端 p000.ga0 的
 * m1403Q（电池）、m1358R（空调）、m1357O（空气）、m1402P（组合读取）。
 *
 * C3 gRPC 返回 protobuf，字段号到业务含义的映射即在此处还原。
 */
export class VehicleStateReader {
  /**
   * 解开 gRPC 响应的外层包装。
   *
   * 还原自 Android 端 ga0.m1349F(map, 3)：状态类接口的响应外层是
   * field 3（length-delimited），里面才是真正的状态字段。
   * dtlinternet 接口用的是 field 2（见 m1407V）。
   *
   * 若外层取不到内容，则退回直接解顶层，避免因个别服务结构差异导致全盘为空。
   */
  static unwrap(response: Uint8Array, outerField: number): Map<number, number | Uint8Array> {
    const outer = new ProtoReader(response).decode();
    const inner = ProtoValue.get(outer, outerField);
    if (inner instanceof Uint8Array) {
      return new ProtoReader(inner).decode();
    }
    return outer;
  }

  /**
   * 读取电池 / 充电状态。对应 ga0.m1403Q。
   */
  static async readBattery(client: GrpcClient, vin: string, state: VehicleState): Promise<void> {
    const response = await client.callStatus(GrpcClient.SERVICE_BATTERY, 'GetLatestBattery', vin);
    VehicleStateReader.applyBattery(response, state);
  }

  /**
   * 把电池 / 充电响应映射到状态对象。
   *
   * 快照（GetLatestBattery）与流式（GetBattery）的响应结构完全相同，
   * 因此映射逻辑只需一份 —— 快照与流共用。
   */
  static applyBattery(response: Uint8Array, state: VehicleState): void {
    const fields = VehicleStateReader.unwrap(response, 3);

    state.battery = ProtoValue.asInteger(ProtoValue.get(fields, 2));
    state.range = ProtoValue.asInteger(ProtoValue.get(fields, 4));
    // 还原自 ga0.m1403Q：field 3/12/13 是 kWh/100km 均耗，
    // field 14/15/16 是 Wh 累计能耗。这几个字段走 m1384q / m1350G，
    // 都是 m1372i 的包装，需兼容 4 字节 float。
    state.tripManualAverageEnergyKwhPer100Km = ProtoValue.asFiniteNumber(ProtoValue.get(fields, 3));
    state.tripAutomaticAverageEnergyKwhPer100Km = ProtoValue.asFiniteNumber(ProtoValue.get(fields, 12));
    state.tripSinceChargeAverageEnergyKwhPer100Km = ProtoValue.asFiniteNumber(ProtoValue.get(fields, 13));
    state.tripManualEnergyWh = ProtoValue.asNonNegative(ProtoValue.get(fields, 14));
    state.tripAutomaticEnergyWh = ProtoValue.asNonNegative(ProtoValue.get(fields, 15));
    state.tripSinceChargeEnergyWh = ProtoValue.asNonNegative(ProtoValue.get(fields, 16));
    state.charging = VehicleState.enumLabel(
      ProtoValue.asInteger(ProtoValue.get(fields, 7)), CHARGING_LABELS);
    state.timeToFullMinutes = ProtoValue.asInteger(ProtoValue.get(fields, 5));
    state.chargerConnection = VehicleState.enumLabel(
      ProtoValue.asInteger(ProtoValue.get(fields, 6)), CHARGER_CONNECTION_LABELS);
    state.powerWatts = ProtoValue.asInteger(ProtoValue.get(fields, 10));
    state.currentAmps = ProtoValue.asFiniteNumber(ProtoValue.get(fields, 11));
    state.chargingType = VehicleState.enumLabel(
      ProtoValue.asInteger(ProtoValue.get(fields, 17)), CHARGING_TYPE_LABELS);
    state.chargerPowerStatus = VehicleState.enumLabel(
      ProtoValue.asInteger(ProtoValue.get(fields, 26)), CHARGER_POWER_LABELS);

    const timestamp = ProtoValue.get(fields, 1);
    if (typeof timestamp === 'number') {
      state.batteryStateAt = timestamp;
    }
  }

  /**
   * 读取外饰状态（车锁 / 门窗 / 尾门）。
   */
  static async readExterior(client: GrpcClient, vin: string, state: VehicleState): Promise<void> {
    const response = await client.callStatus(GrpcClient.SERVICE_EXTERIOR, 'GetLatestExterior', vin);
    VehicleStateReader.applyExterior(response, state);
  }

  /**
   * 把外饰响应映射到状态对象。
   */
  static applyExterior(response: Uint8Array, state: VehicleState): void {
    const fields = VehicleStateReader.unwrap(response, 3);

    state.locked = VehicleState.enumLabel(ProtoValue.asInteger(ProtoValue.get(fields, 2)), LOCK_LABELS);
    state.tailgate = VehicleState.enumLabel(
      ProtoValue.asInteger(ProtoValue.get(fields, 12)), TAILGATE_LABELS);
    state.tailgateLock = VehicleState.enumLabel(
      ProtoValue.asInteger(ProtoValue.get(fields, 16)), LOCK_LABELS);
    // 机盖与充电口状态。还原自 ga0.m1406U：f1760J <- field 11，f1761K <- field 13。
    state.hoodState = ProtoValue.asInteger(ProtoValue.get(fields, 11)) ?? -1;
    state.chargePortState = ProtoValue.asInteger(ProtoValue.get(fields, 13)) ?? -1;

    // 车门状态取 field 3..6，车窗状态取 field 7..10。
    // 还原自 ga0.m1406U：f1758H <- field 3..6，f1759I <- field 7..10。
    const doorStates: number[] = [];
    const windowStates: number[] = [];
    for (let i = 0; i < 4; i++) {
      doorStates.push(ProtoValue.asInteger(ProtoValue.get(fields, 3 + i)) ?? -1);
      windowStates.push(ProtoValue.asInteger(ProtoValue.get(fields, 7 + i)) ?? -1);
    }
    state.doorStates = doorStates;
    state.windowStates = windowStates;
    state.windows = VehicleState.summarizeWindows(state.windowStates);
    // 打印逐扇原始值，便于核对协议枚举：
    // Exterior.OpenStatus 0=未指定 1=开启 2=关闭 3=未关严。
    Log.info(`门窗原始值 门=${doorStates.join(',')} 窗=${windowStates.join(',')}`);
    state.exteriorStateAt = Date.now();
  }

  /**
   * 读取驻车空调状态。对应 ga0.m1358R。
   */
  static async readClimate(client: GrpcClient, vin: string, state: VehicleState): Promise<void> {
    const response = await client.callStatus(
      GrpcClient.SERVICE_CLIMATIZATION, 'GetLatestParkingClimatization', vin);
    VehicleStateReader.applyClimate(response, state);
  }

  /**
   * 把驻车空调响应映射到状态对象。
   */
  static applyClimate(response: Uint8Array, state: VehicleState): void {
    const fields = VehicleStateReader.unwrap(response, 3);

    state.climate = VehicleState.enumLabel(ProtoValue.asInteger(ProtoValue.get(fields, 2)), CLIMATE_LABELS);
    state.climateRuntimeMinutes = ProtoValue.asInteger(ProtoValue.get(fields, 3));
    // field 6 是运行模式，不是循环模式。原版只用它选图标：
    // 1 → ic_climate_cool（雪花）、2 → ic_climate_heat（热气）、其余 → ic_climate_airflow（气流）。
    // 早期版本误映射为「内循环 / 外循环」，原版代码中不存在该语义，已更正。
    state.climateRunMode = VehicleState.enumLabel(
      ProtoValue.asInteger(ProtoValue.get(fields, 6)), CLIMATE_RUN_MODE_LABELS);
    state.climateTemperatureC = ProtoValue.asFiniteNumber(ProtoValue.get(fields, 7));
    state.climateTargetTemperatureC = ProtoValue.asFiniteNumber(ProtoValue.get(fields, 8));
    state.climateStateAt = Date.now();
  }

  /**
   * 读取空气净化状态。对应 ga0.m1357O。
   */
  static async readAir(client: GrpcClient, vin: string, state: VehicleState): Promise<void> {
    const response = await client.callStatus(
      GrpcClient.SERVICE_PRECLEANING, 'GetLatestPreCleaning', vin);
    VehicleStateReader.applyAir(response, state);
  }

  /**
   * 把空气净化响应映射到状态对象。
   */
  static applyAir(response: Uint8Array, state: VehicleState): void {
    const fields = VehicleStateReader.unwrap(response, 3);

    state.air = VehicleState.enumLabel(ProtoValue.asInteger(ProtoValue.get(fields, 6)), AIR_LABELS);

    // AQI 与 PM2.5 是「测量值」，车端只在有新的测量结果时才带上这两个字段
    // （协议里另有 field 8 = lastCycleValid 表示上一次测量是否有效）。
    // 流式推送的后续帧常常只带运行状态与剩余时长，不带测量值。
    //
    // 因此这里只在字段**确实存在**时才覆盖，缺失就沿用上一次的值 ——
    // 否则每来一帧不带测量的推送，已有的 AQI / PM2.5 就被清成未知，
    // 用户会看到「空气质量信息凭空消失」。
    const aqi = ProtoValue.asInteger(ProtoValue.get(fields, 9));
    if (aqi !== undefined) {
      state.airQualityIndex = aqi;
    }
    const pm25 = ProtoValue.asFiniteNumber(ProtoValue.get(fields, 10));
    if (pm25 !== undefined) {
      state.pm25UgM3 = pm25;
    }

    // field 11 = 剩余运行分钟数。据此可推算预计结束时刻，
    // 状态检查安排在那一刻前后即可，不必固定周期轮询。
    state.airRuntimeMinutes = ProtoValue.asInteger(ProtoValue.get(fields, 11));
    state.airStateAt = Date.now();
  }

  /**
   * 读取里程。对应 ga0 的 odometer 分支。
   */
  static async readOdometer(client: GrpcClient, vin: string, state: VehicleState): Promise<void> {
    const response = await client.callStatus(GrpcClient.SERVICE_ODOMETER, 'GetLatestOdometer', vin);
    VehicleStateReader.applyOdometer(response, state);
  }

  /**
   * 把里程响应映射到状态对象。
   */
  static applyOdometer(response: Uint8Array, state: VehicleState): void {
    const fields = VehicleStateReader.unwrap(response, 3);

    // 总里程：原始单位为米，按 m1352I 取整数后除以 1000 换算为公里
    const meters = ProtoValue.asInteger(ProtoValue.get(fields, 2));
    if (meters !== undefined) {
      state.odometerKm = Math.trunc(meters / 1000);
    }
    // 还原自 ga0.m1409X：field 3/4/7 分别是手动 / 自动 / 自充电小计里程。
    // 这三个字段用 m1372i 读取，既接受 8 字节 double 也接受 4 字节 float，
    // 因此不能用 asFiniteDouble（只认 8 字节，float 会读成 NaN）。
    state.tripManualKm = ProtoValue.asFiniteNumber(ProtoValue.get(fields, 3));
    state.tripAutomaticKm = ProtoValue.asFiniteNumber(ProtoValue.get(fields, 4));
    state.tripSinceChargeKm = ProtoValue.asFiniteNumber(ProtoValue.get(fields, 7));
    // field 5/6/8 分别是三个口径的平均车速（km/h）。
    state.manualAverageSpeedKph = ProtoValue.asInteger(ProtoValue.get(fields, 5));
    state.automaticAverageSpeedKph = ProtoValue.asInteger(ProtoValue.get(fields, 6));
    state.sinceChargeAverageSpeedKph = ProtoValue.asInteger(ProtoValue.get(fields, 8));
    state.odometerStateAt = Date.now();

    // 打印里程原始字段，便于核对协议里是否还有独立的行驶时长字段
    const raw: string[] = [];
    fields.forEach((value: number | Uint8Array, fieldNumber: number) => {
      if (value instanceof Uint8Array) {
        raw.push(`${fieldNumber}=bytes(${value.length})`);
      } else {
        raw.push(`${fieldNumber}=${value}`);
      }
    });
    Log.info(`里程原始字段: ${raw.join(', ')}`);
  }

  /**
   * 读取车辆健康状态。对应 ga0 的 health 分支。
   */
  static async readHealth(client: GrpcClient, vin: string, state: VehicleState): Promise<void> {
    const response = await client.callStatus(GrpcClient.SERVICE_HEALTH, 'GetLatestHealth', vin);
    VehicleStateReader.applyHealth(response, state);
  }

  /**
   * 把健康响应映射到状态对象。
   */
  static applyHealth(response: Uint8Array, state: VehicleState): void {
    const fields = VehicleStateReader.unwrap(response, 3);

    // 还原自 y90 的 health 分支：保养状态取 field 5，
    // 剩余工时/天数/里程分别取 field 2 / 3 / 4。
    state.maintenanceStatus = VehicleState.enumLabel(
      ProtoValue.asInteger(ProtoValue.get(fields, 5)), MAINTENANCE_LABELS);
    state.serviceRemainingHours = ProtoValue.asInteger(ProtoValue.get(fields, 2));
    state.serviceRemainingDays = ProtoValue.asInteger(ProtoValue.get(fields, 3));
    state.serviceRemainingKm = ProtoValue.asInteger(ProtoValue.get(fields, 4));

    // 健康总评需要扫描全部健康项：任一项 > 1 视为"需关注"，全部为 0 视为"良好"。
    const healthFields = [5, 6, 7, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
      26, 27, 28, 30, 31, 32, 33, 34, 35, 38];
    let hasAny = false;
    let hasWarning = false;
    for (const fieldNumber of healthFields) {
      const value = ProtoValue.asInteger(ProtoValue.get(fields, fieldNumber));
      if (value !== undefined) {
        hasAny = true;
        if (value > 1) {
          hasWarning = true;
        }
      }
    }
    state.healthStatus = hasWarning ? '需关注' : (hasAny ? '未知' : '良好');
    state.healthWarnings = VehicleStateReader.parseHealthWarnings(fields, state);
    state.healthStateAt = Date.now();
  }

  /**
   * 解析逐项健康告警。
   *
   * 协议里每种告警都是独立字段，枚举取值含义各不相同，
   * 因此按项判定而不是套用统一的「> 1 即报」：
   *
   *   胎压 TyrePressureWarning   1=无告警 2=很低 3=低 4=偏高
   *   制动液 BrakeFluidLevel     1=无告警 2=偏低 3=严重偏低
   *   冷却液 EngineCoolantLevel  1=无告警 2=偏低
   *   机油 OilLevel              1=无告警 2=需要保养 3=偏低 4=偏高
   *   玻璃水 WasherFluidLevel    1=无告警 2=偏低
   *   12V 电压 LowVoltageBattery 1=无告警 2=偏低
   *
   * 注意胎压的 4 是「偏高」，不是正常 ——
   * 漏报胎压偏高与漏报胎压过低同样危险，因此胎压三项全报。
   *
   * 排序按安全性：制动系统 → 轮胎 → 液体 → 电压 → 保养。
   * 概览页的状态行只显示第一条 + 计数，排序即优先级。
   *
   * @param fields 健康响应字段
   * @param state  已写入保养状态的状态对象（保养文案复用其中的枚举标签）
   * @returns 可读的告警文案列表，无告警时为空数组
   */
  private static parseHealthWarnings(
    fields: Map<number, number | Uint8Array>, state: VehicleState): string[] {
    const warnings: string[] = [];

    // 制动液：2=偏低，3=严重偏低
    const brakeFluid = ProtoValue.asInteger(ProtoValue.get(fields, 6));
    if (brakeFluid === 3) {
      warnings.push('制动液液位严重偏低');
    } else if (brakeFluid === 2) {
      warnings.push('制动液液位偏低');
    }

    // 胎压：2=很低，3=低，4=偏高。四条轮分别判定。
    const tyreNames: string[] = ['左前', '右前', '左后', '右后'];
    for (let i = 0; i < 4; i++) {
      const value = ProtoValue.asInteger(ProtoValue.get(fields, 9 + i));
      const name = tyreNames[i];
      if (value === 2) {
        warnings.push(`${name}胎压过低`);
      } else if (value === 3) {
        warnings.push(`${name}胎压偏低`);
      } else if (value === 4) {
        warnings.push(`${name}胎压偏高`);
      }
    }

    // 冷却液：2=偏低
    const coolant = ProtoValue.asInteger(ProtoValue.get(fields, 7));
    if (coolant === 2) {
      warnings.push('冷却液液位偏低');
    }

    // 机油：2=需要保养，3=偏低，4=偏高
    const oil = ProtoValue.asInteger(ProtoValue.get(fields, 8));
    if (oil === 3) {
      warnings.push('机油液位偏低');
    } else if (oil === 4) {
      warnings.push('机油液位偏高');
    } else if (oil === 2) {
      warnings.push('机油需要更换');
    }

    // 玻璃水：2=偏低
    const washer = ProtoValue.asInteger(ProtoValue.get(fields, 13));
    if (washer === 2) {
      warnings.push('玻璃水液位偏低');
    }

    // 12V 蓄电池：2=电压偏低
    const lowVoltage = ProtoValue.asInteger(ProtoValue.get(fields, 38));
    if (lowVoltage === 2) {
      warnings.push('12V 蓄电池电压偏低');
    }

    // 保养：复用已有的枚举标签。
    // 「未提供」= 协议没给值，「正常」= 无告警，「未知」= 取值越界，都不算告警。
    const maintenance = state.maintenanceStatus;
    if (maintenance.length > 0 &&
      maintenance !== '未提供' && maintenance !== '正常' && maintenance !== '未知') {
      warnings.push(maintenance);
    }

    return warnings;
  }

  /**
   * 读取最后停车位置（走 LBS 主机）。对应 ga0 的 dtlinternet 分支。
   *
   * 还原自 ga0.m1407V，字段结构：
   *   请求：field 1 = VIN（m1389s0(vin, 1)，注意与 vehiclestates 的 field 2 不同）
   *   响应：field 2 = 位置消息 { field 1 = 纬度, field 2 = 经度, field 3 = 时间戳消息 { field 1 = 时间戳 } }
   *         field 3 = stale 标志（非 0 表示数据陈旧）
   */
  static async readParkedLocation(client: GrpcClient, vin: string, state: VehicleState): Promise<void> {
    const vinBytes = GrpcClient.utf8(vin);
    const payload = new Uint8Array(vinBytes.length + 2);
    payload[0] = 0x0a; // field 1, wire type 2
    payload[1] = vinBytes.length;
    payload.set(vinBytes, 2);

    const response = await client.call(
      GrpcClient.SERVICE_DTL_INTERNET, 'GetLastParkedLocation', vin, payload, 12000, true);
    VehicleStateReader.applyParkedLocation(response, state);
  }

  /**
   * 把最后停车位置响应映射到状态对象。
   *
   * 快照（GetLastParkedLocation）与流式（StreamLastParkedLocations）
   * 的响应结构完全相同，因此映射逻辑只需一份 —— 快照与流共用。
   *
   * 响应结构：
   *   field 1 = VIN
   *   field 2 = Location 消息 { field 1 = 经度, field 2 = 纬度, field 3 = Timestamp }
   *   field 3 = stale 标志（非 0 表示数据陈旧）
   */
  static applyParkedLocation(response: Uint8Array, state: VehicleState): void {
    // 顶层：field 2 是位置消息，field 3 是 stale 标志。
    const outer = new ProtoReader(response).decode();
    const locationBytes = ProtoValue.get(outer, 2);
    if (!(locationBytes instanceof Uint8Array)) {
      Log.warn('最后停车位置响应缺少 field 2');
      return;
    }
    const location = new ProtoReader(locationBytes).decode();

    // 还原自 ga0.m1407V：
    //   latitude  = field 2（f1786e0）
    //   longitude = field 1（f1788f0）
    // 注意与直觉相反 —— field 1 是经度，field 2 才是纬度。
    const longitude = ProtoValue.asFiniteNumber(ProtoValue.get(location, 1));
    const latitude = ProtoValue.asFiniteNumber(ProtoValue.get(location, 2));
    if (latitude === undefined || longitude === undefined ||
      latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180) {
      Log.warn(`最后停车位置响应中没有有效坐标: lat=${latitude} lon=${longitude}`);
      return;
    }
    state.parkedLatitude = latitude;
    state.parkedLongitude = longitude;

    // field 3 是嵌套消息，其 field 1 为停车时间戳。
    const timeBytes = ProtoValue.get(location, 3);
    if (timeBytes instanceof Uint8Array) {
      const timeFields = new ProtoReader(timeBytes).decode();
      const timestamp = ProtoValue.get(timeFields, 1);
      if (typeof timestamp === 'number') {
        state.parkedTimestamp = timestamp;
      }
    }

    // 顶层 field 3 非 0 表示数据陈旧（stale）。
    const stale = ProtoValue.get(outer, 3);
    state.parkedLocationStale = typeof stale === 'number' && stale !== 0;

    state.parkedLocationStateAt = Date.now();
  }

  /**
   * 读取车型信息（电池容量 / 市场内容码）。对应 ga0.m1408W。
   */
  static async readCarInfo(client: GrpcClient, vin: string, state: VehicleState): Promise<void> {
    const uuidBytes = GrpcClient.utf8(VehicleStateReader.newUuid());
    const vinBytes = GrpcClient.utf8(vin);
    const payload = new Uint8Array(uuidBytes.length + vinBytes.length + 4);

    let offset = 0;
    // field 1 = request id
    payload[offset++] = 0x0a;
    payload[offset++] = uuidBytes.length;
    payload.set(uuidBytes, offset);
    offset += uuidBytes.length;
    // field 2 = VIN
    payload[offset++] = 0x12;
    payload[offset++] = vinBytes.length;
    payload.set(vinBytes, offset);

    const response = await client.call(
      GrpcClient.SERVICE_CAR_INFO, 'GetMyCars', vin, payload, 12000);
    const outer = new ProtoReader(response).decodeAll();

    // field 1 为重复字段，需要保留全部条目逐个比对
    const carList = outer.get(1);
    if (carList === undefined) {
      return;
    }
    for (const car of carList) {
      if (!(car instanceof Uint8Array)) {
        continue;
      }
      const entry = new ProtoReader(car).decode();
      const inner = ProtoValue.get(entry, 1);
      if (!(inner instanceof Uint8Array)) {
        continue;
      }
      const detail = new ProtoReader(inner).decode();
      const detailVin = ProtoValue.decodeString(ProtoValue.get(detail, 1));
      if (detailVin.toLowerCase() !== vin.toLowerCase()) {
        continue;
      }
      // field 40 -> field 5 为电池容量（float）
      const wrapper = ProtoValue.get(detail, 40);
      if (wrapper instanceof Uint8Array) {
        const inner2 = new ProtoReader(wrapper).decode();
        const capacity = ProtoValue.get(inner2, 5);
        if (capacity instanceof Uint8Array && capacity.length === 4) {
          const kwh = ProtoValue.asFloat(capacity);
          if (!Number.isNaN(kwh) && kwh > 0) {
            state.batteryCapacityKwh = kwh;
          }
        }
      }
      return;
    }
  }

  /**
   * 读取全部状态域（部分失败不影响其他域）。
   *
   * @param client gRPC 客户端
   * @param vin    车辆 VIN
   * @param state  待填充的状态对象
   */
  static async readAll(client: GrpcClient, vin: string, state: VehicleState): Promise<void> {
    const tasks: StateReadTask[] = [
      { name: 'carinfo', run: () => VehicleStateReader.readCarInfo(client, vin, state) },
      { name: 'battery', run: () => VehicleStateReader.readBattery(client, vin, state) },
      { name: 'exterior', run: () => VehicleStateReader.readExterior(client, vin, state) },
      { name: 'climate', run: () => VehicleStateReader.readClimate(client, vin, state) },
      { name: 'air', run: () => VehicleStateReader.readAir(client, vin, state) },
      { name: 'odometer', run: () => VehicleStateReader.readOdometer(client, vin, state) },
      { name: 'health', run: () => VehicleStateReader.readHealth(client, vin, state) },
      { name: 'parkedlocation', run: () => VehicleStateReader.readParkedLocation(client, vin, state) }
    ];

    for (const task of tasks) {
      try {
        await task.run();
      } catch (err) {
        // 单域失败不影响其余域，与 Android 端行为一致
        Log.warn(`读取 ${task.name} 状态失败: ${(err as Error).message}`);
      }
    }
  }

  /**
   * 生成 UUID v4。
   */
  static newUuid(): string {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      const v = c === 'x' ? r : (r & 0x3 | 0x8);
      return v.toString(16);
    });
  }
}
