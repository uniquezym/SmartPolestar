# 极星2 车主助手（SmartPolestar）

极星车主 App 的 HarmonyOS 原生移植版 —— 纯 ArkTS 实现，Stage 模型。

> 源应用：`app.c3garage.companion`（极星助手 v0.3.36，Android）
> 目标平台：HarmonyOS 6.1.0 / API 23

---

## 当前状态

协议链路已在真机跑通，登录 → 拉取车辆列表 → 读取 6 个状态域（电量 / 车锁门窗 / 驻车空调 / 空气净化 / 里程 / 健康）全部成功。

| 模块 | 状态 |
|---|---|
| 账号登录与令牌续期 | ✅ 真机验证 |
| C3 gRPC 状态读取 | ✅ 真机验证（6 个接口 `grpc-status=0`） |
| 车控指令（解锁/锁定/尾门/车窗/空调/寻车） | ⏳ 待真机验证 |
| 指纹验证 | ⏳ 待真机验证 |
| 长时任务后台保活 | ⏳ 待真机验证 |
| 图表 / 车辆俯视图 / 服务卡片 / 露营模式 | ⏳ 二期 |

---

## 这个项目在解决什么

移植过程中最大的障碍不是业务逻辑，而是**平台能力缺失**：

### 1. 设备 TLS 栈不协商 ALPN → HTTP/2 无法建立

C3 后端前面是 AWS ELB（`Server: awselb/2.0`），目标组协议是 gRPC/HTTP2。
用 HTTP/1.1 语义发送会被直接拒绝：

```
HTTP/1.1 464
Server: awselb/2.0
# "Load Balancer received an incompatible request protocol"
```

根因在 OpenHarmony 7.0：`native/tls_socket` 建立 TLS 上下文后**完全不设置 ALPN**，
netstack 的 curl 也没传 `CURLOPT_SSL_ENABLE_ALPN`。设备上所有 HTTPS 请求实测都是
HTTP/1.1（curl 枚举 `CURL_HTTP_VERSION_1_1 = 2`，日志里就是 `httpVer:2`）。

**解法**：改用华为自研的 RCP（Remote Communication Kit），它独立于 netstack curl，
内建 HTTP/2 帧层，不依赖系统 TLS 的 ALPN 协商。

### 2. RCP 自带解析器返回不可达地址

RCP 不走系统 netstack 解析 DNS（真机日志 `dnsFromNetsys:0`），
可能解析出连不上的地址且只试这一个 → TCP 超时。

**解法**：用 `connection.getAddressesByName()` 取系统解析结果，
写入 `configuration.dns.dnsRules` 固定 IP，并开启 `happyEyeballOnDnsRule`。

### 3. ArkUI 的 `@Builder` 多参数不刷新

`@Builder` 默认按值传递参数，状态变量变化**不会**引起 Builder 内的 UI 刷新；
参数 ≥ 2 且未用按回调传递时完全不会动态渲染。
表现为「数据全对、日志正常，但界面永远是 —」。

**解法**：状态卡片改用 `@Component` + `@Prop` 子组件（`components/StatusCard.ets`）。

---

## 工程结构

```
entry/src/main/ets/
├── components/
│   └── StatusCard.ets           # @Component + @Prop 状态卡片
├── core/
│   ├── model/
│   │   ├── SessionState.ets     # 会话上下文
│   │   └── VehicleState.ets     # 车辆聚合状态（74 字段）
│   ├── net/
│   │   ├── HttpClient.ets       # REST 客户端
│   │   ├── ServiceDiscovery.ets # 服务发现 + 主机白名单校验
│   │   ├── VehicleCommands.ets  # 车控指令构造
│   │   ├── VehicleStateReader.ets # 状态字段映射
│   │   └── grpc/
│   │       ├── GrpcClient.ets    # gRPC 门面（鉴权重试）
│   │       ├── GrpcRcpChannel.ets# RCP 传输层（当前使用）
│   │       ├── GrpcChannel.ets   # 自研 HTTP/2（保留备查）
│   │       ├── GrpcHttpChannel.ets # netstack http（保留备查）
│   │       └── Http2Frame.ets    # HTTP/2 帧层 + HPACK
│   ├── proto/
│   │   ├── ProtoReader.ets      # protobuf 解码
│   │   └── ProtoWriter.ets      # protobuf 编码
│   ├── session/
│   │   ├── AuthService.ets      # 登录 / 续期
│   │   ├── RequestSigner.ets    # 请求签名
│   │   ├── SessionStore.ets     # 会话持久化
│   │   └── TokenVault.ets       # HUKS 令牌保险箱
│   └── vehicle/
│       ├── BiometricGuard.ets   # 指纹验证
│       ├── ControlCoordinator.ets # 车控编排
│       └── VehicleRepository.ets  # 数据仓储
├── pages/
│   ├── Index.ets                # 状态总览页
│   └── Login.ets                # 登录页
└── service/
    └── BackgroundKeeper.ets     # 长时任务保活
```

---

## 构建

需要 DevEco Studio（HarmonyOS SDK 6.1.0 / API 23）。

```powershell
$env:DEVECO_SDK_HOME = "C:\Program Files\Huawei\DevEco Studio\sdk"
$env:JAVA_HOME      = "C:\Program Files\Huawei\DevEco Studio\jbr"
$env:PATH = "C:\Program Files\Huawei\DevEco Studio\tools\node;C:\Program Files\Huawei\DevEco Studio\jbr\bin;$env:PATH"

$hv = "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat"
& $hv --mode module -p product=default -p module=entry@default -p buildMode=debug assembleHap --no-daemon
& $hv --mode module -p product=default -p module=entry@default -p buildMode=debug test --no-daemon
```

产物：`entry/build/default/outputs/default/entry-default-signed.hap`

> `DEVECO_SDK_HOME` 必须指向 SDK **根目录**（不是 `sdk\default`），
> 否则报 `00303217 Configuration Error`。
> `jbr\bin` 必须在 PATH 里，否则 `PackageHap` 阶段报 `spawn java ENOENT`。

### 签名配置

`build-profile.json5` 含签名密钥与密码，由 DevEco Studio 在本机生成，**不入版本库**。
仓库中提供 `build-profile.json5.template` 作为结构参考；
克隆后用 DevEco Studio 打开工程会自动生成对应文件。

---

## 测试

ArkTS 单元测试（hypium）位于 `entry/src/test/`，共 37 个用例：

- protobuf wire-format 编解码
- HPACK 编码器与 Python `hpack` 库逐字节对齐
- HTTP/2 帧编解码
- C3 请求体结构（字段号 / 嵌套 VIN）
- 状态响应解包
- 会话序列化、枚举映射

---

## 协议要点

### 主机与接口

| 用途 | 主机 | 协议 |
|---|---|---|
| 账号网关 | `gw.app.polestar-auto.com` | REST |
| 服务发现 | `cnepmob.volvocars.com.cn` | REST |
| 车辆状态 / 车控 | `cepmobtoken.prod.c3.volvocars.com.cn` | gRPC |
| 位置 / 空调定时 | `cepmobtoken.lbs.prod.c3.volvocars.com.cn` | gRPC |
| 账号 / 车辆列表 | `pc-api.polestar.com` | GraphQL |

### C3 请求体结构（因接口而异，不可混用）

| 接口类型 | 结构 |
|---|---|
| 状态查询 | **field 2 = VIN**，field 1 留空 |
| 车控 | **field 1 = 嵌套字节**，其内部 field 1 = VIN |
| GetMyCars | field 1 = 请求 UUID，field 2 = VIN |
| GetLastParkedLocation | field 1 = VIN |

字段放错 → 服务端返回 `grpc-status 7 (PERMISSION_DENIED)`。

### C3 响应体结构

状态类接口的响应外层是 **field 3**（需先解一层），dtlinternet 是 **field 2**。

---

## 安全说明

- 令牌存于 HUKS（AES-256-GCM），不落明文
- 服务发现返回的主机名须匹配 `*.volvocars.com.cn` 白名单，防止 DNS 污染
- `RequestSigner.SECRET` 是客户端请求签名密钥（公开存在于 APK 内），属协议常量而非账号凭据

---

## 文档

- [`docs/MIGRATION_PLAN.md`](docs/MIGRATION_PLAN.md) —— 移植方案与风险清单
