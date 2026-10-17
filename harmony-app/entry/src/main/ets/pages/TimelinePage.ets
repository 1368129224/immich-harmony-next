// TimelinePage.ets — ArkUI V2 Native Timeline View
import { AppBridge } from '../bridge/AppBridge';
import { AssetItem, TimeBucketItem } from '../models/AssetModels';

@ComponentV2
export struct TimelinePage {
  @Local buckets: TimeBucketItem[] = [];
  @Local isLoading: boolean = false;

  @Event onSelectAsset: (asset: AssetItem) => void = () => {};

  aboutToAppear(): void {
    this.loadTimeline();
  }

  async loadTimeline(): Promise<void> {
    this.isLoading = true;
    try {
      const bucketList = await AppBridge.syncAndGetBuckets();
      this.buckets = bucketList;

      // Load assets for initial visible buckets
      for (const bucket of this.buckets) {
        const assets = await AppBridge.fetchBucketAssets(bucket.timeBucket);
        bucket.assets = assets;
        bucket.isLoaded = true;
      }
    } catch (err) {
      console.error('[TimelinePage] Failed to load timeline:', err);
    } finally {
      this.isLoading = false;
    }
  }

  formatBucketTitle(timeBucket: string): string {
    const d = new Date(timeBucket);
    if (isNaN(d.getTime())) {
      return timeBucket;
    }
    const months = ['January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'];
    return `${months[d.getUTCMonth()]} ${d.getUTCFullYear()}`;
  }

  build() {
    Column() {
      // Top Navigation Bar
      Row() {
        Text('Photos')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Blank()
        Button('Refresh')
          .fontSize(12)
          .fontColor('#409EFF')
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.loadTimeline();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })

      if (this.isLoading && this.buckets.length === 0) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color('#409EFF')
          Text('Syncing Immich timeline...')
            .fontSize(13)
            .fontColor('#909399')
            .margin({ top: 12 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 16 }) {
          ForEach(this.buckets, (bucket: TimeBucketItem) => {
            ListItem() {
              Column({ space: 8 }) {
                // Bucket Header
                Row() {
                  Text(this.formatBucketTitle(bucket.timeBucket))
                    .fontSize(16)
                    .fontWeight(FontWeight.SemiBold)
                    .fontColor('#E4E7ED')
                  Blank()
                  Text(`${bucket.count} items`)
                    .fontSize(12)
                    .fontColor('#909399')
                }
                .width('100%')
                .padding({ left: 16, right: 16 })

                // Asset Grid (4 columns)
                Grid() {
                  ForEach(bucket.assets, (asset: AssetItem) => {
                    GridItem() {
                      Stack({ alignContent: Alignment.TopEnd }) {
                        Image(asset.localThumbPath || $r('app.media.app_icon'))
                          .width('100%')
                          .height('100%')
                          .objectFit(ImageFit.Cover)

                        // Live Photo / Video Badge
                        if (asset.isLivePhoto) {
                          Text('LIVE')
                            .fontSize(9)
                            .fontColor('#FFFFFF')
                            .backgroundColor('#99000000')
                            .borderRadius(3)
                            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                            .margin({ top: 4, right: 4 })
                        } else if (asset.isVideo) {
                          Text('▶')
                            .fontSize(9)
                            .fontColor('#FFFFFF')
                            .backgroundColor('#99000000')
                            .borderRadius(3)
                            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
                            .margin({ top: 4, right: 4 })
                        }

                        // Favorite indicator
                        if (asset.isFavorite) {
                          Text('♥')
                            .fontSize(11)
                            .fontColor('#F56C6C')
                            .margin({ bottom: 4, left: 4 })
                        }
                      }
                      .width('100%')
                      .aspectRatio(1)
                      .backgroundColor('#2C2C2E')
                      .onClick(() => {
                        this.onSelectAsset(asset);
                      })
                    }
                  }, (asset: AssetItem) => asset.id)
                }
                .columnsTemplate('1fr 1fr 1fr 1fr')
                .columnsGap(2)
                .rowsGap(2)
                .width('100%')
              }
              .width('100%')
            }
          }, (bucket: TimeBucketItem) => bucket.timeBucket)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#121212')
  }
}
