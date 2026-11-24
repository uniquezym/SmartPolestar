import { common } from '@kit.AbilityKit';
import { VehicleRepository } from '../core/vehicle/VehicleRepository';
import { VehicleCapability } from '../core/vehicle/VehicleCapability';
import { VehicleCapabilityService } from '../core/vehicle/VehicleCapabilityService';
import { VehicleSnapshot, SnapshotGroup } from '../core/vehicle/VehicleSnapshot';
import { CapabilityCard, CapabilityItem } from '../components/CapabilityCard';
import { SnapshotCard } from '../components/SnapshotCard';
import { Log } from '../common/Log';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'Capability';

/**
 * 车辆能力页 —— 展示这台车到底支持哪些功能，以及当前是什么状态。
 *
 * 这一页是**只读**的：探测结果仅供查看，暂不参与各功能的可用性判断。
 *
 * 两个数据源：
 *   能力探测 `GET {c3Host}/car-information/car` —— 官方 App 也用这个接口
 *        里的 `supports*` 字段决定功能按钮是否出现。
 *   状态快照 gRPC vehiclestates 各域 —— 车身、电池、里程、空调、净化、
 *        健康、可用性等当前值。
 *
 * 能力探测结果会持久化，下次进来先显示上次的快照，再重新探测一次。
 */
@Entry
@Component
struct Capability {
  /** 页面上下文。 */
  private context: common.UIAbilityContext | undefined = undefined;
  /** 仓储。 */
  private repository: VehicleRepository | undefined = undefined;
  /** 能力服务。 */
  private capabilityService: VehicleCapabilityService | undefined = undefined;

  /** 是否正在探测。 */
  @State detecting: boolean = false;
  /** 探测是否成功。 */
  @State fetched: boolean = false;
  /** 错误信息。 */
  @State error: string = '';
  /** 探测时间。 */
  @State detectedAt: number = 0;

  /** 车辆 VIN。 */
  @State vin: string = '';
  /** 车型名。 */
  @State modelName: string = '';
  /** 车型年款。 */
  @State modelYear: string = '';
  /** 市场。 */
  @State market: string = '';
  /** 车牌号。 */
  @State registrationPlate: string = '';
  /** 驱动位。 */
  @State driverSide: string = '';
  /** 远控类型。 */
  @State remoteControlType: string = '';
  /** 数字钥匙类型。 */
  @State digitalKeyType: string = '';
  /** 充电定时器类型。 */
  @State chargeTimerType: string = '';
  /** 本账号是否为车主。 */
  @State userIsOwner: boolean = false;
  /** 本账号是否已绑定。 */
  @State userIsLinked: boolean = false;
  /** 生产周次。 */
  @State structureWeek: number = 0;
  /** 用户端软件版本。 */
  @State consumerSoftwareVersion: string = '';

  /**
   * 能力快照。分组与条目都从这里现算。
   */
  @State capability: VehicleCapability | undefined = undefined;

  /**
   * 按分组预先算好的能力项。
   *
   * 不在 build 里现算 —— entriesOfGroup 是全表遍历，
   * 九个分组每次渲染要跑近千轮。探测结果变了才重算一次。
   */
  @State groupItems: CapabilityItem[][] = [];
  /** 各分组已开启的能力数。 */
  @State groupEnabled: number[] = [];

  /**
   * 只读状态快照的分组。
   */
  @State snapshotGroups: SnapshotGroup[] = [];
  /** 状态快照是否已读取。 */
  @State snapshotReady: boolean = false;

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.repository = new VehicleRepository(this.context);
    this.capabilityService = new VehicleCapabilityService(this.context, this.repository);
    // 先显示上次探测的快照 —— 冷启动不该从空白开始。
    const cached = this.capabilityService.loadCached();
    if (cached !== undefined) {
      this.applyCapability(cached);
    }
    // 再探测一次，拿到最新结果。
    this.detect();
  }

  /**
   * 发起探测。
   */
  private async detect(): Promise<void> {
    if (this.repository === undefined || this.capabilityService === undefined) {
      return;
    }
    this.detecting = true;
    try {
      await this.repository.loadSession();
      const capability = await this.capabilityService.detect('');
      if (capability !== undefined) {
        this.applyCapability(capability);
      }
    } catch (err) {
      Log.warn(TAG, `能力探测失败: ${(err as Error).message}`);
    } finally {
      this.detecting = false;
    }
    // 能力探测完成后再读状态快照 —— 两次网络请求串行，避免互相拖慢。
    await this.loadSnapshot();
  }

  /**
   * 读取只读状态快照。
   */
  private async loadSnapshot(): Promise<void> {
    if (this.repository === undefined) {
      return;
    }
    try {
      let targetVin = this.vin;
      if (targetVin.length === 0) {
        const vins = await this.repository.fetchVehicles();
        if (vins.length > 0) {
          targetVin = vins[0];
        }
      }
      if (targetVin.length === 0) {
        return;
      }
      const state = await this.repository.readSnapshot(targetVin);
      this.snapshotGroups = VehicleSnapshot.groups(state);
      this.snapshotReady = true;
    } catch (err) {
      Log.warn(TAG, `状态快照读取失败: ${(err as Error).message}`);
    }
  }

  /**
   * 把探测结果映射到页面状态。
   */
  private applyCapability(capability: VehicleCapability): void {
    this.capability = capability;
    this.fetched = capability.fetched;
    this.error = capability.error;
    this.detectedAt = capability.detectedAt;
    this.vin = capability.vin;
    this.modelName = capability.modelName;
    this.modelYear = capability.modelYear;
    this.market = capability.market;
    this.registrationPlate = capability.registrationPlate;
    this.driverSide = capability.driverSide;
    this.remoteControlType = capability.remoteControlType;
    this.digitalKeyType = capability.digitalKeyType;
    this.chargeTimerType = capability.chargeTimerType;
    this.userIsOwner = capability.userIsOwner;
    this.userIsLinked = capability.userIsLinked;
    this.structureWeek = capability.structureWeek;
    this.consumerSoftwareVersion = capability.consumerSoftwareVersion;

    // 按分组预先算好，避免每次渲染都全表遍历。
    const items: CapabilityItem[][] = [];
    const enabled: number[] = [];
    for (const group of VehicleCapability.GROUPS) {
      const groupEntries = VehicleCapability.entriesOfGroup(capability, group);
      const list: CapabilityItem[] = [];
      for (const entry of groupEntries) {
        list.push({
          title: entry.title,
          key: entry.key,
          desc: entry.desc,
          supported: entry.supported,
          value: entry.value
        });
      }
      items.push(list);
      enabled.push(VehicleCapability.enabledInGroup(capability, group).length);
    }
    this.groupItems = items;
    this.groupEnabled = enabled;
  }

  /**
   * 探测时间的展示文案。
   */
  private detectedText(): string {
    if (this.detectedAt <= 0) {
      return '尚未探测';
    }
    const date = new Date(this.detectedAt);
    const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
      `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  }

  /**
   * 车辆档案摘要行。
   */
  @Builder
  private profileRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12.5)
        .fontColor($r('app.color.app_secondary_text'))

      Blank()

      Text(value.length > 0 ? value : '—')
        .fontSize(12.5)
        .fontColor($r('app.color.app_primary_text'))
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ top: 8, bottom: 8 })
    .border({ width: { bottom: 1 }, color: $r('app.color.app_rule') })
  }

  /**
   * 区块标题。
   */
  @Builder
  private sectionTitle(title: string, subtitle: string) {
    Column({ space: 3 }) {
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_primary_text'))
      Text(subtitle)
        .fontSize(10.5)
        .fontColor($r('app.color.app_tertiary_text'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ top: 10, bottom: 2 })
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        // ---------- 页头 ----------
        Row() {
          Column({ space: 5 }) {
            Text('车辆能力')
              .fontSize(23)
              .fontWeight(FontWeight.Normal)
              .fontColor($r('app.color.app_primary_text'))
            Text(this.detecting ? '正在探测…' : '本车支持的功能与当前状态')
              .fontSize(11)
              .fontColor($r('app.color.app_tertiary_text'))
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('重新探测')
            .fontSize(12)
            .fontColor($r('app.color.app_accent_text'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor($r('app.color.app_accent_soft_bg'))
            .borderRadius(6)
            .onClick(() => {
              this.detect();
            })
        }
        .width('100%')
        .padding({ top: 20, bottom: 4 })

        // ---------- 错误提示 ----------
        if (!this.fetched && this.error.length > 0) {
          Column({ space: 4 }) {
            Text('能力探测失败')
              .fontSize(13)
              .fontColor($r('app.color.app_error'))
            Text(this.error)
              .fontSize(11)
              .fontColor($r('app.color.app_tertiary_text'))
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ top: 12, left: 14, right: 14, bottom: 12 })
          .backgroundColor($r('app.color.app_error_soft'))
          .borderRadius(8)
        }

        // ---------- 车辆档案 ----------
        if (this.fetched) {
          Column() {
            Text('车辆档案')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.app_secondary_text'))
              .width('100%')
              .padding({ bottom: 4 })

            this.profileRow('车型', `${this.modelName} ${this.modelYear}`)
            this.profileRow('市场', this.market)
            this.profileRow('车牌', this.registrationPlate)
            this.profileRow('驱动位', this.driverSide)
            this.profileRow('远控类型', this.remoteControlType)
            this.profileRow('数字钥匙', this.digitalKeyType)
            this.profileRow('充电定时器', this.chargeTimerType)
            this.profileRow('账号身份', this.userIsOwner ? '车主' : (this.userIsLinked ? '已绑定' : '未绑定'))
            this.profileRow('生产周次', this.structureWeek > 0 ? `${this.structureWeek} 周` : '')
            this.profileRow('软件版本', this.consumerSoftwareVersion)
            this.profileRow('探测时间', this.detectedText())
          }
          .width('100%')
          .padding({ top: 12, left: 16, right: 16, bottom: 12 })
          .border({ width: 1, color: $r('app.color.app_rule') })
          .borderRadius(8)
        }

        // ---------- 分组能力 ----------
        this.sectionTitle('功能支持情况', '服务端下发的能力开关与限制值')
        ForEach(VehicleCapability.GROUPS, (group: string, index: number) => {
          CapabilityCard({
            groupTitle: group,
            items: this.groupItems[index],
            enabledCount: this.groupEnabled[index]
          })
        }, (group: string) => group)

        // ---------- 只读状态快照 ----------
        if (this.snapshotReady) {
          this.sectionTitle('当前状态', '车端实时上报的只读信息')
          ForEach(this.snapshotGroups, (group: SnapshotGroup) => {
            SnapshotCard({ groupTitle: group.title, items: group.items })
          }, (group: SnapshotGroup) => group.title)
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .backgroundColor($r('app.color.app_background'))
  }
}
