// ExifDrawer.ets — ArkUI V2 Media Metadata & EXIF Bottom Drawer
import { ExifInfo } from '../models/AssetModels';

@ComponentV2
export struct ExifDrawer {
  @Param isVisible: boolean = false;
  @Param exif: ExifInfo = {};

  @Event onClose: () => void = () => {};

  formatParams(): string {
    const parts: string[] = [];
    if (this.exif.focalLength) { parts.push(this.exif.focalLength); }
    if (this.exif.fNumber) { parts.push(this.exif.fNumber); }
    if (this.exif.exposureTime) { parts.push(this.exif.exposureTime); }
    if (this.exif.iso) { parts.push('ISO ' + this.exif.iso); }
    return parts.length > 0 ? parts.join(' · ') : '暂无';
  }

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
          Text('详细信息（EXIF）')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
          Blank()
          Button('关闭')
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
            Text('相机')
              .fontSize(13)
              .fontColor('#909399')
            Blank()
            Text((this.exif.cameraMake || '') + ' ' + (this.exif.cameraModel || '未知设备'))
              .fontSize(13)
              .fontColor('#E4E7ED')
          }
          .width('100%')

          if (this.exif.lensModel) {
            Row() {
              Text('镜头')
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
            Text('拍摄参数')
              .fontSize(13)
              .fontColor('#909399')
            Blank()
            Text(this.formatParams())
              .fontSize(13)
              .fontColor('#E4E7ED')
          }
          .width('100%')

          Row() {
            Text('分辨率')
              .fontSize(13)
              .fontColor('#909399')
            Blank()
            Text(this.exif.resolution || '暂无')
              .fontSize(13)
              .fontColor('#E4E7ED')
          }
          .width('100%')

          if (this.exif.dateTimeOriginal) {
            Row() {
              Text('拍摄时间')
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
