// ExifDrawer.ets — ArkUI V2 Media Metadata & EXIF Bottom Drawer
import { ExifInfo } from '../models/AssetModels';

@ComponentV2
export struct ExifDrawer {
  @Param isVisible: boolean = false;
  @Param exif: ExifInfo = {};

  @Event onClose: () => void = () => {};

  build() {
    if (this.isVisible) {
      Column({ space: 14 }) {
        // Drag indicator handle
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
        .onClick(() => {
          this.onClose();
        })

        // Header
        Row() {
          Text('Details & EXIF')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
          Blank()
          Button('Close')
            .fontSize(12)
            .fontColor('#409EFF')
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.onClose();
            })
        }
        .width('100%')

        Divider().color('#333333')

        // Camera & Lens Details
        Column({ space: 8 }) {
          Row() {
            Text('Camera')
              .fontSize(13)
              .fontColor('#909399')
            Blank()
            Text((this.exif.cameraMake || '') + ' ' + (this.exif.cameraModel || 'Unknown Device'))
              .fontSize(13)
              .fontColor('#E4E7ED')
          }
          .width('100%')

          if (this.exif.lensModel) {
            Row() {
              Text('Lens')
                .fontSize(13)
                .fontColor('#909399')
              Blank()
              Text(this.exif.lensModel)
                .fontSize(13)
                .fontColor('#E4E7ED')
            }
            .width('100%')
          }

          Row() {
            Text('Parameters')
              .fontSize(13)
              .fontColor('#909399')
            Blank()
            Text(`${this.exif.focalLength || '24mm'} · ${this.exif.fNumber || 'f/1.8'} · ${this.exif.exposureTime || '1/120s'} · ISO ${this.exif.iso || '100'}`)
              .fontSize(13)
              .fontColor('#E4E7ED')
          }
          .width('100%')

          Row() {
            Text('Resolution')
              .fontSize(13)
              .fontColor('#909399')
            Blank()
            Text(this.exif.resolution || '4032 × 3024')
              .fontSize(13)
              .fontColor('#E4E7ED')
          }
          .width('100%')

          if (this.exif.dateTimeOriginal) {
            Row() {
              Text('Taken At')
                .fontSize(13)
                .fontColor('#909399')
              Blank()
              Text(this.exif.dateTimeOriginal)
                .fontSize(13)
                .fontColor('#E4E7ED')
            }
            .width('100%')
          }
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 24, top: 4 })
      .backgroundColor('#1E1E1E')
      .borderRadius({ topLeft: 16, topRight: 16 })
      .shadow({ radius: 16, color: '#66000000', offsetY: -4 })
    }
  }
}
