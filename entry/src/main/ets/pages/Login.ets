import { common } from '@kit.AbilityKit';
import { AuthService } from '../core/session/AuthService';
import { Log } from '../common/Log';

/**
 * 登录页。
 *
 * 对应 Android 端 MainActivity 中的登录弹窗：
 *   - 提示"中国区手机号" + "密码"
 *   - 点击后调用 AuthService.login
 */
@Entry
@Component
struct Login {
  @State phone: string = '';
  @State password: string = '';
  @State errorMessage: string = '';
  @State submitting: boolean = false;

  private context: common.UIAbilityContext | undefined = undefined;

  aboutToAppear(): void {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  /**
   * 提交登录。
   */
  private async submit(): Promise<void> {
    if (this.submitting) {
      return;
    }
    if (this.phone.length === 0 || this.password.length === 0) {
      this.errorMessage = '请输入手机号和密码';
      return;
    }
    if (this.context === undefined) {
      return;
    }

    this.submitting = true;
    this.errorMessage = '';
    try {
      await AuthService.login(this.context, this.phone, this.password);
      Log.info('登录成功');
      this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' });
    } catch (err) {
      const e = err as Error;
      this.errorMessage = e.message.length > 0 ? e.message : '账号登录失败';
      Log.error(`登录失败: ${e.message}`);
    } finally {
      this.submitting = false;
    }
  }

  build() {
    Column({ space: 20 }) {
      Text($r('app.string.login_title'))
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.app_primary_text'))
        .margin({ top: 80, bottom: 8 })

      TextInput({ placeholder: $r('app.string.login_phone_hint'), text: this.phone })
        .type(InputType.PhoneNumber)
        .maxLength(11)
        .onChange((value: string) => {
          this.phone = value;
        })
        .backgroundColor($r('app.color.app_card_background'))
        .borderRadius(8)
        .padding({ left: 16, right: 16 })

      TextInput({ placeholder: $r('app.string.login_password_hint'), text: this.password })
        .type(InputType.Password)
        .onChange((value: string) => {
          this.password = value;
        })
        .backgroundColor($r('app.color.app_card_background'))
        .borderRadius(8)
        .padding({ left: 16, right: 16 })

      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(13)
          .fontColor($r('app.color.app_health_error'))
          .width('100%')
      }

      Button(this.submitting ? $r('app.string.common_loading') : $r('app.string.login_submit'))
        .width('100%')
        .height(48)
        .backgroundColor($r('app.color.app_accent'))
        .fontColor($r('app.color.app_on_accent'))
        .enabled(!this.submitting)
        .onClick(() => {
          this.submit();
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24 })
    .backgroundColor($r('app.color.app_background'))
  }
}
