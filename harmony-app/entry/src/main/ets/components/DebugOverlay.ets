// DebugOverlay.ets — ArkUI V2 On-Screen Gesture Parameter Tuner
import { curves } from '@kit.ArkUI';

@ComponentV2
export struct DebugOverlay {
  @Param springResponse: number = 0.35;
  @Param springDamping: number = 0.8;
  @Param dismissThresholdVp: number = 150;

  @Event onParamsChange: (response: number, damping: number, threshold: number) => void = () => {};

  @Local isExpanded: boolean = false;
  @Local currentResponse: number = 0.35;
  @Local currentDamping: number = 0.8;
  @Local currentThreshold: number = 150;

  aboutToAppear(): void {
    this.currentResponse = this.springResponse;
    this.currentDamping = this.springDamping;
    this.currentThreshold = this.dismissThresholdVp;
  }

  build() {
    Column() {
      // Toggle handle bar
      Row() {
        Text(this.isExpanded ? '▼ 手势调参面板' : '▲ 手势调参')
          .fontSize(12)
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Medium)
        Blank()
        Text(this.isExpanded ? '隐藏' : '显示')
          .fontSize(11)
          .fontColor('#409EFF')
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .onClick(() => {
        this.isExpanded = !this.isExpanded;
      })

      if (this.isExpanded) {
        Column({ space: 10 }) {
          // Spring Response Slider
          Column({ space: 4 }) {
            Row() {
              Text('弹簧响应：')
                .fontSize(11)
                .fontColor('#DCDFE6')
              Blank()
              Text(this.currentResponse.toFixed(2) + 's')
                .fontSize(11)
                .fontColor('#67C23A')
                .fontWeight(FontWeight.Bold)
            }
            .width('100%')

            Slider({
              value: this.currentResponse,
              min: 0.1,
              max: 1.0,
              step: 0.05,
              style: SliderStyle.OutSet
            })
              .blockColor('#409EFF')
              .trackColor('#4C4D4F')
              .selectedColor('#409EFF')
              .onChange((val: number) => {
                this.currentResponse = val;
                this.onParamsChange(this.currentResponse, this.currentDamping, this.currentThreshold);
              })
          }

          // Spring Damping Slider
          Column({ space: 4 }) {
            Row() {
              Text('弹簧阻尼：')
                .fontSize(11)
                .fontColor('#DCDFE6')
              Blank()
              Text(this.currentDamping.toFixed(2))
                .fontSize(11)
                .fontColor('#E6A23C')
                .fontWeight(FontWeight.Bold)
            }
            .width('100%')

            Slider({
              value: this.currentDamping,
              min: 0.1,
              max: 1.5,
              step: 0.05,
              style: SliderStyle.OutSet
            })
              .blockColor('#E6A23C')
              .trackColor('#4C4D4F')
              .selectedColor('#E6A23C')
              .onChange((val: number) => {
                this.currentDamping = val;
                this.onParamsChange(this.currentResponse, this.currentDamping, this.currentThreshold);
              })
          }

          // Dismiss Threshold Slider
          Column({ space: 4 }) {
            Row() {
              Text('关闭阈值：')
                .fontSize(11)
                .fontColor('#DCDFE6')
              Blank()
              Text(Math.round(this.currentThreshold) + ' vp')
                .fontSize(11)
                .fontColor('#F56C6C')
                .fontWeight(FontWeight.Bold)
            }
            .width('100%')

            Slider({
              value: this.currentThreshold,
              min: 50,
              max: 300,
              step: 10,
              style: SliderStyle.OutSet
            })
              .blockColor('#F56C6C')
              .trackColor('#4C4D4F')
              .selectedColor('#F56C6C')
              .onChange((val: number) => {
                this.currentThreshold = val;
                this.onParamsChange(this.currentResponse, this.currentDamping, this.currentThreshold);
              })
          }
        }
        .width('100%')
        .padding({ left: 12, right: 12, bottom: 12 })
      }
    }
    .width('92%')
    .backgroundColor('#CC1E1E1E')
    .borderRadius(12)
    .shadow({ radius: 8, color: '#44000000', offsetY: 4 })
    .margin({ bottom: 16 })
  }
}
