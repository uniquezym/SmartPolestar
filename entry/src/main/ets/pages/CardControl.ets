import { common } from '@kit.AbilityKit';
import { VehicleRepository } from '../core/vehicle/VehicleRepository';
import { ControlCoordinator } from '../core/vehicle/ControlCoordinator';
import { VehicleCommands } from '../core/net/VehicleCommands';
import { BiometricGuard, BiometricResult } from '../core/vehicle/BiometricGuard';
import { CardPublisher } from '../core/vehicle/CardPublisher';
import { CardIntent } from '../core/vehicle/CardIntent';
import { BusinessError, Log } from '../common/Log';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'CardControl';

/**
 * 卡片触发的车控确认页。
 *
 * 卡片上的按钮通过 router 事件跳到这里，走完整的安全链路：
 *   指纹验证 → 二次确认弹窗 → 下发指令 → 轮询车端确认 → 回写卡片
 *
 * 【为什么不在卡片里直接执行】
 *   - 卡片进程（FormExtensionAbility）生命周期只有 10 秒，做不了「验证 → 下发 → 轮询」
 *   - 指纹认证控件需要 UI 上下文，卡片进程弹不出来
 *   - 卡片按钮无法承载二次确认弹窗
 *
 * 【与原版对齐】
 *   Android 端的 WidgetControlActivity 同样是「先指纹、再弹确认框」，
 *   指纹不可用时降级为「直接执行」的确认框（见 m485p）。
 */
@Entry
@Component
struct CardControl {
  /** 控制项：lock / climate。 */
  @State control: string = '';
  /** 车辆 VIN。 */
  @State vin: string = '';
  /** 车辆当前状态文案（车锁 / 空调）。 */
  @State currentState: string = '';
  /** 提示信息。 */
  @State message: string = '';
  /** 执行中。 */
  @State busy: boolean = false;
  /** 流程是否已结束（结束则自动返回）。 */
  @State finished: boolean = false;

  private context: common.UIAbilityContext | undefined = undefined;
  private repository: VehicleRepository | undefined = undefined;

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.repository = new VehicleRepository(this.context);
    this.start();
  }

  /**
   * 读取控制项。
   *
   * 控制项由 EntryAbility 解析卡片事件后写入 CardIntent，
   * 这里读取并清空 —— 不依赖路由 params（loadContent 无 params 重载）。
   */
  private start(): void {
    this.control = CardIntent.take();
    if (this.control.length === 0) {
      this.message = '无效的卡片操作';
      this.finished = true;
      return;
    }
    this.run();
  }

  /**
   * 控制项的中文名。
   */
  private controlLabel(): string {
    return this.control === 'lock' ? '车锁' : '驻车空调';
  }

  /**
   * 完整的车控流程。
   */
  private async run(): Promise<void> {
    if (this.repository === undefined || this.context === undefined) {
      this.message = '会话未就绪，请重试';
      this.finished = true;
      return;
    }

    // 1. 加载会话与车辆
    try {
      await this.repository.loadSession();
      const vins = await this.repository.fetchVehicles();
      if (vins.length === 0) {
        this.message = '账号下没有发现车辆';
        this.finished = true;
        return;
      }
      this.vin = vins[0];
    } catch (err) {
      const e = err as BusinessError;
      this.message = e.code === 401 ? '请先打开应用登录后再使用卡片控制' : e.message;
      this.finished = true;
      return;
    }

    // 2. 读当前状态 —— 决定是锁定还是解锁 / 开启还是关闭
    const current = await this.readCurrentState();
    if (current === undefined) {
      this.message = '车辆状态不可用，请先打开应用同步车辆';
      this.finished = true;
      return;
    }
    this.currentState = current;

    // 3. 指纹验证
    const capability = await BiometricGuard.checkAvailable();
    if (capability !== BiometricResult.SUCCESS) {
      // 指纹不可用：降级为「二次确认」而不是直接放行 ——
      // 与原版 WidgetControlActivity.m485p 的行为一致。
      this.confirmWithoutFingerprint(BiometricGuard.fallbackMessage(capability));
      return;
    }

    const result = await BiometricGuard.verify('确认车辆操作');
    if (result !== BiometricResult.SUCCESS) {
      this.message = '未通过指纹验证，未发送车辆指令';
      this.finished = true;
      return;
    }

    // 4. 二次确认
    this.confirm();
  }

  /**
   * 读取控制项的当前状态文案。
   *
   * @returns 状态文案；读取失败时返回 undefined
   */
  private async readCurrentState(): Promise<string | undefined> {
    const repository = this.repository;
    if (repository === undefined) {
      return undefined;
    }
    try {
      if (this.control === 'lock') {
        const state = await repository.readDomain('exterior', this.vin);
        if (state.locked === '未锁') {
          return '未锁';
        }
        if (state.locked === '已锁') {
          return '已锁';
        }
        return undefined;
      }
      const state = await repository.readDomain('climate', this.vin);
      if (state.climate === '开启') {
        return '开启';
      }
      if (state.climate === '关闭') {
        return '关闭';
      }
      return undefined;
    } catch (err) {
      Log.warn(TAG, `读取车辆状态失败: ${(err as Error).message}`);
      return undefined;
    }
  }

  /**
   * 指纹不可用时的降级确认：说明原因 + 列出将执行的操作。
   */
  private confirmWithoutFingerprint(reason: string): void {
    this.getUIContext().showAlertDialog({
      title: '指纹验证不可用',
      message: `${reason}\n\n确认后将直接执行以下车辆操作：\n${this.actionDescription()}`,
      primaryButton: {
        value: '取消',
        action: () => {
          this.message = '已取消';
          this.finished = true;
        }
      },
      secondaryButton: {
        value: '确认并执行',
        fontColor: $r('app.color.app_polar'),
        action: () => {
          this.execute();
        }
      }
    });
  }

  /**
   * 指纹通过后的二次确认。
   */
  private confirm(): void {
    this.getUIContext().showAlertDialog({
      title: '确认车辆操作',
      message: this.actionDescription(),
      primaryButton: {
        value: '取消',
        action: () => {
          this.message = '已取消';
          this.finished = true;
        }
      },
      secondaryButton: {
        value: '确认并执行',
        fontColor: $r('app.color.app_polar'),
        action: () => {
          this.execute();
        }
      }
    });
  }

  /**
   * 将要执行的操作描述。
   */
  private actionDescription(): string {
    if (this.control === 'lock') {
      return this.currentState === '未锁'
        ? '验证后锁定车辆'
        : '验证后解锁车辆';
    }
    return this.currentState === '开启'
      ? '验证后关闭驻车空调'
      : '验证后开启驻车空调';
  }

  /**
   * 下发指令并等待车端确认。
   */
  private async execute(): Promise<void> {
    if (this.busy || this.repository === undefined || this.context === undefined) {
      return;
    }
    const session = this.repository.getSession();
    const client = this.repository.getClient();
    if (session === undefined || client === undefined) {
      this.message = '会话未就绪，请重试';
      this.finished = true;
      return;
    }

    this.busy = true;
    this.message = '指令下发中…';

    // 按当前状态决定动作
    const action = this.control === 'lock'
      ? (this.currentState === '未锁' ? VehicleCommands.ACTION_LOCK : VehicleCommands.ACTION_UNLOCK)
      : (this.currentState === '开启'
        ? VehicleCommands.ACTION_CLIMATE_STOP
        : VehicleCommands.ACTION_CLIMATE_START);

    try {
      const coordinator = new ControlCoordinator(this.context, session, client);
      await coordinator.execute(this.vin, action, (success: boolean, msg: string) => {
        if (!success) {
          this.busy = false;
          this.message = msg.length > 0 ? msg : `${this.controlLabel()}指令下发失败`;
          this.finished = true;
          return;
        }
        this.confirmResult(action);
      });
    } catch (err) {
      const e = err as BusinessError;
      this.busy = false;
      this.message = e.message.length > 0 ? e.message : '车控执行异常';
      this.finished = true;
    }
  }

  /**
   * 轮询车端状态直到确认指令生效。
   *
   * 与主应用 confirmToggle 同一套判定：按动作判定目标状态，
   * 而不是看当前状态 —— 开启空调后车端在真正启动前仍返回「关闭」。
   */
  private async confirmResult(action: string): Promise<void> {
    const repository = this.repository;
    if (repository === undefined) {
      this.busy = false;
      this.finished = true;
      return;
    }
    const budgetMs: number = 12000;
    const startedAt: number = Date.now();
    let interval: number = 300;
    const target: string = this.control === 'lock'
      ? (action === VehicleCommands.ACTION_LOCK ? '已锁' : '未锁')
      : (action === VehicleCommands.ACTION_CLIMATE_START ? '开启' : '关闭');

    while (Date.now() - startedAt < budgetMs) {
      await this.delay(interval);
      interval = Math.min(1200, interval + 250);
      const current = await this.readCurrentState();
      if (current === target) {
        this.busy = false;
        this.message = `${this.controlLabel()}已${target}`;
        this.finished = true;
        await this.refreshCard();
        return;
      }
    }

    // 超时：指令确实已下发成功，只是车端还没推进到终态
    this.busy = false;
    this.message = `${this.controlLabel()}指令已发送`;
    this.finished = true;
    await this.refreshCard();
  }

  /**
   * 车控完成后刷新卡片，让按钮显示回真实状态。
   */
  private async refreshCard(): Promise<void> {
    const context = this.context;
    const repository = this.repository;
    if (context === undefined || repository === undefined || this.vin.length === 0) {
      return;
    }
    try {
      const states = await repository.readAllStates();
      if (states.length === 0) {
        return;
      }
      const state = states[0];
      const snapshot = CardPublisher.snapshot(
        state.vin, state.modelName.length > 0 ? state.modelName : '极星2',
        state.battery ?? -1, state.range ?? -1,
        state.charging, state.chargerConnection, state.powerWatts ?? 0,
        state.currentAmps ?? 0, state.timeToFullMinutes ?? 0,
        state.locked, state.climate);
      await CardPublisher.publish(context, snapshot);
    } catch (err) {
      Log.warn(TAG, `车控后刷新卡片失败: ${(err as Error).message}`);
    }
  }

  /**
   * 返回上一页。
   *
   * 冷启动时本页面是栈底唯一页面，没有上一页可退 —— 直接结束应用。
   */
  private goBack(): void {
    const context = this.context;
    try {
      const index = this.getUIContext().getRouter().getState().index;
      if (index > 1) {
        this.getUIContext().getRouter().back();
        return;
      }
    } catch (err) {
      Log.warn(TAG, `读取路由栈失败: ${(err as Error).message}`);
    }
    if (context !== undefined) {
      try {
        context.terminateSelf();
      } catch (err) {
        Log.warn(TAG, `结束应用失败: ${(err as Error).message}`);
      }
    }
  }

  /**
   * 延时。
   */
  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  build() {
    Column({ space: 16 }) {
      Text(this.controlLabel())
        .fontSize(23)
        .fontWeight(FontWeight.Normal)
        .fontColor($r('app.color.app_primary_text'))
        .margin({ top: 80 })

      Text(this.message.length > 0 ? this.message : '正在准备…')
        .fontSize(13)
        .fontColor($r('app.color.app_secondary_text'))

      if (this.busy) {
        LoadingProgress()
          .width(22)
          .height(22)
          .color($r('app.color.app_accent'))
      }

      Button('返回')
        .width('100%')
        .height(48)
        .backgroundColor($r('app.color.app_surface_muted'))
        .fontColor($r('app.color.app_primary_text'))
        .onClick(() => {
          this.goBack();
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
    .backgroundColor($r('app.color.app_background'))
  }
}
