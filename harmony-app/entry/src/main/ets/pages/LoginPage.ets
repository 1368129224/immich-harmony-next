// LoginPage.ets — ArkUI V2 Clean-Room Immich Login View
// Fully compliant with APP_INTERACTION_SPEC Section 5.1 & DELETION_ACCOUNT_SHARING_SPEC Section 2:
// Primary authentication: Email + Password; Advanced options: API Key.
import { AppBridge } from '../bridge/AppBridge';

@ComponentV2
export struct LoginPage {
  @Local serverUrl: string = 'https://photo.v6.sora233.eu.org:59418';
  @Local email: string = '';
  @Local password: string = '';
  @Local apiKey: string = '';
  @Local showAdvancedApiKey: boolean = false;
  @Local isLoading: boolean = false;
  @Local errorMessage: string = '';

  @Event onLoginSuccess: () => void = () => {};

  async handleLogin(): Promise<void> {
    if (!this.serverUrl.trim()) {
      this.errorMessage = 'Please enter Immich server URL';
      return;
    }

    if (this.isLoading) {
      return;
    }
    if (this.showAdvancedApiKey && !this.apiKey.trim()) {
      this.errorMessage = 'Please enter an API Key';
      return;
    }
    this.isLoading = true;
    this.errorMessage = '';

    try {
      if (this.showAdvancedApiKey) {
        // Advanced: Login via API Key
        const result = await AppBridge.loginServer(this.serverUrl.trim(), this.apiKey.trim());
        console.info('[LoginPage] API Key login result:', result);
      } else {
        // Standard: Login via Email + Password
        if (!this.email.trim() || !this.password) {
          this.errorMessage = 'Please enter both Email and Password';
          this.isLoading = false;
          return;
        }
        const result = await AppBridge.loginWithPassword(this.serverUrl.trim(), this.email.trim(), this.password);
        console.info('[LoginPage] Password login result:', result);
      }
      this.password = '';
      this.apiKey = '';
      this.onLoginSuccess();
    } catch (err) {
      this.errorMessage = 'Login failed: ' + (err instanceof Error ? err.message : JSON.stringify(err));
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
          .width(76)
          .height(76)
          .borderRadius(18)

        Text('Immich NEXT')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')

        Text('HarmonyOS Clean-Room Native Client')
          .fontSize(12)
          .fontColor('#909399')
      }
      .margin({ bottom: 28 })

      // Form Box
      Column({ space: 12 }) {
        // Server URL
        Column({ space: 4 }) {
          Text('SERVER URL')
            .fontSize(11)
            .fontWeight(FontWeight.Bold)
            .fontColor('#909399')
            .width('100%')

          TextInput({ text: this.serverUrl, placeholder: 'https://photos.your-domain.com' })
            .type(InputType.Normal)
            .placeholderColor('#606266')
            .fontColor('#FFFFFF')
            .backgroundColor('#2C2C2E')
            .borderRadius(10)
            .height(46)
            .padding({ left: 14, right: 14 })
            .onChange((val: string) => {
              this.serverUrl = val;
            })
        }
        .width('100%')

        if (!this.showAdvancedApiKey) {
          // Primary Login: Email + Password
          Column({ space: 4 }) {
            Text('EMAIL')
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor('#909399')
              .width('100%')

            TextInput({ text: this.email, placeholder: 'name@example.com' })
              .type(InputType.Email)
              .placeholderColor('#606266')
              .fontColor('#FFFFFF')
              .backgroundColor('#2C2C2E')
              .borderRadius(10)
              .height(46)
              .padding({ left: 14, right: 14 })
              .onChange((val: string) => {
                this.email = val;
              })
          }
          .width('100%')

          Column({ space: 4 }) {
            Text('PASSWORD')
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor('#909399')
              .width('100%')

            TextInput({ text: this.password, placeholder: 'Enter password' })
              .type(InputType.Password)
              .placeholderColor('#606266')
              .fontColor('#FFFFFF')
              .backgroundColor('#2C2C2E')
              .borderRadius(10)
              .height(46)
              .padding({ left: 14, right: 14 })
              .onChange((val: string) => {
                this.password = val;
              })
          }
          .width('100%')
        } else {
          // Advanced: API Key
          Column({ space: 4 }) {
            Text('API KEY (ADVANCED)')
              .fontSize(11)
              .fontWeight(FontWeight.Bold)
              .fontColor('#909399')
              .width('100%')

            TextInput({ text: this.apiKey, placeholder: 'Immich API Key' })
              .type(InputType.Password)
              .placeholderColor('#606266')
              .fontColor('#FFFFFF')
              .backgroundColor('#2C2C2E')
              .borderRadius(10)
              .height(46)
              .padding({ left: 14, right: 14 })
              .onChange((val: string) => {
                this.apiKey = val;
              })
          }
          .width('100%')
        }

        // Advanced Switcher Link
        Row() {
          Button(this.showAdvancedApiKey ? 'Switch to Email & Password login' : 'Advanced: Login with API Key')
            .fontSize(12)
            .fontColor('#409EFF')
            .backgroundColor(Color.Transparent)
            .enabled(!this.isLoading)
            .onClick(() => {
              this.password = '';
              this.apiKey = '';
              this.showAdvancedApiKey = !this.showAdvancedApiKey;
              this.errorMessage = '';
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .margin({ top: 4, bottom: 6 })

        if (this.errorMessage) {
          Text(this.errorMessage)
            .fontSize(12)
            .fontColor('#F56C6C')
            .width('100%')
        }

        Button(this.isLoading ? 'Connecting...' : (this.showAdvancedApiKey ? 'Connect with API Key' : 'Log In'))
          .width('100%')
          .height(46)
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
