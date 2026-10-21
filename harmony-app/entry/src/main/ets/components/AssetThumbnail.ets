import { AssetItem } from '../models/AssetModels';
import { ImmichApiService } from '../services/ImmichApiService';

// Network images are authenticated and cached privately, never token-bearing URLs.
@ComponentV2
export struct AssetThumbnail {
  @Param asset: AssetItem = new AssetItem({ id: '', assetType: 'IMAGE', fileCreatedAt: '', isFavorite: false });
  @Local source: string | Resource = '';
  @Local failed: boolean = false;
  @Local errorText: string = '';
  private loading: boolean = false;
  private isVisible: boolean = false;

  aboutToAppear(): void {
    if (this.asset.localThumbPath) {
      this.source = this.asset.localThumbPath;
    }
  }

  @Monitor('asset.id')
  onAssetIdChanged(): void {
    this.source = this.asset.localThumbPath || '';
    if (this.isVisible && !this.source) {
      this.load();
    }
  }

  async load(): Promise<void> {
    if (this.loading || !this.asset.id) {
      return;
    }
    this.failed = false;
    if (this.asset.localThumbPath) {
      this.source = this.asset.localThumbPath;
      return;
    }
    this.loading = true;
    try {
      this.source = await ImmichApiService.getInstance().cacheAssetImage(this.asset.id);
      this.asset.localThumbPath = this.source;
    } catch (error) {
      this.errorText = error instanceof Error ? error.message : 'Image unavailable';
      this.failed = true;
    } finally {
      this.loading = false;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.source) {
        Image(this.source)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .align(Alignment.Center)
          .autoResize(true)
      } else if (this.failed) {
        Column({ space: 4 }) {
          Text(this.errorText).fontSize(8).fontColor('#A4A9B2').maxLines(2)
          Text('Retry').fontSize(10).fontColor('#409EFF')
        }
        .onClick(() => { this.load(); })
      } else {
        LoadingProgress().width(18).height(18).color('#606266')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#25272B')
    .aspectRatio(1)
    .clip(true)
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, _currentRatio: number) => {
      this.isVisible = isVisible;
      if (isVisible) {
        if (this.asset.localThumbPath) {
          this.source = this.asset.localThumbPath;
        } else if (!this.source && !this.loading) {
          this.load();
        }
      }
    })
  }
}
