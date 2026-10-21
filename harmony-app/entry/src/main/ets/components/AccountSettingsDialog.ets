// AccountSettingsDialog.ets — ArkUI V2 Multi-Account Management & Settings Modal
// Full compliance with DELETION_ACCOUNT_SHARING_SPEC Section 2 (Multi-server, Multi-account, Cache cleaning, Backup per-account)
import { AppBridge } from '../bridge/AppBridge';
import { AccountInfo, BackupConfig } from '../models/AssetModels';

@ComponentV2
export struct AccountSettingsDialog {
  @Param isVisible: boolean = false;
  @Event onClose: () => void = () => {};
  @Event onLogout: () => void = () => {};

  @Local accounts: AccountInfo[] = [];
  @Local backupConfig: BackupConfig = new BackupConfig();
  @Local toastText: string = '';
  @Local customServerUrl: string = 'https://photo.v6.sora233.eu.org:59418';
  @Local customEmail: string = '';
  @Local customPassword: string = '';
  @Local customApiKey: string = '';
  @Local useApiKeyMode: boolean = false;
  @Local isTestingConnection: boolean = false;
  @Local showCustomServerEditor: boolean = false;

  aboutToAppear(): void {
    this.refreshData();
  }

  async refreshData(): Promise<void> {
    this.accounts = await AppBridge.fetchAccounts();
    this.backupConfig = await AppBridge.fetchBackupConfig();
  }

  getCurrentAccount(): AccountInfo | null {
    return this.accounts.find(a => a.isCurrent) || (this.accounts.length > 0 ? this.accounts[0] : null);
  }

  showToast(text: string): void {
    this.toastText = text;
    setTimeout(() => {
      this.toastText = '';
    }, 2500);
  }

  async handleSwitchAccount(acc: AccountInfo): Promise<void> {
    await AppBridge.switchAccount(acc.id);
    await this.refreshData();
    this.showToast(`已切换到 ${acc.name}`);
  }

  async handleClearCache(acc: AccountInfo): Promise<void> {
    await AppBridge.clearAccountCache(acc.id);
    await this.refreshData();
    this.showToast(`已清理 ${acc.name} 的应用缓存，本机相册原件与登录凭据已保留。`);
  }

  async handleUpdateServer(): Promise<void> {
    if (!this.customServerUrl.trim()) {
      this.showToast('请输入有效的服务器地址');
      return;
    }
    this.isTestingConnection = true;
    try {
      let res = '';
      if (this.useApiKeyMode) {
        if (!this.customApiKey.trim()) {
          this.showToast('请输入 API Key');
          this.isTestingConnection = false;
          return;
        }
        res = await AppBridge.loginServer(this.customServerUrl.trim(), this.customApiKey.trim());
      } else {
        if (!this.customEmail.trim() || !this.customPassword) {
          this.showToast('请输入邮箱和密码');
          this.isTestingConnection = false;
          return;
        }
        res = await AppBridge.loginWithPassword(this.customServerUrl.trim(), this.customEmail.trim(), this.customPassword);
      }
      await this.refreshData();
      this.showToast(res || '已成功连接服务器');
      this.showCustomServerEditor = false;
    } catch (err) {
      this.showToast('连接失败：' + (err instanceof Error ? err.message : JSON.stringify(err)));
    } finally {
      this.isTestingConnection = false;
    }
  }
  async handleToggleBackup(val: boolean): Promise<void> {
    this.backupConfig.enabled = val;
    await AppBridge.updateBackupConfig(this.backupConfig);
    this.showToast(val ? '已开启自动备份（仅 Wi-Fi）' : '已暂停备份');
  }

  build() {
    if (this.isVisible) {
      Stack({ alignContent: Alignment.Bottom }) {
        // Backdrop overlay
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#88000000')
          .onClick(() => {
            this.onClose();
          })

        // Bottom Sheet Container
        Column({ space: 16 }) {
          // Sheet Drag Handle
          Row() {
            Blank()
            Row()
              .width(40)
              .height(4)
              .backgroundColor('#666666')
              .borderRadius(2)
            Blank()
          }
          .width('100%')
          .padding({ top: 8 })

          // Header
          Row() {
            Text('账号与设置')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
            Blank()
            Button('完成')
              .fontSize(13)
              .fontColor('#409EFF')
              .backgroundColor(Color.Transparent)
              .onClick(() => {
                this.onClose();
              })
          }
          .width('100%')

          Scroll() {
            Column({ space: 20 }) {
              // Current Active Account Card
              if (this.getCurrentAccount()) {
                Column({ space: 8 }) {
                  Row({ space: 12 }) {
                    Row()
                      .width(44)
                      .height(44)
                      .borderRadius(22)
                      .backgroundColor('#409EFF')

                    Column({ space: 2 }) {
                      Text(this.getCurrentAccount()?.name || '')
                        .fontSize(15)
                        .fontWeight(FontWeight.Bold)
                        .fontColor('#FFFFFF')
                      Text(this.getCurrentAccount()?.email || '')
                        .fontSize(12)
                        .fontColor('#909399')
                      Text('已连接：' + (this.getCurrentAccount()?.serverUrl || ''))
                        .fontSize(11)
                        .fontColor('#67C23A')
                    }
                    .alignItems(HorizontalAlign.Start)

                    Blank()

                    Text('当前')
                      .fontSize(11)
                      .fontColor('#67C23A')
                      .backgroundColor('#2267C23A')
                      .borderRadius(4)
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  }
                  .width('100%')

                  // Quick Server Settings Toggle
                  Row() {
                    Text(this.showCustomServerEditor ? '收起服务器配置 ▲' : '配置服务器与登录 ▼')
                      .fontSize(11)
                      .fontColor('#409EFF')
                      .onClick(() => {
                        this.showCustomServerEditor = !this.showCustomServerEditor;
                      })
                  }
                  .margin({ top: 4 })

                  if (this.showCustomServerEditor) {
                    Column({ space: 8 }) {
                      TextInput({ text: this.customServerUrl, placeholder: '服务器地址（https://...）' })
                        .fontSize(12)
                        .fontColor('#FFFFFF')
                        .backgroundColor('#1C1C1E')
                        .borderRadius(8)
                        .height(38)
                        .onChange((val: string) => {
                          this.customServerUrl = val;
                        })

                      if (!this.useApiKeyMode) {
                        TextInput({ text: this.customEmail, placeholder: '邮箱' })
                          .type(InputType.Email)
                          .fontSize(12)
                          .fontColor('#FFFFFF')
                          .backgroundColor('#1C1C1E')
                          .borderRadius(8)
                          .height(38)
                          .onChange((val: string) => {
                            this.customEmail = val;
                          })

                        TextInput({ text: this.customPassword, placeholder: '密码' })
                          .type(InputType.Password)
                          .fontSize(12)
                          .fontColor('#FFFFFF')
                          .backgroundColor('#1C1C1E')
                          .borderRadius(8)
                          .height(38)
                          .onChange((val: string) => {
                            this.customPassword = val;
                          })
                      } else {
                        TextInput({ text: this.customApiKey, placeholder: 'API Key（高级）' })
                          .type(InputType.Password)
                          .fontSize(12)
                          .fontColor('#FFFFFF')
                          .backgroundColor('#1C1C1E')
                          .borderRadius(8)
                          .height(38)
                          .onChange((val: string) => {
                            this.customApiKey = val;
                          })
                      }

                      Row() {
                        Text(this.useApiKeyMode ? '使用邮箱和密码' : '高级：使用 API Key')
                          .fontSize(11)
                          .fontColor('#409EFF')
                          .onClick(() => {
                            this.useApiKeyMode = !this.useApiKeyMode;
                          })
                      }
                      .width('100%')
                      .justifyContent(FlexAlign.End)

                      Button(this.isTestingConnection ? '连接中...' : (this.useApiKeyMode ? '使用 API Key 连接' : '登录并同步'))
                        .fontSize(12)
                        .height(36)
                        .width('100%')
                        .backgroundColor('#409EFF')
                        .borderRadius(8)
                        .enabled(!this.isTestingConnection)
                        .onClick(() => {
                          this.handleUpdateServer();
                        })
                    }
                    .margin({ top: 8 })
                    .padding(10)
                    .backgroundColor('#1E1E20')
                    .borderRadius(8)
                    .width('100%')
                  }
                }
                .width('100%')
                .padding(14)
                .backgroundColor('#252528')
                .borderRadius(12)
              }

              // Switch Accounts List
              Column({ space: 8 }) {
                Text('切换服务器 / 账号')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#909399')
                  .width('100%')

                Column() {
                  ForEach(this.accounts, (acc: AccountInfo) => {
                    Row() {
                      Column({ space: 2 }) {
                        Text(acc.name)
                          .fontSize(14)
                          .fontColor(acc.isCurrent ? '#409EFF' : '#FFFFFF')
                          .fontWeight(acc.isCurrent ? FontWeight.Bold : FontWeight.Normal)
                        Text(acc.serverUrl)
                          .fontSize(11)
                          .fontColor('#909399')
                      }
                      .alignItems(HorizontalAlign.Start)

                      Blank()

                      if (acc.isCurrent) {
                        Text('✓ 当前')
                          .fontSize(12)
                          .fontColor('#409EFF')
                          .margin({ right: 10 })
                      } else {
                        Button('切换')
                          .fontSize(11)
                          .height(28)
                          .padding({ left: 10, right: 10 })
                          .backgroundColor('#3A3A3C')
                          .fontColor('#FFFFFF')
                          .margin({ right: 8 })
                          .onClick(() => {
                            this.handleSwitchAccount(acc);
                          })
                      }

                      // Clear Cache Button for this account
                      Button('清理缓存')
                        .fontSize(11)
                        .height(28)
                        .padding({ left: 8, right: 8 })
                        .backgroundColor('#2C2C2E')
                        .fontColor('#E6A23C')
                        .onClick(() => {
                          this.handleClearCache(acc);
                        })
                    }
                    .width('100%')
                    .padding({ left: 14, right: 14, top: 10, bottom: 10 })
                  })
                }
                .backgroundColor('#252528')
                .borderRadius(12)
              }
              .width('100%')

              // Automatic Backup Section (Spec 2.1.1)
              Column({ space: 8 }) {
                Text('自动备份')
                  .fontSize(12)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#909399')
                  .width('100%')

                Column({ space: 12 }) {
                  Row() {
                    Column({ space: 2 }) {
                      Text('备份当前账号')
                        .fontSize(14)
                        .fontColor('#FFFFFF')
                      Text('仅当前账号会自动备份')
                        .fontSize(11)
                        .fontColor('#909399')
                    }
                    .alignItems(HorizontalAlign.Start)

                    Blank()

                    Toggle({ type: ToggleType.Switch, isOn: this.backupConfig.enabled })
                      .selectedColor('#409EFF')
                      .onChange((isOn: boolean) => {
                        this.handleToggleBackup(isOn);
                      })
                  }
                  .width('100%')

                  Divider().color('#333336')

                  Row() {
                    Text('仅 Wi-Fi（默认开启）')
                      .fontSize(13)
                      .fontColor('#DCDFE6')
                    Blank()
                    Toggle({ type: ToggleType.Switch, isOn: this.backupConfig.wifiOnly })
                      .selectedColor('#409EFF')
                      .onChange((isOn: boolean) => {
                        this.backupConfig.wifiOnly = isOn;
                        AppBridge.updateBackupConfig(this.backupConfig);
                      })
                  }
                  .width('100%')

                  Row() {
                    Text('需要充电（默认关闭）')
                      .fontSize(13)
                      .fontColor('#DCDFE6')
                    Blank()
                    Toggle({ type: ToggleType.Switch, isOn: this.backupConfig.requireCharging })
                      .selectedColor('#409EFF')
                      .onChange((isOn: boolean) => {
                        this.backupConfig.requireCharging = isOn;
                        AppBridge.updateBackupConfig(this.backupConfig);
                      })
                  }
                  .width('100%')
                }
                .padding(14)
                .backgroundColor('#252528')
                .borderRadius(12)
              }
              .width('100%')

              // Logout Button
              Button('退出 Immich 登录')
                .width('100%')
                .height(44)
                .fontSize(14)
                .fontColor('#F56C6C')
                .backgroundColor('#2C2C2E')
                .borderRadius(10)
                .onClick(() => {
                  this.onLogout();
                })
            }
            .width('100%')
            .padding({ bottom: 20 })
          }
          .width('100%')
          .layoutWeight(1)

          if (this.toastText) {
            Text(this.toastText)
              .fontSize(12)
              .fontColor('#FFFFFF')
              .backgroundColor('#444444')
              .borderRadius(14)
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          }
        }
        .width('100%')
        .height('75%')
        .padding({ left: 16, right: 16, bottom: 16 })
        .backgroundColor('#1C1C1E')
        .borderRadius({ topLeft: 20, topRight: 20 })
      }
      .width('100%')
      .height('100%')
    }
  }
}
