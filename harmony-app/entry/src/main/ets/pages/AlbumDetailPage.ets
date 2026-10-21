// AlbumDetailPage.ets — paged, authenticated album contents (ArkUI V2)
// Spec 4.1 & 4.2: 2-4 column pinch zoom, sorted by capture time with newest at bottom, default scroll to bottom
import { AppBridge } from '../bridge/AppBridge';
import { AssetThumbnail } from '../components/AssetThumbnail';
import { AlbumItem, AlbumAssetPage, AssetItem, SyncState } from '../models/AssetModels';

@ComponentV2
export struct AlbumDetailPage {
  @Param album: AlbumItem = new AlbumItem('', '', '', 0);
  @Event onBack: () => void = () => {};
  @Event onSelectAsset: (asset: AssetItem, allAssets?: AssetItem[]) => void = () => {};

  @Local assets: AssetItem[] = [];
  @Local isLoading: boolean = false;
  @Local loadError: string = '';
  @Local hasMore: boolean = false;
  @Local isAtBottom: boolean = true;

  // Zoom columns: 2 to 4 (Spec 4.1: albums stay 2-4 columns)
  @Local columnCount: number = 3;
  private pinchBaseColumns: number = 3;

  private pageToLoad: number = 1;
  private cursorToLoad: string | undefined = undefined;
  private isFirstLoad: boolean = true;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.loadNextPage();
  }

  // Spec 4.2: Sort by capture time chronologically, newest at bottom
  private sortAssetsChronologically(list: AssetItem[]): AssetItem[] {
    return [...list].sort((a: AssetItem, b: AssetItem) => {
      const timeA = new Date(a.fileCreatedAt).getTime();
      const timeB = new Date(b.fileCreatedAt).getTime();
      return timeA - timeB;
    });
  }

  async loadNextPage(): Promise<void> {
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    this.loadError = '';
    try {
      const result: AlbumAssetPage = await AppBridge.fetchAlbumAssetsPage(
        this.album.id, this.pageToLoad, this.cursorToLoad);
      const ids = new Set<string>(this.assets.map((asset: AssetItem) => asset.id));
      const additions: AssetItem[] = [];
      for (const asset of result.assets) {
        if (!ids.has(asset.id)) {
          ids.add(asset.id);
          additions.push(asset);
        }
      }
      this.assets = this.sortAssetsChronologically([...this.assets, ...additions]);
      this.hasMore = result.nextPage !== undefined || !!result.nextCursor;
      // Advance only after success: Retry always repeats the failed page/cursor.
      this.pageToLoad = result.nextPage ?? (this.pageToLoad + 1);
      this.cursorToLoad = result.nextCursor;

      // Spec 4.2: Default scroll to bottom to view newest photos
      if (this.isFirstLoad && this.assets.length > 0) {
        this.isFirstLoad = false;
        setTimeout(() => {
          this.scroller.scrollEdge(Edge.Bottom);
          this.isAtBottom = true;
        }, 80);
      }
    } catch (err) {
      this.loadError = err instanceof Error ? err.message : '无法加载相册照片';
      console.error('[AlbumDetailPage] Failed to load album page');
    } finally {
      this.isLoading = false;
    }
  }

  getColumnsTemplate(): string {
    return Array(this.columnCount).fill('1fr').join(' ');
  }

  handlePinchStart(): void {
    this.pinchBaseColumns = this.columnCount;
  }

  handlePinchUpdate(scale: number): void {
    if (scale > 1.25 && this.columnCount > 2) {
      this.columnCount = Math.max(2, this.columnCount - 1);
    } else if (scale < 0.75 && this.columnCount < 4) {
      this.columnCount = Math.min(4, this.columnCount + 1);
    }
  }

  getSyncBadgeText(state: SyncState): string {
    switch (state) {
      case 'LOCAL_ONLY':
        return '↑'; // Unsynced / phone only
      case 'SYNCED':
        return '✓'; // Synced on cloud and local
      case 'CLOUD_ONLY':
        return '☁'; // Cloud only
      case 'REMOTE_DELETED_LOCAL_KEPT':
        return '⊘'; // Remote deleted, local kept & auto-upload blocked
      case 'UPLOADING':
        return '⋯'; // In upload progress
      default:
        return '';
    }
  }

  getSyncBadgeBgColor(state: SyncState): string {
    switch (state) {
      case 'LOCAL_ONLY':
        return '#CC606266';
      case 'SYNCED':
        return '#CC409EFF';
      case 'CLOUD_ONLY':
        return '#CC67C23A';
      case 'REMOTE_DELETED_LOCAL_KEPT':
        return '#CCE6A23C';
      case 'UPLOADING':
        return '#CC909399';
      default:
        return '#80000000';
    }
  }

  @Builder
  pageStatus() {
    if (this.isLoading) {
      Column({ space: 8 }) {
        LoadingProgress().width(32).height(32).color('#409EFF')
        Text('正在加载照片...').fontSize(12).fontColor('#909399')
      }
      .width('100%')
      .padding(20)
    } else if (this.loadError) {
      Column({ space: 8 }) {
        Text('无法加载相册照片').fontSize(15).fontColor('#FFFFFF')
        Text(this.loadError).fontSize(12).fontColor('#F56C6C')
        Button('重试')
          .fontColor('#409EFF')
          .backgroundColor(Color.Transparent)
          .onClick(() => { this.loadNextPage(); })
      }
      .width('100%')
      .padding(20)
    } else if (this.hasMore) {
      Button('加载更多')
        .fontColor('#409EFF')
        .backgroundColor('#25272B')
        .margin({ top: 16, bottom: 16 })
        .onClick(() => { this.loadNextPage(); })
    } else if (this.assets.length === 0) {
      Column({ space: 12 }) {
        Image($r('app.media.icon_albums'))
          .width(48).height(48).fillColor('#909399')
        Text('相册为空').fontSize(15).fontColor('#A4A9B2')
      }
      .width('100%')
      .padding({ top: 48, bottom: 48 })
    }
  }

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        Row({ space: 12 }) {
          Button('返回')
            .fontSize(14)
            .fontColor('#409EFF')
            .backgroundColor(Color.Transparent)
            .padding({ left: 0, right: 8 })
            .onClick(() => { this.onBack(); })
          Column({ space: 4 }) {
            Text(this.album.name)
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`${this.album.count} 项 · 已加载 ${this.assets.length} 项 · 最新在底部`)
              .fontSize(11)
              .fontColor('#909399')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text(`${this.columnCount} 列`)
            .fontSize(11)
            .fontColor('#909399')
            .margin({ right: 4 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })

        Scroll(this.scroller) {
          Column() {
            if (this.assets.length > 0) {
              Grid() {
                ForEach(this.assets, (asset: AssetItem) => {
                  GridItem() {
                    Stack({ alignContent: Alignment.BottomEnd }) {
                      AssetThumbnail({ asset: asset })
                        .width('100%')
                        .height('100%')

                      // Bottom-Right: Sync State Badge (Spec 4.1.1)
                      Row() {
                        if (asset.syncState === 'CLOUD_ONLY') {
                          Image($r('app.media.icon_cloud'))
                            .width(10)
                            .height(10)
                            .fillColor('#FFFFFF')
                        } else {
                          Text(this.getSyncBadgeText(asset.syncState))
                            .fontSize(9)
                            .fontColor('#FFFFFF')
                            .fontWeight(FontWeight.Bold)
                        }
                      }
                      .backgroundColor(this.getSyncBadgeBgColor(asset.syncState))
                      .borderRadius(8)
                      .padding({ left: 3, right: 3, top: 1, bottom: 1 })
                      .margin({ right: 2, bottom: 2 })
                    }
                    .width('100%')
                    .aspectRatio(1)
                    .clip(true)
                    .backgroundColor('#2C2C2E')
                    .onClick(() => { this.onSelectAsset(asset, this.assets); })
                  }
                  .aspectRatio(1)
                }, (asset: AssetItem) => asset.id)
              }
              .columnsTemplate(this.getColumnsTemplate())
              .columnsGap(3)
              .rowsGap(3)
              .width('100%')
            }
            this.pageStatus()
          }
          .width('100%')
          .padding({ bottom: 24 })
        }
        .width('100%')
        .layoutWeight(1)
        .onScrollEdge((side: Edge) => {
          if (side === Edge.Bottom) {
            this.isAtBottom = true;
          }
        })
        .onScrollFrameBegin((offset: number, _state: ScrollState) => {
          if (offset < -15) {
            this.isAtBottom = false;
          }
          return { offsetRemain: offset };
        })
        .gesture(
          PinchGesture({ fingers: 2 })
            .onActionStart(() => {
              this.handlePinchStart();
            })
            .onActionUpdate((event: GestureEvent) => {
              if (event.scale) {
                this.handlePinchUpdate(event.scale);
              }
            })
        )
      }
      .width('100%')
      .height('100%')

      // "Back to Latest" Floating Button (when user scrolls away from bottom)
      if (!this.isAtBottom && this.assets.length > 0) {
        Button({ type: ButtonType.Capsule }) {
          Row({ space: 4 }) {
            Text('↓ 最新')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Medium)
          }
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        }
        .backgroundColor('#CC409EFF')
        .margin({ right: 16, bottom: 20 })
        .shadow({ radius: 8, color: '#66000000', offsetY: 4 })
        .onClick(() => {
          this.scroller.scrollEdge(Edge.Bottom);
          this.isAtBottom = true;
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#121212')
  }
}
