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
    state.exteriorStateAt = Date.now();
  }

  /**
   * 读取驻车空调状态。对应 ga0.m1358R。
   */
  static async readClimate(client: GrpcClient, vin: string, state: VehicleState): Promise<void> {
    const response = await client.callStatus(
      GrpcClient.SERVICE_CLIMATIZATION, 'GetLatestParkingClimatization', vin);
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
    const fields = VehicleStateReader.unwrap(response, 3);

    state.air = VehicleState.enumLabel(ProtoValue.asInteger(ProtoValue.get(fields, 6)), AIR_LABELS);
    state.airQualityIndex = ProtoValue.asInteger(ProtoValue.get(fields, 9));
    state.pm25UgM3 = ProtoValue.asFiniteNumber(ProtoValue.get(fields, 10));
    state.airStateAt = Date.now();
  }

  /**
   * 读取里程。对应 ga0 的 odometer 分支。
   */
  static async readOdometer(client: GrpcClient, vin: string, state: VehicleState): Promise<void> {
    const response = await client.callStatus(GrpcClient.SERVICE_ODOMETER, 'GetLatestOdometer', vin);
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
    state.healthStateAt = Date.now();
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
