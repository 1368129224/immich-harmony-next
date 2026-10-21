// AlbumsPage.ets — ArkUI V2 Native Albums View
// Full Support for 2-4 Column Pinch Zoom, Pinned Grouping, Merged Local/Cloud Albums, and Alphabetical Sorting
import { AppBridge } from '../bridge/AppBridge';
import { AssetThumbnail } from '../components/AssetThumbnail';
import { AlbumItem } from '../models/AssetModels';

@ComponentV2
export struct AlbumsPage {
  @Local albums: AlbumItem[] = [];
  @Local isLoading: boolean = false;
  @Local loadError: string = '';

  // Zoom columns: 2 to 4 (Default is 2)
  @Local columnCount: number = 2;
  private pinchBaseColumns: number = 2;

  // Selected album for detail inspection
  @Local selectedAlbum: AlbumItem | null = null;

  @Event onOpenAlbum: (album: AlbumItem) => void = () => {};

  aboutToAppear(): void {
    this.loadAlbums();
  }

  async loadAlbums(): Promise<void> {
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    this.loadError = '';
    try {
      const list = await AppBridge.fetchAlbums();
      this.albums = list;
    } catch (err) {
      this.loadError = err instanceof Error ? err.message : '无法加载相册';
      console.error('[AlbumsPage] Failed to load albums');
    } finally {
      this.isLoading = false;
    }
  }

  getPinnedAlbums(): AlbumItem[] {
    return this.albums.filter(a => a.isPinned);
  }

  getUnpinnedAlbums(): AlbumItem[] {
    return this.albums
      .filter(a => !a.isPinned)
      .sort((a, b) => a.name.localeCompare(b.name));
  }

  getColumnsTemplate(): string {
    return Array(this.columnCount).fill('1fr').join(' ');
  }

  handlePinchUpdate(scale: number): void {
    // 2, 3, 4 columns
    if (scale > 1.25 && this.columnCount > 2) {
      this.columnCount--;
    } else if (scale < 0.75 && this.columnCount < 4) {
      this.columnCount++;
    }
  }

  async togglePin(album: AlbumItem): Promise<void> {
    await AppBridge.toggleAlbumPin(album.id);
    this.albums = [...this.albums];
  }

  getSourceBadge(source: string): string {
    switch (source) {
      case 'MERGED':
        return '本机 + 云端';
      case 'CLOUD':
        return '仅云端';
      case 'LOCAL':
        return '仅本机';
      default:
        return '';
    }
  }

  getSourceBadgeColor(source: string): string {
    switch (source) {
      case 'MERGED':
        return '#CC409EFF';
      case 'CLOUD':
        return '#CC67C23A';
      case 'LOCAL':
        return '#CC909399';
      default:
        return '#CC333333';
    }
  }

  @Builder
  albumCover(album: AlbumItem) {
    Stack() {
      if (album.coverAsset) {
        AssetThumbnail({ asset: album.coverAsset })
          .width('100%')
          .height('100%')
      } else if (album.coverUri) {
        Image(album.coverUri)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
      } else {
        Image($r('app.media.icon_albums'))
          .width(36)
          .height(36)
          .fillColor('#909399')
      }
    }
    .width('100%')
    .aspectRatio(1)
    .borderRadius(10)
    .clip(true)
    .backgroundColor('#2C2C2E')
  }

  build() {
    Column() {
      // Top Navigation
      Row() {
        Text('相册')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')

        Blank()

        Text(`${this.columnCount} 列`)
          .fontSize(11)
          .fontColor('#909399')
          .margin({ right: 12 })

        Button() {
          Image($r('app.media.icon_refresh'))
            .width(18)
            .height(18)
            .fillColor('#409EFF')
        }
        .height(32)
        .padding({ left: 8, right: 8 })
        .backgroundColor(Color.Transparent)
        .enabled(!this.isLoading)
        .onClick(() => { this.loadAlbums(); })

      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 8 })

      if (this.loadError) {
        Column({ space: 8 }) {
          Text('无法加载相册').fontSize(15).fontColor('#FFFFFF')
          Text(this.loadError).fontSize(12).fontColor('#F56C6C')
          Button('重试')
            .fontColor('#409EFF')
            .backgroundColor(Color.Transparent)
            .onClick(() => { this.loadAlbums(); })
        }
        .width('100%')
        .padding(16)
      }

      if (this.isLoading && this.albums.length === 0) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color('#409EFF')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (!this.isLoading && !this.loadError && this.albums.length === 0) {
        Column({ space: 12 }) {
          Image($r('app.media.icon_albums'))
            .width(48).height(48).fillColor('#909399')
          Text('暂无相册').fontSize(16).fontColor('#FFFFFF')
          Text('相册会显示在这里。').fontSize(13).fontColor('#909399')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.albums.length > 0) {
        Scroll() {
          Column({ space: 20 }) {
            // Section 1: Pinned Albums
            if (this.getPinnedAlbums().length > 0) {
              Column({ space: 10 }) {
                Row() {
                  Text('置顶相册')
                    .fontSize(15)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#E4E7ED')
                  Blank()
                }
                .width('100%')
                .padding({ left: 16, right: 16 })

                Grid() {
                  ForEach(this.getPinnedAlbums(), (album: AlbumItem) => {
                    GridItem() {
                      Column({ space: 6 }) {
                        Stack({ alignContent: Alignment.TopEnd }) {
                          this.albumCover(album)

                          // Pin Icon Badge
                          Image($r('app.media.icon_pin'))
                            .width(18)
                            .height(18)
                            .fillColor('#FFFFFF')
                            .margin({ top: 6, right: 6 })

                          // Source Badge
                          Text(this.getSourceBadge(album.source))
                            .fontSize(8)
                            .fontColor('#FFFFFF')
                            .backgroundColor(this.getSourceBadgeColor(album.source))
                            .borderRadius(3)
                            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
                            .margin({ left: 6, bottom: 6 })
                            .align(Alignment.BottomStart)
                        }

                        Text(album.name)
                          .fontSize(13)
                          .fontWeight(FontWeight.Medium)
                          .fontColor('#FFFFFF')
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })

                        Text(`${album.count} 项`)
                          .fontSize(11)
                          .fontColor('#909399')
                      }
                      .alignItems(HorizontalAlign.Start)
                      .onClick(() => {
                        this.onOpenAlbum(album);
                      })
                      .gesture(
                        LongPressGesture({ repeat: false })
                          .onAction(() => {
                            this.togglePin(album);
                          })
                      )
                    }
                  }, (album: AlbumItem) => album.id)
                }
                .columnsTemplate(this.getColumnsTemplate())
                .columnsGap(12)
                .rowsGap(12)
                .padding({ left: 16, right: 16 })
                .width('100%')
              }
              .width('100%')
            }

            // Section 2: All Albums (Alphabetical)
            Column({ space: 10 }) {
              Row() {
                Text('全部相册')
                  .fontSize(15)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#E4E7ED')
                Blank()
                Text(`${this.getUnpinnedAlbums().length} 个相册`)
                  .fontSize(12)
                  .fontColor('#909399')
              }
              .width('100%')
              .padding({ left: 16, right: 16 })

              Grid() {
                ForEach(this.getUnpinnedAlbums(), (album: AlbumItem) => {
                  GridItem() {
                    Column({ space: 6 }) {
                      Stack({ alignContent: Alignment.BottomStart }) {
                        this.albumCover(album)

                        // Source Badge (Merged / Cloud / Local)
                        Text(this.getSourceBadge(album.source))
                          .fontSize(8)
                          .fontColor('#FFFFFF')
                          .backgroundColor(this.getSourceBadgeColor(album.source))
                          .borderRadius(3)
                          .padding({ left: 4, right: 4, top: 2, bottom: 2 })
                          .margin({ left: 6, bottom: 6 })
                      }

                      Text(album.name)
                        .fontSize(13)
                        .fontWeight(FontWeight.Medium)
                        .fontColor('#FFFFFF')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })

                      Text(`${album.count} 项`)
                        .fontSize(11)
                        .fontColor('#909399')
                    }
                    .alignItems(HorizontalAlign.Start)
                    .onClick(() => {
                      this.onOpenAlbum(album);
                    })
                    .gesture(
                      LongPressGesture({ repeat: false })
                        .onAction(() => {
                          this.togglePin(album);
                        })
                    )
                  }
                }, (album: AlbumItem) => album.id)
              }
              .columnsTemplate(this.getColumnsTemplate())
              .columnsGap(12)
              .rowsGap(12)
              .padding({ left: 16, right: 16 })
              .width('100%')
            }
            .width('100%')
          }
          .padding({ bottom: 24 })
        }
        .width('100%')
        .layoutWeight(1)
        .gesture(
          PinchGesture({ fingers: 2 })
            .onActionUpdate((event: GestureEvent) => {
              if (event.scale) {
                this.handlePinchUpdate(event.scale);
              }
            })
        )
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#121212')
  }
}
