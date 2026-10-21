// SearchPage.ets — ArkUI V2 Native Search View
// Clean-Room Native Search UI with Category Badges, People & Places Discovery, and Search History

@ComponentV2
export struct SearchPage {
  @Local searchQuery: string = '';
  @Local recentSearches: string[] = ['Family', 'Tokyo Trip', 'Cat', 'Night View'];

  private presetCategories: string[] = [
    'People & Pets', 'Places', 'Live Photos', 'Videos',
    'Favorites', 'Documents', 'Food', 'Screenshots'
  ];

  build() {
    Column({ space: 16 }) {
      // Top Title
      Row() {
        Text('Search')
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

        TextInput({ text: this.searchQuery, placeholder: 'Search photos, places, people...' })
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
            Text('Categories')
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
                Text('Recent Searches')
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#E4E7ED')
                Blank()
                Button('Clear')
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
            Text('Immich Smart Search')
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor('#409EFF')
            Text('Search by facial recognition, natural language clip search (e.g. "sunset over lake"), OCR text in photos, and GPS map locations.')
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
