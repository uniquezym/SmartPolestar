import { common } from '@kit.AbilityKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { WidgetSnapshot, WidgetStore } from './WidgetStore';
import { CardData } from './CardData';
import { Log } from '../../common/Log';

/**
 * 卡片数据推送器。
 *
 * 主应用刷新状态后调用 publish()：
 *   1. 把状态快照写进 Preferences（卡片进程靠它读取）
 *   2. 调 formProvider.updateForm 把显示数据推给所有已添加的卡片
 *   3. 设置下次自动刷新时间 —— 常态 30 分钟，充电中 5 分钟
 *
 * 卡片侧不主动打车端接口：FormExtensionAbility 生命周期只有 10 秒，
 * 做不了「读会话 → 服务发现 → 拉状态 → 渲染」这条链路。
 */
export class CardPublisher {
  /**
   * 推送一次状态到卡片。
   *
   * @param context  主应用上下文
   * @param snapshot 状态快照
   */
  static async publish(context: common.UIAbilityContext, snapshot: WidgetSnapshot): Promise<void> {
    // 1. 落盘 —— 卡片被拉起时靠它渲染
    await WidgetStore.save(context, snapshot);

    // 2. 推送给已添加的卡片
    let formIds: string[] = [];
    try {
      const running = await formProvider.getPublishedRunningFormInfos();
      formIds = running.map((info) => info.formId);
    } catch (err) {
      Log.warn(`获取已添加卡片失败: ${(err as Error).message}`);
      return;
    }
    if (formIds.length === 0) {
      return;
    }

    const data = CardData.binding(CardData.display(snapshot));
    const binding = formBindingData.createFormBindingData(data);

    for (const formId of formIds) {
      try {
        await formProvider.updateForm(formId, binding);
        await formProvider.setFormNextRefreshTime(formId, CardPublisher.refreshMinutes(snapshot));
      } catch (err) {
        Log.warn(`推送卡片 ${formId} 失败: ${(err as Error).message}`);
      }
    }
    Log.info(`已推送 ${formIds.length} 张卡片`);
  }

  /**
   * 卡片下次自动刷新的间隔（分钟）。
   *
   * 充电中电量还在变，5 分钟一次；其余情况 30 分钟一次。
   */
  private static refreshMinutes(snapshot: WidgetSnapshot): number {
    if (snapshot.charging === '充电中' || snapshot.charging === '智能充电' ||
      snapshot.charging === '智能充电暂停') {
      return WidgetStore.REFRESH_MINUTES_CHARGING;
    }
    return WidgetStore.REFRESH_MINUTES;
  }

  /**
   * 由车辆状态生成卡片快照。
   *
   * @param vin       车辆 VIN
   * @param modelName 车型名
   * @param battery   电量百分比
   * @param range     预计续航（公里）
   * @param charging  充电状态文案
   * @param charger   充电枪连接状态文案
   * @param powerWatts 充电功率（瓦）
   * @param currentAmps 充电电流（安）
   * @param remainingMinutes 充满剩余时长（分钟）
   * @param locked    车锁状态文案
   * @param climate   驻车空调状态文案
   */
  static snapshot(vin: string, modelName: string, battery: number, range: number,
    charging: string, charger: string, powerWatts: number, currentAmps: number,
    remainingMinutes: number, locked: string, climate: string): WidgetSnapshot {
    return {
      vin: vin,
      modelName: modelName,
      battery: battery,
      range: range,
      charging: charging,
      chargerConnection: charger,
      powerWatts: powerWatts,
      currentAmps: currentAmps,
      remainingMinutes: remainingMinutes,
      locked: locked,
      climate: climate,
      updatedAt: Date.now()
    };
  }
}
