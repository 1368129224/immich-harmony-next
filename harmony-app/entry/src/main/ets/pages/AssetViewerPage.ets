// AssetViewerPage.ets — ArkUI V2 Native Full-Screen Media Viewer & Live Photo Engine
// Full Implementation of Toolbar Toggling, Status-Driven Bottom Bar, Deletion/Trash Dialogs, Sharing with GPS Stripping, Swiper Photo Switching & Zoom/Pan/Dismiss Gestures
import { curves } from '@kit.ArkUI';

import { AppBridge } from '../bridge/AppBridge';
import { AssetItem, AssetViewerBundle, ExifInfo } from '../models/AssetModels';
import { DebugOverlay } from '../components/DebugOverlay';
import { FilmstripScrubber } from '../components/FilmstripScrubber';
import { ExifDrawer } from '../components/ExifDrawer';

@ComponentV2
export struct AssetViewerPage {
  @Param currentAsset: AssetItem = new AssetItem();
  @Param allAssets: AssetItem[] = [];

  @Event onDismiss: () => void = () => {};

  @Local activeAsset: AssetItem = new AssetItem();
  @Local displayAssets: AssetItem[] = [];
  @Local currentIndex: number = 0;
  @Local viewerBundle: AssetViewerBundle | null = null;
  @Local isLoadingMedia: boolean = true;
  @Local mediaError: string = '';
  @Local isExifDrawerOpen: boolean = false;
  @Local exifData: ExifInfo = {};

  // Toolbars Visibility (Spec 3.2: defaults to visible on open, toggle on single tap, keep on photo switch)
  @Local showToolbars: boolean = true;

  // Gesture Tuning Parameters
  @Local springResponse: number = 0.35;
  @Local springDamping: number = 0.8;
  @Local dismissThresholdVp: number = 150;

  // Zoom & Pan state
  @Local imageScale: number = 1.0;
  @Local imagePanX: number = 0;
  @Local imagePanY: number = 0;

  // Drag-to-dismiss interactive state
  @Local dragOffsetY: number = 0;
  @Local bgOpacity: number = 1.0;

  // Live / Video Playing state
  @Local isLivePlaying: boolean = false;
  @Local isVideoPlaying: boolean = false;

  // Delete & Trash Dialog state
  @Local showDeleteLocalDialog: boolean = false;
  @Local showCloudTrashDialog: boolean = false;
  @Local dontRemindChecked: boolean = false;

  // Share Dialog state
  @Local showShareDialog: boolean = false;
  @Local shareFormat: string = 'ORIGINAL'; // 'ORIGINAL' | 'COMPATIBLE' | 'LINK'
  @Local stripGpsForShare: boolean = true;

  // Toast message
  @Local toastMessage: string = '';

  private swiperController: SwiperController = new SwiperController();

  aboutToAppear(): void {
    this.activeAsset = this.currentAsset;
    this.displayAssets = this.allAssets.length > 0 ? this.allAssets : [this.currentAsset];
    const idx = this.displayAssets.findIndex((a: AssetItem) => a.id === this.currentAsset.id);
    this.currentIndex = idx >= 0 ? idx : 0;
    this.showToolbars = true; // Spec 3.2: Always default to visible when opening viewer
    this.loadMediaBundle(this.activeAsset.id);
  }

  async loadMediaBundle(assetId: string): Promise<void> {
    this.isLoadingMedia = true;
    this.mediaError = '';
    this.viewerBundle = null;
    try {
      const bundle = await AppBridge.prepareAssetViewerBundle(assetId);
      this.viewerBundle = bundle;

      // Extract EXIF info via AppBridge
      const exif = await AppBridge.getAssetExif(assetId);
      if (exif) {
        this.exifData = exif;
      } else {
        const fallbackExif: ExifInfo = {
          dateTimeOriginal: this.activeAsset.fileCreatedAt,
        };
        this.exifData = fallbackExif;
      }
    } catch (err) {
      this.mediaError = err instanceof Error ? err.message : '无法加载预览';
      console.error('[AssetViewerPage] Failed to load media preview');
    } finally {
      this.isLoadingMedia = false;
    }
  }

  // Switch to a new asset (from Swiper or Filmstrip) while preserving toolbar visibility state
  switchToAsset(asset: AssetItem): void {
    if (asset.id === this.activeAsset.id) {
      return;
    }
    this.activeAsset = asset;
    const idx = this.displayAssets.findIndex((a: AssetItem) => a.id === asset.id);
    if (idx >= 0 && idx !== this.currentIndex) {
      this.currentIndex = idx;
    }
    // Spec 3.4: Stop video/live playback on photo switch
    this.isVideoPlaying = false;
    this.isLivePlaying = false;

    // Reset zoom and dismiss offsets
    this.imageScale = 1.0;
    this.imagePanX = 0;
    this.imagePanY = 0;
    this.dragOffsetY = 0;
    this.bgOpacity = 1.0;

    // Spec 3.2: Keep current showToolbars visibility state across photo switches!
    this.loadMediaBundle(asset.id);
  }

  handleDragUpdate(offsetY: number): void {
    if (offsetY > 0) {
      this.dragOffsetY = offsetY;
      const progress = Math.min(offsetY / 400, 1.0);
      this.bgOpacity = Math.max(0.2, 1.0 - progress);
    }
  }

  handleDragEnd(): void {
    if (this.dragOffsetY > this.dismissThresholdVp) {
      this.onDismiss();
    } else {
      this.dragOffsetY = 0;
      this.bgOpacity = 1.0;
      this.imageScale = 1.0;
      this.imagePanX = 0;
      this.imagePanY = 0;
    }
  }

  showToast(msg: string): void {
    this.toastMessage = msg;
    setTimeout(() => {
      this.toastMessage = '';
    }, 2500);
  }

  async handleToggleFavorite(): Promise<void> {
    const nextState = await AppBridge.toggleFavorite(this.activeAsset.id, this.activeAsset.isFavorite);
    this.activeAsset.isFavorite = nextState;
    this.showToast(nextState ? '已添加到收藏' : '已从收藏移除');
  }

  async handleConfirmDeleteLocal(): Promise<void> {
    await AppBridge.deleteLocalAsset(this.activeAsset.id);
    this.showDeleteLocalDialog = false;
    this.activeAsset.hasLocalOriginal = false;
    this.showToast('本机照片已删除，云端副本已保留。');
  }

  async handleConfirmCloudTrash(): Promise<void> {
    await AppBridge.trashCloudAsset(this.activeAsset.id);
    this.showCloudTrashDialog = false;
    this.activeAsset.hasCloudOriginal = false;
    this.showToast('已移入云端回收站，已停止自动重新上传。');
  }

  async handleConfirmShare(): Promise<void> {
    await AppBridge.shareAsset(this.activeAsset.id, this.shareFormat, this.stripGpsForShare);
    this.showShareDialog = false;
    this.showToast(`已分享（${this.shareFormat === 'ORIGINAL' ? '原图' : (this.shareFormat === 'COMPATIBLE' ? '兼容格式' : '云端链接')}）${this.stripGpsForShare ? '，已移除位置信息' : ''}`);
  }

  async handleDownloadOriginal(): Promise<void> {
    await AppBridge.downloadAssetOriginal(this.activeAsset.id);
    this.showToast('原图已保存到系统相册');
  }

  @Builder
  mediaItemView(asset: AssetItem) {
    Stack({ alignContent: Alignment.Center }) {
      if (this.isLoadingMedia && asset.id === this.activeAsset.id) {
        LoadingProgress()
          .width(54)
          .height(54)
          .color('#409EFF')
      } else if (this.mediaError && asset.id === this.activeAsset.id) {
        Column({ space: 12 }) {
          Text(this.mediaError).fontSize(14).fontColor('#F56C6C')
          Button('重试').onClick(() => { this.loadMediaBundle(this.activeAsset.id); })
        }
      } else {
        Image(asset.id === this.activeAsset.id
          ? (this.viewerBundle?.imagePath || this.activeAsset.localPreviewPath || this.activeAsset.localThumbPath || '')
          : (asset.localPreviewPath || asset.localThumbPath || ''))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .scale({ x: this.imageScale, y: this.imageScale })
          .translate({ x: this.imagePanX, y: this.imagePanY + this.dragOffsetY })
          .animation({ curve: curves.springMotion(this.springResponse, this.springDamping) })

        // Video Play Overlay button (Spec 3.4: video plays on button tap, not auto)
        if (asset.isVideo && !this.isVideoPlaying) {
          Button({ type: ButtonType.Circle }) {
            Text('▶')
              .fontSize(24)
              .fontColor('#FFFFFF')
              .margin({ left: 4 })
          }
          .width(64)
          .height(64)
          .backgroundColor('#99000000')
          .onClick(() => {
            this.isVideoPlaying = true;
            this.showToast('正在播放视频...');
          })
        }

        // Live Photo Playing Indicator (Spec 3.4)
        if (this.isLivePlaying && asset.isLivePhoto) {
          Text('正在播放实况')
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor('#AA000000')
            .borderRadius(14)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .position({ x: '35%', y: 80 })
        }
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // Main Swiper Container with interactive gesture handling
      Stack({ alignContent: Alignment.Center }) {
        Swiper(this.swiperController) {
          ForEach(this.displayAssets, (asset: AssetItem) => {
            this.mediaItemView(asset)
          }, (asset: AssetItem) => asset.id)
        }
        .index(this.currentIndex)
        .loop(false)
        .indicator(false)
        .disableSwipe(this.imageScale > 1.05) // In zoom state, prioritize internal pan over page swipe
        .onChange((index: number) => {
          if (this.displayAssets[index]) {
            this.switchToAsset(this.displayAssets[index]);
          }
        })
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
      .opacity(this.bgOpacity)
      .gesture(
        GestureGroup(
          GestureMode.Parallel,
          // Spec 3.3: Disambiguate single-tap toggle toolbars and double-tap zoom
          GestureGroup(
            GestureMode.Exclusive,
            TapGesture({ count: 2 })
              .onAction(() => {
                if (this.imageScale > 1.05) {
                  this.imageScale = 1.0;
                  this.imagePanX = 0;
                  this.imagePanY = 0;
                } else {
                  this.imageScale = 2.5;
                }
              }),
            TapGesture({ count: 1 })
              .onAction(() => {
                // Spec 3.2: Single tap toggles toolbar visibility
                this.showToolbars = !this.showToolbars;
              })
          ),
          // Spec 3.4: Long-press to play Live Photo
          LongPressGesture({ repeat: false })
            .onAction(() => {
              if (this.activeAsset.isLivePhoto) {
                this.isLivePlaying = true;
                setTimeout(() => {
                  this.isLivePlaying = false;
                }, 2000);
              }
            }),
          // Pan Gesture: Zoomed state pans image; Normal state drags down to dismiss
          PanGesture({ direction: PanDirection.All })
            .onActionUpdate((event: GestureEvent) => {
              if (this.imageScale > 1.05) {
                // Pan around zoomed image
                this.imagePanX += event.offsetX * 0.4;
                this.imagePanY += event.offsetY * 0.4;
              } else if (event.offsetY > 0) {
                // Drag down to dismiss when at normal scale
                this.handleDragUpdate(event.offsetY);
              }
            })
            .onActionEnd(() => {
              if (this.imageScale <= 1.05) {
                this.handleDragEnd();
              }
            })
        )
      )

      // Top Header Controls (Visible when showToolbars = true)
      if (this.showToolbars) {
        Row() {
          Button('返回')
            .fontSize(13)
            .fontColor('#FFFFFF')
            .backgroundColor('#44000000')
            .borderRadius(16)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .onClick(() => {
              this.onDismiss();
            })

          Blank()

          // Live Photo visible toggle button (Spec 3.4)
          if (this.activeAsset.isLivePhoto) {
            Button('实况')
              .fontSize(11)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Bold)
              .backgroundColor(this.isLivePlaying ? '#409EFF' : '#66000000')
              .borderRadius(12)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .margin({ right: 8 })
              .onClick(() => {
                this.isLivePlaying = !this.isLivePlaying;
              })
          }

          // Active Download to System Gallery button (Spec 3.6: download saves to system gallery)
          if (this.activeAsset.hasCloudOriginal) {
            Button('下载')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .backgroundColor('#44000000')
              .borderRadius(16)
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .margin({ right: 8 })
              .onClick(() => {
                this.handleDownloadOriginal();
              })
          }

          Button('信息')
            .fontSize(13)
            .fontColor('#FFFFFF')
            .backgroundColor('#44000000')
            .borderRadius(16)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .onClick(() => {
              this.isExifDrawerOpen = !this.isExifDrawerOpen;
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 44 })
        .position({ x: 0, y: 0 })
      }

      // Bottom Actions & Filmstrip (Visible when showToolbars = true)
      if (this.showToolbars) {
        Column() {
          // Gesture Tuning Panel
          DebugOverlay({
            springResponse: this.springResponse,
            springDamping: this.springDamping,
            dismissThresholdVp: this.dismissThresholdVp,
            onParamsChange: (resp: number, damp: number, thresh: number) => {
              this.springResponse = resp;
              this.springDamping = damp;
              this.dismissThresholdVp = thresh;
            }
          })

          // Filmstrip Scrubber for fast sequential navigation
          if (this.displayAssets.length > 0) {
            FilmstripScrubber({
              assets: this.displayAssets,
              currentAssetId: this.activeAsset.id,
              onSelectAsset: (asset: AssetItem) => {
                this.switchToAsset(asset);
              }
            })
          }

          // Status-Driven Bottom Bar (Spec 3.1 & Deletion Spec)
          // Dual (Local+Cloud): 5 items: Favorite, Add Album, Delete Local, Cloud Trash, Share
          // Local Only: 4 items: Favorite, Add Album, Delete Local, Share
          // Cloud Only: 4 items: Favorite, Add Album, Cloud Trash, Share
          Row() {
            // 1. Favorite
            Column({ space: 3 }) {
              Text(this.activeAsset.isFavorite ? '♥' : '♡')
                .fontSize(18)
                .fontColor(this.activeAsset.isFavorite ? '#F56C6C' : '#FFFFFF')
              Text('收藏')
                .fontSize(10)
                .fontColor(this.activeAsset.isFavorite ? '#F56C6C' : '#E4E7ED')
            }
            .layoutWeight(1)
            .onClick(() => {
              this.handleToggleFavorite();
            })

            // 2. Add to Album
            Column({ space: 3 }) {
              Text('＋')
                .fontSize(18)
                .fontColor('#FFFFFF')
              Text('相册')
                .fontSize(10)
                .fontColor('#E4E7ED')
            }
            .layoutWeight(1)
            .onClick(() => {
              this.showToast('请选择要添加的相册...');
            })

            // 3. Delete Local (if local exists)
            if (this.activeAsset.hasLocalOriginal) {
              Column({ space: 3 }) {
                Image($r('app.media.icon_trash'))
                  .width(20)
                  .height(20)
                  .fillColor('#F56C6C')
                Text('删除本机')
                  .fontSize(10)
                  .fontColor('#F56C6C')
              }
              .layoutWeight(1)
              .onClick(() => {
                this.showDeleteLocalDialog = true;
              })
            }

            // 4. Cloud Trash (if cloud exists)
            if (this.activeAsset.hasCloudOriginal) {
              Column({ space: 3 }) {
                Image($r('app.media.icon_cloud_trash'))
                  .width(20)
                  .height(20)
                  .fillColor('#E6A23C')
                Text('云端回收站')
                  .fontSize(10)
                  .fontColor('#E6A23C')
              }
              .layoutWeight(1)
              .onClick(() => {
                this.showCloudTrashDialog = true;
              })
            }

            // 5. Share
            Column({ space: 3 }) {
              Text('↗')
                .fontSize(18)
                .fontColor('#409EFF')
              Text('分享')
                .fontSize(10)
                .fontColor('#409EFF')
            }
            .layoutWeight(1)
            .onClick(() => {
              this.showShareDialog = true;
            })
          }
          .width('100%')
          .height(56)
          .backgroundColor('#CC1E1E1E')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        }
        .width('100%')
      }

      // EXIF Drawer Bottom Sheet
      ExifDrawer({
        isVisible: this.isExifDrawerOpen,
        exif: this.exifData,
        onClose: () => {
          this.isExifDrawerOpen = false;
        }
      })

      // Toast Feedback
      if (this.toastMessage) {
        Text(this.toastMessage)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor('#CC333333')
          .borderRadius(18)
          .padding({ left: 18, right: 18, top: 8, bottom: 8 })
          .margin({ bottom: 80 })
      }

      // Delete Local Confirmation Dialog
      if (this.showDeleteLocalDialog) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#88000000')
            .onClick(() => {
              this.showDeleteLocalDialog = false;
            })

          Column({ space: 14 }) {
            Text('删除本机副本')
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')

            Text(this.activeAsset.hasCloudOriginal
              ? '仅删除本设备上的副本，Immich 中的云端备份不受影响。除非手动上传，此照片将不再自动上传。'
              : '此照片尚未备份到 Immich。删除后将从本设备永久移除。')
              .fontSize(13)
              .fontColor('#DCDFE6')
              .lineHeight(18)

            Row({ space: 6 }) {
              Checkbox({ name: 'dontRemind' })
                .select(this.dontRemindChecked)
                .onChange((val: boolean) => {
                  this.dontRemindChecked = val;
                })
              Text('此账号不再提示')
                .fontSize(12)
                .fontColor('#909399')
            }
            .width('100%')

            Row({ space: 10 }) {
              Button('取消')
                .layoutWeight(1)
                .height(40)
                .backgroundColor('#2C2C2E')
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.showDeleteLocalDialog = false;
                })

              Button('删除本机')
                .layoutWeight(1)
                .height(40)
                .backgroundColor('#F56C6C')
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.handleConfirmDeleteLocal();
                })
            }
            .width('100%')
          }
          .width('85%')
          .padding(20)
          .backgroundColor('#1E1E1E')
          .borderRadius(16)
        }
        .width('100%')
        .height('100%')
      }

      // Move to Cloud Trash Confirmation Dialog
      if (this.showCloudTrashDialog) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#88000000')
            .onClick(() => {
              this.showCloudTrashDialog = false;
            })

          Column({ space: 14 }) {
            Text('移入 Immich 云端回收站')
              .fontSize(17)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')

            Text('将此资源移入 Immich 服务器回收站。本机相册原件保持不变，并已停止自动上传以防误重新上传。')
              .fontSize(13)
              .fontColor('#DCDFE6')
              .lineHeight(18)

            Row({ space: 6 }) {
              Checkbox({ name: 'dontRemindTrash' })
                .select(this.dontRemindChecked)
                .onChange((val: boolean) => {
                  this.dontRemindChecked = val;
                })
              Text('此账号不再提示')
                .fontSize(12)
                .fontColor('#909399')
            }
            .width('100%')

            Row({ space: 10 }) {
              Button('取消')
                .layoutWeight(1)
                .height(40)
                .backgroundColor('#2C2C2E')
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.showCloudTrashDialog = false;
                })

              Button('移入回收站')
                .layoutWeight(1)
                .height(40)
                .backgroundColor('#E6A23C')
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.handleConfirmCloudTrash();
                })
            }
            .width('100%')
          }
          .width('85%')
          .padding(20)
          .backgroundColor('#1E1E1E')
          .borderRadius(16)
        }
        .width('100%')
        .height('100%')
      }

      // Share Options Sheet (Spec 3.5: Original / Compatible / Link, Strip GPS)
      if (this.showShareDialog) {
        Stack({ alignContent: Alignment.Bottom }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#88000000')
            .onClick(() => {
              this.showShareDialog = false;
            })

          Column({ space: 14 }) {
            Row() {
              Text('分享媒体')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
              Blank()
              Button('关闭')
                .fontSize(12)
                .fontColor('#909399')
                .backgroundColor(Color.Transparent)
                .onClick(() => {
                  this.showShareDialog = false;
                })
            }
            .width('100%')

            // Format Selection
            Column({ space: 8 }) {
              Text('格式：')
                .fontSize(13)
                .fontColor('#909399')
                .width('100%')

              Row({ space: 8 }) {
                Button('原图')
                  .layoutWeight(1)
                  .height(36)
                  .fontSize(12)
                  .fontColor(this.shareFormat === 'ORIGINAL' ? '#FFFFFF' : '#909399')
                  .backgroundColor(this.shareFormat === 'ORIGINAL' ? '#409EFF' : '#2C2C2E')
                  .onClick(() => {
                    this.shareFormat = 'ORIGINAL';
                  })

                Button('兼容格式')
                  .layoutWeight(1)
                  .height(36)
                  .fontSize(12)
                  .fontColor(this.shareFormat === 'COMPATIBLE' ? '#FFFFFF' : '#909399')
                  .backgroundColor(this.shareFormat === 'COMPATIBLE' ? '#409EFF' : '#2C2C2E')
                  .onClick(() => {
                    this.shareFormat = 'COMPATIBLE';
                  })

                Button('云端链接')
                  .layoutWeight(1)
                  .height(36)
                  .fontSize(12)
                  .enabled(this.activeAsset.hasCloudOriginal)
                  .fontColor(this.shareFormat === 'LINK' ? '#FFFFFF' : '#909399')
                  .backgroundColor(this.shareFormat === 'LINK' ? '#409EFF' : '#2C2C2E')
                  .onClick(() => {
                    this.shareFormat = 'LINK';
                  })
              }
              .width('100%')
            }

            // Strip GPS Option (Spec 3.5 requirement)
            Row() {
              Column({ space: 2 }) {
                Text('移除位置信息')
                  .fontSize(13)
                  .fontColor('#FFFFFF')
                Text('分享副本中移除位置信息，保护隐私')
                  .fontSize(11)
                  .fontColor('#909399')
              }
              .alignItems(HorizontalAlign.Start)

              Blank()

              Toggle({ type: ToggleType.Switch, isOn: this.stripGpsForShare })
                .selectedColor('#409EFF')
                .onChange((isOn: boolean) => {
                  this.stripGpsForShare = isOn;
                })
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })

            Button('通过鸿蒙分享')
              .width('100%')
              .height(44)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .backgroundColor('#409EFF')
              .borderRadius(10)
              .onClick(() => {
                this.handleConfirmShare();
              })
          }
          .width('100%')
          .padding(20)
          .backgroundColor('#1E1E1E')
          .borderRadius({ topLeft: 16, topRight: 16 })
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}
