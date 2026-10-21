// LibraryPage.ets — ArkUI V2 Native Library View
// Structured "Photo Categories + Management Hub" as confirmed in App Interaction Spec Section 1
// Includes the Settings block: appearance (follow system / dark) and thumbnail cache management.
import { ThemeService } from '../services/ThemeService';

@ComponentV2
export struct LibraryPage {
  @Event onSelectItem: (category: string) => void = () => {};
  @Event onClearThumbnailCache: () => void = () => {};

  @Local theme: ThemeService = ThemeService.getInstance();
  @Local followSystem: boolean = true;

  aboutToAppear(): void {
    this.followSystem = this.theme.mode === 'SYSTEM';
  }

  @Builder
  buildSectionHeader(title: string) {
    Row() {
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme.textSecondary)
      Blank()
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 6 })
  }

  @Builder
  buildListItem(icon: Resource, title: string, category: string) {
    Row() {
      Image(icon)
        .width(20)
        .height(20)
        .fillColor(this.theme.iconTint)
        .margin({ right: 14 })

      Text(title)
        .fontSize(15)
        .fontColor(this.theme.textPrimary)
        .fontWeight(FontWeight.Medium)

      Blank()

      Text('›')
        .fontSize(18)
        .fontColor(this.theme.textTertiary)
    }
    .width('100%')
    .height(48)
    .padding({ left: 16, right: 16 })
    .backgroundColor(this.theme.surface)
    .onClick(() => {
      this.onSelectItem(category);
    })
  }

  private confirmClearCache(): void {
    AlertDialog.show({
      title: '清理缩略图缓存',
      message: '将删除本机已缓存的缩略图，之后浏览时会从服务器重新下载。不会影响服务器上的照片。',
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '清理',
        fontColor: '#F56C6C',
        action: () => {
          this.onClearThumbnailCache();
        }
      }
    });
  }

  build() {
    Column() {
      // Top Title
      Row() {
        Text('资料库')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme.textPrimary)
        Blank()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      Scroll() {
        Column({ space: 12 }) {
          // 1. Common / Favorites & Recent
          this.buildSectionHeader('常用')
          Column() {
            this.buildListItem($r('app.media.icon_heart'), '收藏', 'favorites')
            Divider().color(this.theme.divider).margin({ left: 48 })
            this.buildListItem($r('app.media.icon_clock'), '最近添加', 'recently_added')
          }
          .borderRadius(12)
          .clip(true)
          .width('92%')

          // 2. Media Types
          this.buildSectionHeader('媒体类型')
          Column() {
            this.buildListItem($r('app.media.icon_video'), '视频', 'videos')
            Divider().color(this.theme.divider).margin({ left: 48 })
            this.buildListItem($r('app.media.icon_live_photo'), '实况照片', 'live_photos')
          }
          .borderRadius(12)
          .clip(true)
          .width('92%')

          // 3. Management
          this.buildSectionHeader('管理')
          Column() {
            this.buildListItem($r('app.media.icon_archive'), '归档', 'archive')
            Divider().color(this.theme.divider).margin({ left: 48 })
            this.buildListItem($r('app.media.icon_cloud_trash'), '回收站（Immich 云端）', 'trash')
          }
          .borderRadius(12)
          .clip(true)
          .width('92%')

          // 4. Settings: appearance and cache
          this.buildSectionHeader('设置')
          Column() {
            Row() {
              Text('跟随系统外观')
                .fontSize(15)
                .fontColor(this.theme.textPrimary)
                .fontWeight(FontWeight.Medium)
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.followSystem })
                .selectedColor('#409EFF')
                .onChange((on: boolean) => {
                  // Turning follow-system off keeps the current appearance as the fixed choice
                  this.followSystem = on;
                  this.theme.setMode(on ? 'SYSTEM' : (this.theme.isDark ? 'DARK' : 'LIGHT'));
                })
            }
            .width('100%')
            .height(48)
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.theme.surface)
            Divider().color(this.theme.divider).margin({ left: 16 })
            Row() {
              Text('深色模式')
                .fontSize(15)
                .fontColor(this.followSystem ? this.theme.textTertiary : this.theme.textPrimary)
                .fontWeight(FontWeight.Medium)
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.theme.isDark })
                .enabled(!this.followSystem)
                .selectedColor('#409EFF')
                .onChange((on: boolean) => {
                  this.theme.setMode(on ? 'DARK' : 'LIGHT');
                })
            }
            .width('100%')
            .height(48)
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.theme.surface)
            Divider().color(this.theme.divider).margin({ left: 16 })
            Row() {
              Text('清理缩略图缓存')
                .fontSize(15)
                .fontColor(this.theme.textPrimary)
                .fontWeight(FontWeight.Medium)
              Blank()
              Text('›')
                .fontSize(18)
                .fontColor(this.theme.textTertiary)
            }
            .width('100%')
            .height(48)
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.theme.surface)
            .onClick(() => {
              this.confirmClearCache();
            })
          }
          .borderRadius(12)
          .clip(true)
          .width('92%')
        }
        .width('100%')
        .padding({ bottom: 32 })
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bg)
  }
}
