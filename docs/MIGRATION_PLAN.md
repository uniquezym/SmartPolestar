# 极星助手 Android → HarmonyOS 移植方案

> 源 APK：`polestar-assistant-v0.3.36-20261109-224558-release.apk`（`app.c3garage.companion`）
> 目标工程：`D:\Work\study\project\SmartPolestar`
> 目标平台：HarmonyOS 6.1.0 (API 23)，Stage 模型，ArkTS + ArkUI，纯 ArkTS 实现
> 文档日期：2026-11-10

---

## 一、已确认的四项决策

| 决策项 | 选定方案 |
|---|---|
| gRPC 传输 | **自研轻量 gRPC 传输层**（TLSSocket + ALPN h2 + 自实现 HTTP/2 帧层 + protobuf 编解码） |
| 后台策略 | **长时任务 + 前台通知常驻**（`backgroundTaskManager` BLUETOOTH_INTERACTION） |
| 功能范围 | **核心链路优先**：登录鉴权 + 状态展示 + 核心车控 + 数据层；图表/俯视图/卡片交互/露营模式留二期 |
| 实现语言 | **纯 ArkTS**，不引入 C++ Native |

---

## 二、目标工程现状

已确认可直接复用，无需重建工程骨架：

| 项 | 现状 |
|---|---|
| SDK | `C:\Program Files\Huawei\DevEco Studio\sdk\default\{openharmony,hms}`，apiVersion 23 / 6.1.0.28 |
| 构建 | DevEco Studio + hvigor，`targetSdkVersion 6.1.0(23)`，`runtimeOS HarmonyOS` |
| 签名 | `default` 签名配置已就绪（`.ohos\config\default_SmartPolestar_*.cer/.p12/.p7b`） |
| 模块 | `entry` 模块，`mainElement: EntryAbility`，stage 模型，deviceTypes `["phone","2in1"]` |
| 现状 | 脚手架 Hello World + 一个 NAPI 示例（`libentry.so`），**已能成功产出签名 HAP**（`entry-default-signed.hap`） |
| 依赖 | 当前 `dependencies` 为空；`devDependencies` 为 hypium 1.0.25 / hamock 1.0.0 |

**关键缺口**：目标工程目前**没有任何业务代码**，全部为脚手架产物。

---

## 三、协议可行性实测结论

这是本次方案最关键的验证部分，直接决定 gRPC 自研的工作量边界。

### 3.1 服务发现（已实测通过）

`GET https://cnepmob.volvocars.com.cn/`，Accept `application/volvo.cloud.cnepmob.v1+json`：

```json
{
  "c3": {
    "grpcHost": "cepmobtoken.prod.c3.volvocars.com.cn",
    "grpcKeepAliveTime": 45,
    "grpcPort": 443,
    "url": "https://cepmobtoken.prod.c3.volvocars.com.cn"
  },
  "c3Lbs": {
    "grpcHost": "cepmobtoken.lbs.prod.c3.volvocars.com.cn",
    "grpcKeepAliveTime": 45,
    "grpcPort": 443,
    "url": "https://cepmobtoken.lbs.prod.c3.volvocars.com.cn"
  }
}
```

注意 `url` 字段与 `grpcHost` 同值 —— 同一主机同时提供 REST 与 gRPC。

### 3.2 ALPN h2 协商（已实测通过）

| 主机 | TLS | ALPN | Cipher |
|---|---|---|---|
| `cepmobtoken.prod.c3.volvocars.com.cn` | TLSv1.3 | **h2** | TLS_AES_128_GCM_SHA256 |
| `cepmobtoken.lbs.prod.c3.volvocars.com.cn` | TLSv1.3 | **h2** | TLS_AES_128_GCM_SHA256 |

后端为 AWS ELB（`Server: awselb/2.0`）。用 HTTP/1.1 探测返回 `505 HTTP Version Not Supported`，反证服务端是纯 HTTP/2。

**结论**：HarmonyOS `TLSSocket.connect()` 的 `ALPNProtocols: ['h2']` 可直接完成协商，**无需自研 TLS 层**。

### 3.3 REST 旁路（部分可用，作为降级预案）

| 路径 | 响应 | 判读 |
|---|---|---|
| `/car-information/car` | **401** | 端点存在，仅缺 Bearer token |
| `/car-information/vin` | **401** | 端点存在 |
| `/vehicle/vin`、`/vehiclestates/battery` 等 | 404 | 不存在 |

状态类服务的 REST 版本未开放，**gRPC 仍是唯一通道**。

### 3.4 HarmonyOS 侧 API 可用性（读 SDK `.d.ts` 确认）

| 能力 | 结论 | 关键 API |
|---|---|---|
| TLS Socket + ALPN | 支持 | `@ohos.net.socket` `TLSSocket.connect()` / `ALPNProtocols` |
| HTTP/2 帧层 | **需自研** | SDK 无 gRPC、无 HTTP/2 帧实现 |
| protobuf | 三方可用 | OHPM `protobufjs` 可拉取（已验证 status=200） |
| BLE 扫描 + RSSI | 支持 | `@ohos.bluetooth.ble` `ScanResult.rssi` |
| 加速度计 | 支持 | `@ohos.sensor` `SensorId.ACCELEROMETER` |
| 长时任务 | 支持 | `@ohos.resourceschedule.backgroundTaskManager` `MODE_BLUETOOTH_INTERACTION=5`；API 21+ `BackgroundTaskSubmode.SUBMODE_CAR_KEY_NORMAL_NOTIFICATION=1` |
| 密钥存储 | 支持 | `@ohos.security.huks` AES-256-GCM（HUKS_ALG_AES=20 / HUKS_MODE_GCM=32 / AE_TAG / NONCE 齐备） |
| 持久化 | 支持 | `@ohos.data.preferences`（Preferences）、`@ohos.data.relationalStore`（SQLite，支持 `encrypt`） |
| 服务卡片 | 支持 | **正确命名为 Form / `@kit.FormKit`**（SDK 中无 `appwidget`），`FormExtensionAbility.onFormEvent` + `postCardAction` |
| 生物识别 | 支持 | `@ohos.userIAM` |
| 周期任务 | 受限 | `workScheduler` 最小周期 20 分钟（Android 原为 15 分钟） |

---

## 四、能力映射与缺口清单

| Android 能力 | HarmonyOS 对应 | 状态 | 处置 |
|---|---|---|---|
| grpc-java over h2 | 自研 HTTP/2 + protobuf | ⚠️ **需自研** | 阶段二核心任务，见 §六 |
| 服务发现 REST | `@ohos.net.http` | ✅ 平移 | |
| 账号网关 REST | `@ohos.net.http` | ✅ 平移 | |
| GraphQL 车型图 | `@ohos.net.http` | ✅ 平移 | |
| AndroidKeyStore AES-GCM | `@ohos.security.huks` | ✅ 替换 | 密钥留 TEE，密文+IV+Tag 存 Preferences |
| SharedPreferences | `@ohos.data.preferences` | ✅ 平移 | |
| Room(SQLite) | `@ohos.data.relationalStore` | ✅ 平移 | |
| WorkManager 15min | `workScheduler` 20min / 长时任务 | ⚠️ 周期受限 | 露营模式二期改长时任务驱动 |
| 前台服务 START_STICKY | `backgroundTaskManager` 长时任务 | ⚠️ 机制不同 | 选定的长时任务方案 |
| BLE 后台扫描 | `MODE_BLUETOETOOTH_INTERACTION` | ⚠️ 需长时任务 | 退后台仍会被系统停扫，**需真机验证** |
| 加速度计后台采样 | 同上 | ⚠️ 需长时任务 | 同上 |
| Google 活动识别 | **无等价物** | ❌ 缺失 | 二期以自研运动判定替代 |
| 小组件按钮 → 透明 Activity → 指纹 | Form `postCardAction` + `onFormEvent` | ❌ 交互模型不同 | 二期重写为卡片消息回调 |
| 附近充电站（唤起高德） | 无高德 App | ❌ 缺失 | 改为跳转系统地图或砍掉 |
| 自研 Canvas 图表（k40, 511 行） | `ohos.charts` / ArkUI Canvas | ⚠️ 需重建 | 二期 |
| 车辆俯视图交互控件（g10） | ArkUI Canvas + Path | ⚠️ 需重写 | 二期 |
| 图片 LruCache 手写 | `Image` + PixelMap + 自建缓存 | ⚠️ 需自建 | 首期仅需 22 张车型 WebP |

### 已确认的"好消息"

- **无任何第三方商业库依赖**：38 个 `.version` 文件全是 Google/AndroidX 官方组件；gRPC/protobuf/gson 是"混淆后伪装成 p000"的内置栈。
- **App 自有资源极少**：257 张图片中 221 张是 AndroidX 自带（`abc_*`，鸿蒙端全部可丢弃），自有仅 36 张（22 张是车型 WebP 渲染图）；55 个 VectorDrawable 需转 SVG；字体仅 1 个 Noto Sans SC（鸿蒙系统自带，可直接删除）。
- **App 自有 layout 仅 4 个**（3 个 widget + 1 个 fingerprint dialog），其余 28 个是 AppCompat/Material 自带。

---

## 五、工程结构设计

```
SmartPolestar/
├── entry/src/main/
│   ├── ets/
│   │   ├── entryability/EntryAbility.ets        # 入口，启动长时任务协调器
│   │   ├── pages/
│   │   │   ├── Index.ets                        # 主页面（状态总览）
│   │   │   ├── Login.ets                        # 登录页
│   │   │   └── Control.ets                      # 车控页
│   │   ├── core/
│   │   │   ├── session/                         # 会话与令牌
│   │   │   │   ├── SessionStore.ets             # Preferences 持久化
│   │   │   │   ├── TokenVault.ets               # HUKS AES-GCM 封装
│   │   │   │   └── AuthService.ets              # 登录 / 刷新 / 签名
│   │   │   ├── net/
│   │   │   │   ├── HttpClient.ets               # @ohos.net.http 封装
│   │   │   │   ├── ServiceDiscovery.ets         # cnepmob + 主机白名单
│   │   │   │   └── grpc/
│   │   │   │       ├── GrpcChannel.ets           # TLSSocket + ALPN + 连接复用
│   │   │   │       ├── Http2Frame.ets            # HTTP/2 帧编解码
│   │   │   │       ├── Http2Stream.ets           # 流控与多路复用
│   │   │   │       ├── GrpcCall.ets              # 一元调用封装
│   │   │   │       └── GrpcStatus.ets            # 状态码映射
│   │   │   ├── proto/
│   │   │   │   ├── ProtoWriter.ets               # varint / 定长 / length-delimited
│   │   │   │   ├── ProtoReader.ets               # 字段号 -> 值映射
│   │   │   │   └── schemas/                       # 各服务字段号映射
│   │   │   ├── model/
│   │   │   │   ├── VehicleState.ets              # 74 字段聚合状态
│   │   │   │   ├── VehicleCommand.ets            # 15 个动作枚举
│   │   │   │   └── SessionState.ets
│   │   │   └── vehicle/
│   │   │       └── VehicleRepository.ets         # 状态读取聚合层
│   │   ├── service/
│   │   │   └── BackgroundKeeper.ets              # 长时任务申请/维持
│   │   └── common/
│   │       ├── Log.ets
│   │       └── GeoUtils.ets                      # Haversine
│   └── resources/base/
│       ├── element/                               # 颜色/字符串/尺寸（抽取硬编码常量）
│       ├── media/                                 # 车型 WebP + 图标 SVG
│       └── profile/
├── entry/src/test/                                # 单元测试
│   ├── ProtoCodec.test.ets
│   ├── Signature.test.ets
│   └── Http2Frame.test.ets
```

### 关键设计要点

1. **Protobuf 手写而非依赖 protobufjs**：Android 端本就是手写 wire-format（`ga0.m1363b0/m1364c/m1374j/m1376k`），且已还原字段映射。手写可保持与原实现逐字节一致，并复用已通过的 22 项自验证用例作为测试基线。`Protobuf.ets` 直接移植 `recovered/src/main/java/.../proto/Protobuf.java` 的逻辑。

2. **HTTP/2 帧层只实现 gRPC 需要的子集**：
   - 帧类型：DATA(0)、HEADERS(1)、WINDOW_UPDATE(8)、PING(6)、GOAWAY(7)、RST_STREAM(3)
   - HPACK 编码：**只支持静态表 + 增量编码（literal without indexing）**，服务端 metadata 仅 `authorization`、`vin`、`content-type`、`te`、`user-agent`，无需完整 Huffman 解码
   - 流控：基于 `SETTINGS_INITIAL_WINDOW_SIZE` 与 WINDOW_UPDATE 的最小实现
   - 全部为**一元调用**（服务端流 `GetSoftwareInfo` 二期再处理）

3. **签名与鉴权严格对齐原实现**：`MD5(SECRET + canonical + SECRET)`、9 参数字典序、`URLEncoder` 的 `+`→`%20` / `%7E`→`~` 特殊处理，均可从已还原的 `RequestSigner.java` 直接移植，并用同样输入比对输出。

4. **Host 白名单保留**：`(?i)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+volvocars\.com\.cn`。

---

## 六、阶段划分与交付物

### 阶段一：数据层与协议底座（无 UI，可独立验证）

| # | 任务 | 产出 | 验收 |
|---|---|---|---|
| 1.1 | 工程骨架搭建 | 模块结构、目录、资源抽取、常量入 `element/` | `hvigor` 构建通过 |
| 1.2 | HUKS 令牌保险箱 | `TokenVault.ets` | 加密→读回→解密一致 |
| 1.3 | 会话存储 | `SessionStore.ets` | token blob 往返 |
| 1.4 | 签名算法 | `AuthService.ets` 签名部分 | **与 Android 端同输入产出同 sign** |
| 1.5 | HTTP 客户端 + 服务发现 | `HttpClient.ets` / `ServiceDiscovery.ets` | 取得 c3/c3Lbs 主机 |
| 1.6 | Protobuf 编解码 | `ProtoWriter/Reader.ets` | **复用 22 项用例的等价断言** |
| 1.7 | HTTP/2 帧层 | `Http2Frame.ets` | HEADERS/DATA 往返、HPACK 编解码 |
| 1.8 | gRPC 通道 | `GrpcChannel.ets` + `GrpcCall.ets` | TLS 握手成功、ALPN=h2 |
| 1.9 | 状态读取 | `VehicleRepository.ets` | **真实调用 GetLatestBattery 拿到电量/续航** |

**阶段一的关键验收点**：在无 UI 的情况下，用真实账号从 HarmonyOS 侧完整跑通"登录 → 服务发现 → gRPC 拉取电量"。这验证了移植的协议底座是否成立。

### 阶段二：核心链路 UI + 车控

| # | 任务 | 产出 |
|---|---|---|
| 2.1 | 登录页 + 免责声明 | `Login.ets` |
| 2.2 | 会话管理 | 启动加载、过期刷新、失效跳登录 |
| 2.3 | 状态总览页 | 电量、续航、充电状态、车锁、门窗、尾门、空调、位置、里程 |
| 2.4 | 核心车控 | 解锁/锁车、尾门、车窗、空调启停、空气净化、鸣笛闪灯（15 个动作全量接入） |
| 2.5 | 车控确认 | 调 `@ohos.userIAM` 指纹验证 + 降级确认框 |
| 2.6 | 长时任务 | `BackgroundKeeper.ets`，BLE 交互类型 + 常驻通知 |

### 阶段三（二期，本次仅预留接口）

- 自研 Canvas 图表（`k40` 等价物）→ `ohos.charts`
- 车辆俯视图交互控件（`g10` 等价物）→ ArkUI Canvas
- 服务卡片 ×2（Form Extension，含按钮交互）
- 露营模式状态机（长时任务驱动，替代 15 分钟 WorkManager）
- 自动化规则（BLE + FFT 步态 + 活动识别替代方案）
- 里程趋势图与能耗统计
- 附近充电站（系统地图跳转替代高德）
- OTA 自更新（HarmonyOS 应用内更新机制替代 PackageInstaller）

---

## 七、风险与已知约束

| 风险 | 等级 | 说明与对策 |
|---|---|---|
| **设备 TLS 栈缺 ALPN** | 🔴 已解决 | OpenHarmony 7.0 的 netstack curl 与 `native/tls_socket` 均不协商 ALPN，设备上所有 HTTPS 实测降级为 HTTP/1.1，导致 AWS ELB 返回 464。**改用 RCP（`@kit.RemoteCommunicationKit`）**，其内建 HTTP/2 帧层，不依赖系统 TLS 的 ALPN |
| **RCP 自带解析器返回不可达 IP** | 🔴 已解决 | RCP 走自己的 DNS（真机日志 `dnsFromNetsys:0`），可能解析出连不上的地址且只试这一个 → TCP 超时。**改为用 `connection.getAddressesByName()` 取系统解析结果并写入 `dns.dnsRules` 固定 IP** |
| **无真机 / 无模拟器** | 🟠 中 | 本机 `hdc list targets` 为空，SDK 无模拟器镜像。长时任务后台行为、15 个车控动作、指纹验证仍需真机闭环 |
| BLE / 传感器后台行为 | 🟠 中 | 官方明确"无长时任务退后台强制停扫"，长时任务也非绝对保证。需真机实测退后台 5/15/30 分钟的行为 |
| Google 活动识别无等价物 | 🟠 中 | 影响"乘车保护"逻辑精度。替代方案：结合 BLE 近场 + 加速度计积分判定 |
| WorkScheduler 20 分钟下限 | 🟢 低 | 露营模式改为长时任务内自定时器 |
| 小组件交互模型不同 | 🟡 中 | 卡片内不能弹 Activity，指纹验证需两段式（卡片→主 Ability→回写卡片） |
| 账号 / 车机状态依赖 | 🟢 低 | 需真实中国区账号与绑定车辆才能验证业务链路 |

---

## 八、验证策略

1. **协议层对照测试**：用 Python `grpcio` 在 PC 端构造相同的 gRPC 请求，比对 HarmonyOS 侧 `Http2Frame.ets` 输出的帧字节，确保 HTTP/2 编码正确。
2. **算法回归**：Android 端已还原并通过 22 项断言的 protobuf / RSSI / FFT 算法，移植后以 ArkTS 单元测试（hypium）复刻同样的断言集。
3. **签名一致性**：同一组参数分别在 Android 还原代码与 ArkTS 实现上计算 sign，比对 32 位小写 hex 完全一致。
4. **端到端**：真机登录 → 拉取状态 → 执行一次车控（建议先用"鸣笛闪灯"这类无副作用动作）。

---

## 九、需要你补充的信息

1. **真实中国区极星账号与已绑定车辆** —— 阶段一.9 起必需，用于验证 gRPC 真实调用。
2. **是否接受阶段一无法在本机闭环** —— 若需本机内完成真机验证，需要你提供真机连接（`hdc list targets` 需出现设备）或开通模拟器。
3. **gRPC 服务端是否有其他开放计划** —— 若服务端愿意为鸿蒙开放状态类 REST 接口，可显著降低阶段一.7/1.8 的工作量（已验证 `/car-information/*` 端点族存在）。
4. **应用名与包名** —— 是否沿用"极星助手"，以及 bundleName 是否沿用现有 `SmartPolestar`。

---

## 十、确认后立即启动的内容

确认本方案后，我将立即开始**阶段一**，具体顺序：

1. 搭建工程骨架与目录结构，抽取资源常量
2. 实现 HUKS `TokenVault` 与 `SessionStore`
3. 移植签名算法 `AuthService.signRequest`
4. 实现 `HttpClient` 与 `ServiceDiscovery`
5. 移植 `Protobuf` 编解码并编写 ArkTS 单元测试
6. 实现 `Http2Frame` / `Http2Stream` / `GrpcChannel`
7. 用真实账号验证 `GetLatestBattery` 全链路
