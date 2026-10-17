// LoginPage.ets — ArkUI V2 Clean-Room Immich Login View
import { AppBridge } from '../bridge/AppBridge';

@ComponentV2
export struct LoginPage {
  @Local serverUrl: string = 'https://immich.app';
  @Local apiKey: string = '';
  @Local isLoading: boolean = false;
  @Local errorMessage: string = '';

  @Event onLoginSuccess: () => void = () => {};

  async handleLogin(): Promise<void> {
    if (!this.serverUrl.trim()) {
      this.errorMessage = 'Please enter Immich server URL';
      return;
    }

    this.isLoading = true;
    this.errorMessage = '';

    try {
      const result = await AppBridge.loginServer(this.serverUrl.trim(), this.apiKey.trim());
      console.info('[LoginPage] Login result:', result);
      this.onLoginSuccess();
    } catch (err: unknown) {
      this.errorMessage = 'Login failed: ' + String(err);
    } finally {
      this.isLoading = false;
    }
  }

  build() {
    Column() {
      Blank()

      // Header Brand
      Column({ space: 8 }) {
        Image($r('app.media.app_icon'))
          .width(84)
          .height(84)
          .borderRadius(20)

        Text('Immich NEXT')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')

        Text('HarmonyOS Clean-Room Native Client')
          .fontSize(13)
          .fontColor('#909399')
      }
      .margin({ bottom: 40 })

      // Form Box
      Column({ space: 14 }) {
        TextInput({ text: this.serverUrl, placeholder: 'Server URL (e.g. https://photos.my-nas.com)' })
          .type(InputType.Normal)
          .placeholderColor('#606266')
          .fontColor('#FFFFFF')
          .backgroundColor('#2C2C2E')
          .borderRadius(10)
          .height(48)
          .padding({ left: 14, right: 14 })
          .onChange((val: string) => {
            this.serverUrl = val;
          })

        TextInput({ text: this.apiKey, placeholder: 'Immich API Key' })
          .type(InputType.Password)
          .placeholderColor('#606266')
          .fontColor('#FFFFFF')
          .backgroundColor('#2C2C2E')
          .borderRadius(10)
          .height(48)
          .padding({ left: 14, right: 14 })
          .onChange((val: string) => {
            this.apiKey = val;
          })

        if (this.errorMessage) {
          Text(this.errorMessage)
            .fontSize(12)
            .fontColor('#F56C6C')
            .width('100%')
        }

        Button(this.isLoading ? 'Connecting...' : 'Connect to Immich')
          .width('100%')
          .height(48)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .backgroundColor('#409EFF')
          .borderRadius(10)
          .enabled(!this.isLoading)
          .onClick(() => {
            this.handleLogin();
          })
      }
      .width('88%')

      Blank()
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#121212')
    .justifyContent(FlexAlign.Center)
  }
}
