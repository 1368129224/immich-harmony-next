// FilmstripScrubber.ets — ArkUI V2 Horizontal Media Filmstrip Scrubber
import { AssetItem } from '../models/AssetModels';

@ComponentV2
export struct FilmstripScrubber {
  @Param assets: AssetItem[] = [];
  @Param currentAssetId: string = '';

  @Event onSelectAsset: (asset: AssetItem) => void = () => {};

  build() {
    Scroll() {
      Row({ space: 8 }) {
        ForEach(this.assets, (item: AssetItem) => {
          Stack({ alignContent: Alignment.BottomEnd }) {
            Column()
              .width(54)
              .height(54)
              .backgroundColor('#25272B')
              .borderRadius(6)
            if (item.localThumbPath || item.localPreviewPath) {
              Image(item.localThumbPath || item.localPreviewPath)
                .width(54)
                .height(54)
                .objectFit(ImageFit.Cover)
                .borderRadius(6)
                .border({
                  width: this.currentAssetId === item.id ? 2 : 0,
                  color: '#409EFF',
                })
            }

            if (item.isLivePhoto) {
              Text('实况')
                .fontSize(8)
                .fontColor('#FFFFFF')
                .backgroundColor('#88000000')
                .borderRadius(2)
                .padding({ left: 2, right: 2 })
                .margin({ right: 2, bottom: 2 })
            } else if (item.isVideo) {
              Text('▶')
                .fontSize(8)
                .fontColor('#FFFFFF')
                .backgroundColor('#88000000')
                .borderRadius(2)
                .padding({ left: 2, right: 2 })
                .margin({ right: 2, bottom: 2 })
            }
          }
          .onClick(() => {
            this.onSelectAsset(item);
          })
        }, (item: AssetItem) => item.id)
      }
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(70)
    .backgroundColor('#80000000')
  }
}
