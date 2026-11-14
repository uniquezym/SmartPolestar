# 车辆 API 接口能力清单

> 源 APK：`polestar-assistant-v0.3.36-20261109-224558-release.apk`（`app.c3garage.companion`，App 版本 4.25.0）
> 反编译产物：`d:\Project\极星APP\recovered`（`sources/`、`resources/`）
> 文档日期：2026-11-13

本文梳理极星云端 API 自身支持的能力：**支持查询哪些状态、支持控制哪些功能**。不涉及客户端实现情况。

---

## 一、接口总览

原版 App 与极星云端的全部交互分为三类通道。

| 通道 | 协议 | 主机 | 用途 |
|---|---|---|---|
| gRPC | HTTP/2 + protobuf | `{c3Host}` / `{c3LbsHost}` | 车辆状态查询与车控指令下发 |
| REST（网关） | HTTPS + JSON | `gw.app.polestar-auto.com` | 账号登录与令牌续期 |
| REST（发现） | HTTPS + JSON | `cnepmob.volvocars.com.cn` | 解析 C3 与 LBS 主机地址 |

**gRPC 服务清单（8 个）**

| 服务全名 | 主机 | 用途 |
|---|---|---|
| `services.vehiclestates.battery.BatteryService` | C3 | 电池与充电状态 |
| `services.vehiclestates.exterior.ExteriorService` | C3 | 车锁、车门、车窗、尾门等外饰状态 |
| `services.vehiclestates.parkingclimatization.ParkingClimatizationService` | C3 | 驻车空调状态 |
| `services.vehiclestates.precleaning.PreCleaningService` | C3 | 空气净化状态 |
| `services.vehiclestates.odometer.OdometerService` | C3 | 里程与能耗 |
| `services.vehiclestates.health.HealthService` | C3 | 车辆健康与保养 |
| `invocation.InvocationService` | C3 | 全部车控指令下发 |
| `chronos.services.v1.ParkingClimateTimerService` | LBS | 驻车空调定时任务 |
| `dtlinternet.DtlInternetService` | LBS | 最后停车位置 |
| `car_information.CarInformation` | C3 | 账号下车辆列表与车型 |
| `ota_mobcache.OtaDiscoveryService` | C3 | 软件版本与 OTA 状态 |

---

## 二、状态查询能力

所有 gRPC 请求携带 `authorization`（Bearer token）与 `vin` 两个元数据头。

### 2.1 车辆列表与车型

| 项 | 内容 |
|---|---|
| 服务 | `car_information.CarInformation` |
| 方法 | `GetMyCars` |
| 请求体 | field 1 = 请求 UUID（string），field 2 = VIN（string） |
| 查询能力 | 账号下全部车辆、每辆车的 VIN、车型代号、市场内容码、电池容量 |

### 2.2 电池与充电

| 项 | 内容 |
|---|---|
| 服务 | `services.vehiclestates.battery.BatteryService` |
| 方法 | `GetLatestBattery` |
| 响应外层 | field 3 |
| 查询能力 | 电量百分比、预计续航、充电状态、充电枪连接状态、充电类型、充电桩供电状态、充电功率、充电电流、充满剩余时长 |

**字段号对照**

| 字段 | 含义 | 取值 |
|---|---|---|
| 2 | 电量 | 整数百分比 |
| 4 | 预计续航 | 整数 km |
| 5 | 充满剩余时长 | 整数分钟 |
| 6 | 充电枪连接状态 | 未知 / 已连接 / 未连接 / 连接故障 |
| 7 | 充电状态 | 未指定 / 充电中 / 空闲 / 计划中 / 放电中 / 错误 / 智能充电 / 已完成 / 智能充电暂停 |
| 10 | 充电功率 | 整数 W |
| 11 | 充电电流 | 浮点 A |
| 12 / 13 | 自动 / 自充电均耗 | kWh/100km |
| 14 / 15 / 16 | 手动 / 自动 / 自充电累计能耗 | Wh |
| 17 | 充电类型 | 未知 / 未充电 / 交流 / 直流 / 无线 |
| 26 | 充电桩供电状态 | 未知 / 无电源 / 初始化中 / 可用 / 正在供电 / 故障 |

### 2.3 外饰（车锁 / 门 / 窗 / 尾门）

| 项 | 内容 |
|---|---|
| 服务 | `services.vehiclestates.exterior.ExteriorService` |
| 方法 | `GetLatestExterior` |
| 响应外层 | field 3 |
| 查询能力 | 整车锁状态、四门开关状态、四窗开关状态、尾门状态、尾门锁状态、机盖状态、充电口状态 |

**字段号对照**

| 字段 | 含义 | 取值 |
|---|---|---|
| 2 | 整车锁 | 未知 / 未锁 / 已锁 |
| 3 ~ 6 | 前左 / 前右 / 后左 / 后右 车门 | 逐门状态码 |
| 7 ~ 10 | 前左 / 前右 / 后左 / 后右 车窗 | 逐窗状态码（0 关闭，1/3 未关闭） |
| 11 | 机盖 | 状态码 |
| 12 | 尾门 | 未知 / 已打开 / 已关闭 / 未关严 |
| 13 | 充电口 | 状态码 |
| 16 | 尾门锁 | 未知 / 未锁 / 已锁 |

### 2.4 驻车空调

| 项 | 内容 |
|---|---|
| 服务 | `services.vehiclestates.parkingclimatization.ParkingClimatizationService` |
| 方法 | `GetLatestParkingClimatization` |
| 响应外层 | field 3 |
| 查询能力 | 空调开关状态、剩余运行时长、运行模式、车内温度、设定温度 |

**字段号对照**

| 字段 | 含义 | 取值 |
|---|---|---|
| 2 | 开关状态 | 未知 / 开启 / 关闭 / 处理中 |
| 3 | 剩余运行时长 | 整数分钟 |
| 6 | 运行模式 | 1 = 制冷 · 2 = 制热 · 其他值 = 送风（气流） |
| 7 | 车内温度 | 浮点 ℃ |
| 8 | 设定温度 | 浮点 ℃ |

> **字段 6 的语义说明**：原版**不把它作为文字显示**，只用于选择状态卡图标 ——
> 值为 `1` 显 `ic_climate_cool`（雪花）、值为 `2` 显 `ic_climate_heat`（上升热气）、
> 其余显 `ic_climate_airflow`（气流）。
>
> 早期分析曾把该字段误记为「内循环 / 外循环」，但原版代码中不存在「循环模式」这一概念，
> 全局搜索「循环 / 内循环 / 外循环」无任何命中，该映射无依据。
> 云端也未开放循环模式（内循环 / 外循环）的查询或控制接口。

### 2.5 空气净化

| 项 | 内容 |
|---|---|
| 服务 | `services.vehiclestates.precleaning.PreCleaningService` |
| 方法 | `GetLatestPreCleaning` |
| 响应外层 | field 3 |
| 查询能力 | 净化开关状态、空气质量指数（AQI）、PM2.5 浓度 |

**字段号对照**

| 字段 | 含义 | 取值 |
|---|---|---|
| 6 | 开关状态 | 未知 / 开启 / 关闭 / 处理中 |
| 9 | AQI | 整数 |
| 10 | PM2.5 | 浮点 μg/m³ |

### 2.6 里程与能耗

| 项 | 内容 |
|---|---|
| 服务 | `services.vehiclestates.odometer.OdometerService` |
| 方法 | `GetLatestOdometer` |
| 响应外层 | field 3 |
| 查询能力 | 总里程、手动小计里程、自动小计里程、自充电小计里程、平均车速 |

**字段号对照**

| 字段 | 含义 |
|---|---|
| 2 | 总里程（单位米） |
| 3 / 4 / 7 | 手动 / 自动 / 自充电小计里程 |
| 5 / 6 / 8 | 手动 / 自动 / 自充电平均车速 |

### 2.7 车辆健康与保养

| 项 | 内容 |
|---|---|
| 服务 | `services.vehiclestates.health.HealthService` |
| 方法 | `GetLatestHealth` |
| 响应外层 | field 3 |
| 查询能力 | 30 项健康位、保养状态、剩余工时 / 天数 / 里程、外部灯光状态 |

**字段号对照**

| 字段 | 含义 | 取值 |
|---|---|---|
| 2 / 3 / 4 | 剩余工时 / 天数 / 里程 | 数值 |
| 5 | 保养状态 | 未提供 / 正常 / 未知警告 / 保养将近 / 发动机工时将近 / 里程将近 / 需要保养 / 发动机工时到期 / 里程到期 / 保养逾期 / 发动机工时逾期 / 里程逾期 |
| 6 | 制动液 | 未提供 / 正常 / 液位偏低 / 液位严重偏低 |
| 7 | 冷却液 | 未提供 / 正常 / 液位偏低 |
| 9 ~ 12 | 四轮胎压 | 未提供 / 正常 / 胎压过低 / 胎压偏低 / 胎压偏高 |
| 13 | 雨刮液 | 未提供 / 正常 / 液位偏低 |
| 14 ~ 35 | 其余逐项健康位 | 状态码 |
| 38 | 12V 电池 | 未提供 / 正常 / 电量偏低 |
| 46 | 外部灯光分组 | 状态码集合 |

**总评判定规则**：任一项 &gt; 1 → `需关注`；否则全部为 0 或无数据 → `未知`；否则 → `良好`。

### 2.8 最后停车位置

| 项 | 内容 |
|---|---|
| 服务 | `dtlinternet.DtlInternetService` |
| 方法 | `GetLastParkedLocation` |
| 主机 | LBS |
| 请求体 | field 1 = VIN（string） |
| 查询能力 | 最后停车经纬度、停车时间、停车时里程 |

**字段号对照**

| 字段 | 含义 |
|---|---|
| 1 | 纬度 |
| 2 | 经度 |
| 3 | 停车时间戳 |
| 4 | 停车时里程 |

### 2.9 驻车空调定时任务

| 项 | 内容 |
|---|---|
| 服务 | `chronos.services.v1.ParkingClimateTimerService` |
| 方法 | `GetLatestTimers` |
| 主机 | LBS |
| 请求体 | field 1 = VIN（嵌套消息） |
| 查询能力 | 已设定的全部空调定时任务，含任务标识、时段、启用状态、生效日 |

**响应字段号对照**

| 字段 | 含义 |
|---|---|
| 3 | 定时任务列表（重复字段） |
| 1（任务内） | 任务标识 |
| 2（任务内） | 时段索引 |
| 3（任务内） | 起始时间（内含 field 1 小时 / field 2 分钟） |
| 4（任务内） | 是否激活 |
| 5（任务内） | 是否循环 |
| 6（任务内） | 生效日集合 |

### 2.10 软件版本与 OTA

| 项 | 内容 |
|---|---|
| 服务 | `ota_mobcache.OtaDiscoveryService` |
| 方法 | `GetSoftwareInfo` |
| 请求体 | field 1 = VIN（string），field 2 = 语言码（string，如 `zh-CN`） |
| 查询能力 | 当前软件版本号、可用更新名称、更新状态、是否可安装 |

**响应字段号对照**

| 字段 | 含义 |
|---|---|
| 2 | 更新信息（内含 field 1 更新名称） |
| 4 | 更新状态 |
| 6 | 当前版本号 |
| 8 | 是否存在可用更新 |

**更新状态枚举**：状态未知 / 可下载 / 正在下载 / 下载完成 / 下载失败 / 已开始安装 / 正在安装 / 已中止 / 安装失败 / 已完成 / 已延期 / 关键安装失败 / 已预约安装 / 预约安装已触发。

---

## 三、功能控制能力

全部车控指令走同一个服务 `invocation.InvocationService`，靠方法名区分动作。

**请求体统一结构**

| 字段 | 类型 | 内容 |
|---|---|---|
| field 1 | length-delimited | 嵌套消息，其内部 field 1 = VIN |
| field 2 | varint | 动作枚举 |
| field 3 | fixed32 | 目标温度，仅 `ClimatizationStart` 使用 |

### 3.1 车锁

| 动作 | RPC 方法 | field 2 枚举 | 说明 |
|---|---|---|---|
| 解锁车辆 | `Unlock` | 3 | 整车解锁 |
| 锁定车辆 | `Lock` | 0 | 整车加锁 |
| 解锁尾门 | `Unlock` | 1 | 仅尾门解锁 |
| 锁定尾门 | `Lock` | 1 | 仅尾门上锁 |

### 3.2 尾门

| 动作 | RPC 方法 | field 2 枚举 | 说明 |
|---|---|---|---|
| 打开尾门 | `TailgateControl` | 1 | |
| 关闭尾门 | `TailgateControl` | 2 | |

### 3.3 车窗

| 动作 | RPC 方法 | field 2 枚举 | 说明 |
|---|---|---|---|
| 打开全部车窗 | `WindowControl` | 1 | 四窗同时开 |
| 关闭全部车窗 | `WindowControl` | 2 | 四窗同时关 |

> 该接口不支持单独控制某一扇车窗。

### 3.4 驻车空调

| 动作 | RPC 方法 | 附加字段 | 说明 |
|---|---|---|---|
| 开启空调 | `ClimatizationStart` | field 3 = 22.0（fixed32） | 目标温度固定 22℃ |
| 关闭空调 | `ClimatizationStop` | — | |

> 该接口不支持自定义目标温度，固定下发 22℃。

### 3.5 空气净化

| 动作 | RPC 方法 | field 2 枚举 | 说明 |
|---|---|---|---|
| 开启空气净化 | `PreCleaning` | 1 | |
| 关闭空气净化 | `PreCleaning` | 0 | |

### 3.6 寻车

| 动作 | RPC 方法 | field 2 枚举 | 说明 |
|---|---|---|---|
| 鸣笛并闪灯 | `HonkFlash` | 0 | |
| 仅鸣笛 | `HonkFlash` | 1 | |
| 仅闪灯 | `HonkFlash` | 2 | |

### 3.7 空调定时任务

| 动作 | RPC 方法 | 主机 | 请求体 |
|---|---|---|---|
| 新建 / 更新定时 | `SetTimers` | LBS | field 1 = VIN（嵌套），field 2 = 任务配置 |
| 删除定时 | `DeleteTimer` | LBS | field 1 = VIN（嵌套），field 2 = 任务标识（string） |

**`SetTimers` 的 field 2 任务配置结构**

| 字段 | 含义 |
|---|---|
| 1 | 任务标识（string，空表示新建） |
| 2 | 时段索引（varint） |
| 3 | 起始时间（嵌套：field 1 小时 / field 2 分钟） |
| 4 | 是否激活（varint 0/1） |
| 5 | 是否循环（varint 0/1） |
| 6 | 生效日集合（重复 varint） |

---

## 四、账号与令牌接口

| 接口 | 方法 | 请求体 | 响应 |
|---|---|---|---|
| `gw.app.polestar-auto.com/user/api/v2/oauth/login/password` | POST | `clientId` / `phone` / `password` / `autocrt` | `data.globleToken` 内含 `accessToken`、`refreshToken`、`expiresIn` |
| `gw.app.polestar-auto.com/user/api/v2/oauth/refresh-global-token` | POST | `refreshToken` | 同上，新令牌对 |
| `cnepmob.volvocars.com.cn/` | GET | — | `c3` 与 `c3Lbs` 主机地址 |
| `{c3Host}/car-information/car` | GET | — | 车辆列表（JSON） |

**网关请求签名**：query 串按 key 排序后拼接，以固定盐值包裹做 MD5，输出 `sign` 参数。参与签名的字段含 `appId`、`timestamp`、`nonce`、`deviceId`、`deviceModel`、`brand`、`clientType`、`systemVer`、`appVer`。

---

## 五、能力边界小结

| 维度 | 结论 |
|---|---|
| 状态查询 | 覆盖 10 类状态域：车辆信息、电池充电、外饰、驻车空调、空气净化、里程能耗、健康保养、停车位置、空调定时、OTA |
| 功能控制 | 覆盖 7 类控制域：车锁（整车 + 尾门）、尾门开合、车窗开合、驻车空调、空气净化、寻车、空调定时 |
| 已知限制 | 车窗只能四窗整组开关，无单车窗控制；驻车空调目标温度固定 22℃，不可设定；门与机盖、充电口仅可查不可控 |
| 未开放的域 | 充电功率、充电电流、充满时间、目标温度、空调循环模式（内循环 / 外循环）、充电计划、充电时段等均为只读，无对应控制接口 |
