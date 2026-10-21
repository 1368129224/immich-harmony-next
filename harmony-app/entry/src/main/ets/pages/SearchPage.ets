// SearchPage.ets — ArkUI V2 Native Search View
// Clean-Room Native Search UI with Category Badges, People & Places Discovery, and Search History

@ComponentV2
export struct SearchPage {
  @Local searchQuery: string = '';
  @Local recentSearches: string[] = [];

  private presetCategories: string[] = [
    '人物与宠物', '地点', '实况照片', '视频',
    '收藏', '文档', '美食', '截图'
  ];

  build() {
    Column({ space: 16 }) {
      // Top Title
      Row() {
        Text('搜索')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
        Blank()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12 })

      // Search Bar
      Row({ space: 8 }) {
        Image($r('app.media.icon_search'))
          .width(20)
          .height(20)
          .fillColor('#909399')

        TextInput({ text: this.searchQuery, placeholder: '搜索照片、地点、人物...' })
          .type(InputType.Normal)
          .placeholderColor('#606266')
          .fontColor('#FFFFFF')
          .backgroundColor(Color.Transparent)
          .layoutWeight(1)
          .height(36)
          .onChange((val: string) => {
            this.searchQuery = val;
          })

        if (this.searchQuery.length > 0) {
          Button('✕')
            .fontSize(12)
            .fontColor('#909399')
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.searchQuery = '';
            })
        }
      }
      .width('92%')
      .height(44)
      .backgroundColor('#2C2C2E')
      .borderRadius(12)
      .padding({ left: 12, right: 12 })

      Scroll() {
        Column({ space: 22 }) {
          // Discovery & Preset Categories
          Column({ space: 10 }) {
            Text('分类')
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor('#E4E7ED')
              .width('100%')
              .padding({ left: 16, right: 16 })

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.presetCategories, (cat: string) => {
                Button(cat)
                  .fontSize(12)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#2C2C2E')
                  .borderRadius(8)
                  .height(32)
                  .padding({ left: 12, right: 12 })
                  .margin({ right: 8, bottom: 8 })
                  .onClick(() => {
                    this.searchQuery = cat;
                  })
              })
            }
            .padding({ left: 16, right: 16 })
            .width('100%')
          }
          .width('100%')

          // Search History Section
          if (this.recentSearches.length > 0) {
            Column({ space: 8 }) {
              Row() {
                Text('最近搜索')
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#E4E7ED')
                Blank()
                Button('清空')
                  .fontSize(12)
                  .fontColor('#909399')
                  .backgroundColor(Color.Transparent)
                  .onClick(() => {
                    this.recentSearches = [];
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16 })

              Column() {
                ForEach(this.recentSearches, (term: string) => {
                  Row() {
                    Image($r('app.media.icon_clock'))
                      .width(18)
                      .height(18)
                      .fillColor('#909399')
                      .margin({ right: 8 })
                    Text(term)
                      .fontSize(14)
                      .fontColor('#DCDFE6')
                    Blank()
                    Text('↗')
                      .fontSize(13)
                      .fontColor('#606266')
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                  .onClick(() => {
                    this.searchQuery = term;
                  })
                })
              }
              .width('100%')
            }
            .width('100%')
          }

          // Smart Semantic Search Tip
          Column({ space: 6 }) {
            Text('Immich 智能搜索')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#409EFF')
            Text('支持人脸识别、自然语言语义搜索（如“湖边日落”）、照片文字识别（OCR）以及 GPS 地图位置搜索。')
              .fontSize(11)
              .fontColor('#909399')
              .lineHeight(16)
          }
          .width('92%')
          .backgroundColor('#1A2A3A')
          .borderRadius(10)
          .padding(14)
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#121212')
  }
}
