import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { CardBinding, CardData } from '../../core/vehicle/CardData';
import { WidgetStore } from '../../core/vehicle/WidgetStore';
import { Log } from '../../common/Log';

/** 本文件的日志 Tag —— 过滤日志时按它筛。 */
const TAG: string = 'CardFormAbility';

/**
 * 桌面卡片提供方。
 *
 * 卡片进程与主应用进程分离，无法共享内存态：
 *   - 主应用刷新状态后把快照写进 Preferences（WidgetStore），
 *     再调用 formProvider.updateForm 推送给卡片；
 *   - 卡片被系统拉起时（onAddForm / onUpdateForm）从 Preferences 读快照渲染。
 *
 * 【生命周期约束】FormExtensionAbility 创建后 10 秒内无操作会被清理，
 * 因此回调里不能做耗时操作 —— 这里只做 Preferences 读取与数据推送，
 * 不去打车端接口。需要实时数据时由主应用主动推送。
 */
export default class CardFormAbility extends FormExtensionAbility {
  /**
   * 卡片被添加 / 临时卡片转正式卡片。
   *
   * 同步返回上次同步的数据 —— 此时主应用可能没在运行，
   * 快照是唯一可用的数据源。
   */
  onAddForm(want: Want): formBindingData.FormBindingData {
    const snapshot = WidgetStore.loadSync(this.context);
    const display = snapshot !== undefined
      ? CardData.display(snapshot)
      : CardData.empty();
    return formBindingData.createFormBindingData(CardData.binding(display));
  }

  /**
   * 系统要求刷新卡片（定时刷新 / 定点刷新）。
   *
   * 这里读一次快照推送 —— 快照由主应用维护，卡片侧不主动查车端。
   */
  onUpdateForm(formId: string, wantParams?: Record<string, Object>): void {
    this.pushSnapshot(formId);
  }

  /**
   * 卡片被删除。
   */
  onRemoveForm(formId: string): void {
    Log.info(TAG, `卡片被移除: ${formId}`);
  }

  /**
   * 卡片收到 message 事件。
   *
   * 本卡片的控制走 router 事件跳主应用，不在这里处理事件。
   */
  onFormEvent(formId: string, message: string): void {
    Log.info(TAG, `卡片事件: ${formId} ${message}`);
  }

  /**
   * 卡片可见性变化。
   */
  onChangeFormVisibility(newStatus: Record<string, number>): void {
  }

  /**
   * 卡片状态。始终返回 READY，卡片内容由主应用推送。
   */
  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  /**
   * 读取最新快照并推送给卡片。
   *
   * @param formId 卡片 ID
   */
  private pushSnapshot(formId: string): void {
    this.loadSnapshot().then((data: CardBinding) => {
      const binding = formBindingData.createFormBindingData(data);
      return formProvider.updateForm(formId, binding);
    }).then(() => {
      Log.info(TAG, `卡片 ${formId} 已刷新`);
    }).catch((err: Error) => {
      Log.warn(TAG, `刷新卡片 ${formId} 失败: ${err.message}`);
    });
  }

  /**
   * 读取快照并转成卡片要显示的数据。
   *
   * 快照不存在时用空数据 —— 卡片显示占位符而不是崩溃。
   */
  private async loadSnapshot(): Promise<CardBinding> {
    try {
      const snapshot = await WidgetStore.load(this.context);
      if (snapshot === undefined) {
        return CardData.binding(CardData.empty());
      }
      return CardData.binding(CardData.display(snapshot));
    } catch (err) {
      Log.warn(TAG, `读取卡片快照失败: ${(err as Error).message}`);
      return CardData.binding(CardData.empty());
    }
  }
}
