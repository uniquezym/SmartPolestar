import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { VehicleRepository } from '../core/vehicle/VehicleRepository';
import { ControlCoordinator } from '../core/vehicle/ControlCoordinator';
import { VehicleCommands } from '../core/net/VehicleCommands';
import { VehicleState } from '../core/model/VehicleState';
import { StatusCard } from '../components/StatusCard';
import { BusinessError, Log } from '../common/Log';

/**
 * 车辆状态总览页。
 *
 * 对应 Android 端 MainActivity 的状态卡片区（电量 / 续航 / 充电 / 车锁 / 门窗 / 空调 / 里程）。
 */
@Entry
@Component
struct Index {
  @State loading: boolean = false;
  @State errorMessage: string = '';
  @State hasSession: boolean = false;

  @State battery: number = -1;
  @State range: number = -1;
  @State charging: string = '—';
  @State chargingDetail: string = '';
  @State locked: string = '—';
  @State windows: string = '—';
  @State tailgate: string = '—';
  @State climate: string = '—';
  @State odometer: string = '—';
  @State health: string = '—';
  @State vin: string = '';

  private context: common.UIAbilityContext | undefined = undefined;
  private repository: VehicleRepository | undefined = undefined;

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.repository = new VehicleRepository(this.context);
    this.bootstrap();
  }

  /**
   * 加载会话并拉取状态。
   */
  private async bootstrap(): Promise<void> {
    if (this.repository === undefined) {
      return;
    }
    this.loading = true;
    this.errorMessage = '';
    try {
      await this.repository.loadSession();
      this.hasSession = true;
      await this.refresh();
    } catch (err) {
      const e = err as BusinessError;
      if (e.code === 401) {
        // 未登录，跳转登录页
        this.getUIContext().getRouter().replaceUrl({ url: 'pages/Login' });
        return;
      }
      this.errorMessage = e.message.length > 0 ? e.message : '加载失败';
      Log.error(`加载失败: ${e.message}`);
    } finally {
      this.loading = false;
    }
  }

  /**
   * 刷新车辆状态。
   */
  private async refresh(): Promise<void> {
    if (this.repository === undefined) {
      return;
    }
    this.loading = true;
    try {
      const states = await this.repository.readAllStates();
      if (states.length === 0) {
        this.errorMessage = '账号下没有发现车辆';
        return;
      }
      this.applyState(states[0]);
    } catch (err) {
      const e = err as BusinessError;
      this.errorMessage = e.message.length > 0 ? e.message : '状态读取失败';
      Log.error(`状态读取失败: ${e.message}`);
    } finally {
      this.loading = false;
    }
  }

  /**
   * 把状态对象映射到 UI 字段。
   */
  private applyState(state: VehicleState): void {
    this.vin = state.vin;
    this.battery = state.battery ?? -1;
    this.range = state.range ?? -1;
    this.charging = state.charging;
    this.chargingDetail = this.buildChargingDetail(state);
    this.locked = state.locked;
    this.windows = state.windows;
    this.tailgate = state.tailgate;
    this.climate = state.climate;
    this.odometer = state.odometerKm !== undefined ?
      `${Math.round(state.odometerKm).toLocaleString()} km` : '—';
    this.health = state.healthStatus;
  }

  /**
   * 拼装充电详情文案。
   */
  private buildChargingDetail(state: VehicleState): string {
    const parts: string[] = [];
    if (state.chargerConnection !== '未知') {
      parts.push(state.chargerConnection);
    }
    if (state.chargingType !== '未知' && state.chargingType !== '未充电') {
      parts.push(state.chargingType);
    }
    if (state.timeToFullMinutes !== undefined && state.timeToFullMinutes > 0) {
      parts.push(`约 ${state.timeToFullMinutes} 分钟充满`);
    }
    if (state.powerWatts !== undefined && state.powerWatts > 0) {
      parts.push(`${state.powerWatts} W`);
    }
    return parts.join(' · ');
  }

  /**
   * 执行车控动作。
   */
  private async control(action: string): Promise<void> {
    if (this.repository === undefined || this.context === undefined) {
      return;
    }
    const client = this.repository.getClient();
    const session = this.repository.getSession();
    if (client === undefined || session === undefined) {
      this.errorMessage = '会话未就绪，请重试';
      return;
    }

    const coordinator = new ControlCoordinator(this.context, session, client);
    await coordinator.execute(this.vin, action, (success: boolean, message: string) => {
      if (!success) {
        promptAction.showToast({ message: message });
      } else {
        // 执行成功后刷新状态
        this.refresh();
      }
    });
  }

  /**
   * 构建一个操作按钮。
   */
  @Builder
  actionButton(label: string, action: string, primary: boolean) {
    Button(label)
      .fontSize(14)
      .height(42)
      .layoutWeight(1)
      .backgroundColor(primary ?
        $r('app.color.app_accent') : $r('app.color.app_accent_soft'))
      .fontColor(primary ?
        $r('app.color.app_on_accent') : $r('app.color.app_primary_text'))
      .onClick(() => {
        this.control(action);
      })
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        // 顶部标题栏
        Row() {
          Column({ space: 2 }) {
            Text('极星2')
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.app_primary_text'))
            if (this.vin.length > 0) {
              Text(`VIN …${this.vin.substring(this.vin.length - 6)}`)
                .fontSize(12)
                .fontColor($r('app.color.app_secondary_text'))
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          if (this.loading) {
            LoadingProgress()
              .width(24)
              .height(24)
              .color($r('app.color.app_accent'))
          } else {
            Button('刷新')
              .fontSize(14)
              .height(36)
              .backgroundColor($r('app.color.app_accent_soft'))
              .fontColor($r('app.color.app_primary_text'))
              .onClick(() => {
                this.refresh();
              })
          }
        }
        .width('100%')
        .padding({ top: 20, bottom: 4 })

        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize(13)
            .fontColor($r('app.color.app_health_error'))
            .width('100%')
            .padding(12)
            .backgroundColor($r('app.color.app_card_background'))
            .borderRadius(8)
        }

        // 电量与续航
        Row({ space: 12 }) {
          StatusCard({ title: $r('app.string.state_battery'),
            value: this.battery >= 0 ? `${this.battery}%` : '—' })
          StatusCard({ title: $r('app.string.state_range'),
            value: this.range >= 0 ? `${this.range} km` : '—' })
        }
        .width('100%')

        // 充电状态
        StatusCard({ title: $r('app.string.state_charging'),
          value: this.charging, detail: this.chargingDetail })

        // 车门与车窗
        StatusCard({ title: '车门与车窗', value: this.locked,
          detail: `车窗 ${this.windows} · 尾门 ${this.tailgate}` })

        // 驻车空调
        StatusCard({ title: $r('app.string.state_climate'), value: this.climate })

        // 里程与健康
        Row({ space: 12 }) {
          StatusCard({ title: $r('app.string.state_odometer'), value: this.odometer })
          StatusCard({ title: '车辆健康', value: this.health })
        }
        .width('100%')

        // 车锁控制
        Column({ space: 10 }) {
          Text('车锁')
            .fontSize(13)
            .fontColor($r('app.color.app_secondary_text'))
            .width('100%')
          Row({ space: 12 }) {
            this.actionButton('解锁车辆', VehicleCommands.ACTION_UNLOCK, true)
            this.actionButton('锁定车辆', VehicleCommands.ACTION_LOCK, false)
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .backgroundColor($r('app.color.app_card_background'))
        .borderRadius(10)

        // 尾门与车窗
        Column({ space: 10 }) {
          Text('尾门与车窗')
            .fontSize(13)
            .fontColor($r('app.color.app_secondary_text'))
            .width('100%')
          Row({ space: 12 }) {
            this.actionButton('打开尾门', VehicleCommands.ACTION_TRUNK_OPEN, false)
            this.actionButton('关闭尾门', VehicleCommands.ACTION_TRUNK_CLOSE, false)
          }
          .width('100%')
          Row({ space: 12 }) {
            this.actionButton('打开车窗', VehicleCommands.ACTION_WINDOWS_OPEN, false)
            this.actionButton('关闭车窗', VehicleCommands.ACTION_WINDOWS_CLOSE, false)
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .backgroundColor($r('app.color.app_card_background'))
        .borderRadius(10)

        // 空调与空气净化
        Column({ space: 10 }) {
          Text('空调与空气净化')
            .fontSize(13)
            .fontColor($r('app.color.app_secondary_text'))
            .width('100%')
          Row({ space: 12 }) {
            this.actionButton('开启空调', VehicleCommands.ACTION_CLIMATE_START, true)
            this.actionButton('关闭空调', VehicleCommands.ACTION_CLIMATE_STOP, false)
          }
          .width('100%')
          Row({ space: 12 }) {
            this.actionButton('开启净化', VehicleCommands.ACTION_AIR_START, false)
            this.actionButton('关闭净化', VehicleCommands.ACTION_AIR_STOP, false)
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(16)
        .backgroundColor($r('app.color.app_card_background'))
        .borderRadius(10)

        // 寻车
        Row({ space: 12 }) {
          this.actionButton('鸣笛', VehicleCommands.ACTION_HONK, false)
          this.actionButton('闪灯', VehicleCommands.ACTION_FLASH, false)
          this.actionButton('鸣笛并闪灯', VehicleCommands.ACTION_HONK_FLASH, false)
        }
        .width('100%')

        // 退出登录
        Button('退出登录')
          .fontSize(14)
          .height(44)
          .width('100%')
          .backgroundColor($r('app.color.app_accent_soft'))
          .fontColor($r('app.color.app_health_error'))
          .margin({ top: 8, bottom: 24 })
          .onClick(() => {
            this.logout();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
  }

  /**
   * 退出登录并返回登录页。
   */
  private async logout(): Promise<void> {
    if (this.repository !== undefined) {
      await this.repository.logout();
    }
    this.getUIContext().getRouter().replaceUrl({ url: 'pages/Login' });
  }
}
