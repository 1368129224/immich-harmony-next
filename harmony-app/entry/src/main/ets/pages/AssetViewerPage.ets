// AssetViewerPage.ets — ArkUI V2 Native Full-Screen Media Viewer & Live Photo Engine
import { fileUri } from '@kit.CoreFileKit';
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
  @Local viewerBundle: AssetViewerBundle | null = null;
  @Local isLoadingMedia: boolean = true;
  @Local isExifDrawerOpen: boolean = false;
  @Local exifData: ExifInfo = {};

  // Gesture Tuning Parameters
  @Local springResponse: number = 0.35;
  @Local springDamping: number = 0.8;
  @Local dismissThresholdVp: number = 150;

  // Drag-to-dismiss interactive state
  @Local dragOffsetY: number = 0;
  @Local bgOpacity: number = 1.0;
  @Local imageScale: number = 1.0;

  aboutToAppear(): void {
    this.activeAsset = this.currentAsset;
    this.loadMediaBundle(this.activeAsset.id);
  }

  async loadMediaBundle(assetId: string): Promise<void> {
    this.isLoadingMedia = true;
    try {
      const bundle = await AppBridge.prepareAssetViewerBundle(assetId);
      this.viewerBundle = bundle;

      // Mock or extract EXIF info
      this.exifData = {
        cameraMake: 'Sony',
        cameraModel: 'ILCE-7RM5',
        lensModel: 'FE 24-70mm F2.8 GM II',
        focalLength: '35mm',
        fNumber: 'f/2.8',
        exposureTime: '1/250s',
        iso: '100',
        dateTimeOriginal: this.activeAsset.fileCreatedAt,
        resolution: '9504 × 6336',
      };
    } catch (err) {
      console.error('[AssetViewerPage] Failed to load bundle:', err);
    } finally {
      this.isLoadingMedia = false;
    }
  }

  handleDragUpdate(offsetY: number): void {
    if (offsetY > 0) {
      this.dragOffsetY = offsetY;
      const progress = Math.min(offsetY / 400, 1.0);
      this.bgOpacity = Math.max(0.2, 1.0 - progress);
      this.imageScale = Math.max(0.7, 1.0 - progress * 0.3);
    }
  }

  handleDragEnd(): void {
    if (this.dragOffsetY > this.dismissThresholdVp) {
      // Dismiss threshold reached -> animate out
      this.onDismiss();
    } else {
      // Snap back with tuned spring animation
      animateTo({
        curve: curves.springCurve(0, 1, this.springResponse, this.springDamping)
      }, () => {
        this.dragOffsetY = 0;
        this.bgOpacity = 1.0;
        this.imageScale = 1.0;
      });
    }
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // Main Content Canvas with drag-to-dismiss gesture
      Stack({ alignContent: Alignment.Center }) {
        if (this.isLoadingMedia) {
          LoadingProgress()
            .width(54)
            .height(54)
            .color('#409EFF')
        } else if (this.viewerBundle) {
          // Standard Image or Live Photo Preview
          Image(this.viewerBundle.imagePath)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Contain)
            .scale({ x: this.imageScale, y: this.imageScale })
            .translate({ y: this.dragOffsetY })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
      .opacity(this.bgOpacity)
      .gesture(
        PanGesture({ direction: PanDirection.Vertical })
          .onActionUpdate((event: GestureEvent) => {
            this.handleDragUpdate(event.offsetY);
          })
          .onActionEnd(() => {
            this.handleDragEnd();
          })
      )

      // Top Header Controls
      Row() {
        Button('Back')
          .fontSize(14)
          .fontColor('#FFFFFF')
          .backgroundColor('#44000000')
          .borderRadius(16)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .onClick(() => {
            this.onDismiss();
          })

        Blank()

        if (this.viewerBundle?.isLivePhoto) {
          Text('LIVE PHOTO')
            .fontSize(11)
            .fontColor('#FFFFFF')
            .fontWeight(FontWeight.Bold)
            .backgroundColor('#66000000')
            .borderRadius(12)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .margin({ right: 8 })
        }

        Button('Info')
          .fontSize(14)
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

      // Bottom Filmstrip & Debug Overlay
      Column() {
        // Tuning overlay slider panel
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

        // Filmstrip Scrubber
        FilmstripScrubber({
          assets: this.allAssets,
          currentAssetId: this.activeAsset.id,
          onSelectAsset: (asset: AssetItem) => {
            this.activeAsset = asset;
            this.loadMediaBundle(asset.id);
          }
        })
      }
      .width('100%')

      // EXIF Drawer Bottom Sheet
      ExifDrawer({
        isVisible: this.isExifDrawerOpen,
        exif: this.exifData,
        onClose: () => {
          this.isExifDrawerOpen = false;
        }
      })
    }
    .width('100%')
    .height('100%')
  }
}
