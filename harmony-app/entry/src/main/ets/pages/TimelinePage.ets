// TimelinePage.ets — ArkUI V2 Native Timeline View
// Full Support for 2-15 Column Pinch Zoom, Continuous Multi-Selection, Sync State Badges, Source Filtering & Batch Action Bar
import { curves } from '@kit.ArkUI';
import { AppBridge } from '../bridge/AppBridge';
import { AssetThumbnail } from '../components/AssetThumbnail';
import { AlbumItem, AssetItem, SyncState, TimeBucketItem } from '../models/AssetModels';
import { ThemeService } from '../services/ThemeService';

export type SourceFilterType = 'ALL' | 'CLOUD' | 'LOCAL';

enum GestureLockMode {
  NONE,
  UNDECIDED,
  SCROLL,
  DRAG_SELECTION
}

interface RectBounds {
  x: number;
  y: number;
  w: number;
  h: number;
}

@ComponentV2
export struct TimelinePage {
  @Local buckets: TimeBucketItem[] = [];
  @Local isLoading: boolean = false;
  @Local loadError: string = '';
  @Local toastText: string = '';

  // Filter: All / Cloud / Local (Spec 2.1)
  @Local currentFilter: SourceFilterType = 'ALL';

  // Grid Zoom: 2 to 15 columns (Default is 4)
  @Local columnCount: number = 4;
  private pinchBaseColumnCount: number = 4;
  private lastPinchApplyTime: number = 0;
  private pendingColumnCount: number = 4;
  private static readonly PINCH_APPLY_INTERVAL_MS: number = 150;

  // Selection Mode (Spec 2.2 & 2.3)
  @Local isSelectionMode: boolean = false;
  @Local selectedAssetIds: Set<string> = new Set<string>();
  @Local isAtBottom: boolean = true;

  // Album Picker modal for "Add to Album" action
  @Local isAlbumPickerOpen: boolean = false;
  @Local availableAlbums: AlbumItem[] = [];

  // Flat asset cache for sequential range selection
  private allVisibleAssets: AssetItem[] = [];
  private dragStartIndex: number = -1;
  private preDragSelection: Set<string> = new Set<string>();

  // Touch gesture state machine for continuous range drag selection
  private gestureLockMode: GestureLockMode = GestureLockMode.NONE;
  private touchStartWinX: number = 0;
  private touchStartWinY: number = 0;
  private pendingStartIndex: number = -1;
  private itemBounds: Map<string, RectBounds> = new Map<string, RectBounds>();

  private listScroller: Scroller = new Scroller();

  @Event onSelectAsset: (asset: AssetItem, allAssets?: AssetItem[]) => void = () => {};
  @Event onOpenSettings: () => void = () => {};

  @Param scrollToLatestTrigger: number = 0;
  @Param mediaVersion: number = 0;
  @Local theme: ThemeService = ThemeService.getInstance();
  // Changes the grid item identity so every thumbnail is rebuilt after a cache clear
  @Local thumbEpoch: number = 0;
  private isLoadingOlder: boolean = false;
  private oldestLoadedBucketIdx: number = 0;
  // While true, older-history loading is suppressed so prepending does not shift the bottom-anchored view
  private coldStartAnchoring: boolean = false;
  private bottomAnchorToken: number = 0;

  @Monitor('scrollToLatestTrigger')
  onScrollToLatestTriggerChanged(): void {
    if (this.scrollToLatestTrigger > 0) {
      this.scrollToLatest();
    }
  }

  @Monitor('mediaVersion')
  onMediaVersionChanged(): void {
    // Thumbnail cache was cleared: drop cached paths so each visible cell re-downloads from the server
    for (const bucket of this.buckets) {
      for (const asset of bucket.assets) {
        asset.localThumbPath = undefined;
      }
    }
    this.thumbEpoch++;
  }

  aboutToAppear(): void {
    this.loadTimeline();
  }

  showToast(text: string): void {
    this.toastText = text;
    setTimeout(() => {
      this.toastText = '';
    }, 2500);
  }

  /**
   * Cold start: Load the newest bucket(s) first and scroll immediately to the bottom (Spec 2.4)
   */
  async loadTimeline(): Promise<void> {
    if (this.isLoading) {
      return;
    }
    this.isLoading = true;
    this.loadError = '';
    try {
      const bucketList = await AppBridge.syncAndGetBuckets();

      if (bucketList.length === 0) {
        this.buckets = bucketList;
        this.updateFlattenedAssets();
        return;
      }

      // Spec 2.4: Cold start loads the newest section first and scrolls directly to bottom
      // Fill the newest assets BEFORE publishing the array, so the List is created with real content
      const newestIdx = bucketList.length - 1;
      const initialBatchStart = Math.max(0, newestIdx - 1); // Load last 1-2 newest buckets first
      for (let i = newestIdx; i >= initialBatchStart; i--) {
        const bucket = bucketList[i];
        if (!bucket.isLoaded) {
          bucket.assets = await AppBridge.fetchBucketAssets(bucket.timeBucket);
          bucket.isLoaded = true;
        }
      }
      this.oldestLoadedBucketIdx = initialBatchStart;
      this.buckets = bucketList;
      this.updateFlattenedAssets();

      // Position at the newest photos once the List has laid out the content
      this.anchorToBottom();
    } catch (err) {
      this.loadError = err instanceof Error ? err.message : 'Unable to load server photos';
      console.error('[TimelinePage] Failed to load timeline: ' + this.loadError);
    } finally {
      this.isLoading = false;
    }
  }

  /**
   * On-demand progressive loading for older history as user scrolls up
   */
  async loadOlderBuckets(): Promise<void> {
    if (this.coldStartAnchoring || this.isLoadingOlder || this.oldestLoadedBucketIdx <= 0 || this.buckets.length === 0) {
      return;
    }
    this.isLoadingOlder = true;
    try {
      const targetStart = Math.max(0, this.oldestLoadedBucketIdx - 2);
      let changed = false;
      for (let i = this.oldestLoadedBucketIdx - 1; i >= targetStart; i--) {
        const bucket = this.buckets[i];
        if (!bucket.isLoaded) {
          bucket.assets = await AppBridge.fetchBucketAssets(bucket.timeBucket);
          bucket.isLoaded = true;
          changed = true;
        }
      }
      this.oldestLoadedBucketIdx = targetStart;
      if (changed) {
        this.updateFlattenedAssets();
      }
    } catch (err) {
      console.warn('[TimelinePage] Failed to load older buckets: ' + err);
    } finally {
      this.isLoadingOlder = false;
    }
  }

  public scrollToLatest(): void {
    this.anchorToBottom();
  }

  /**
   * Scrolls to the bottom and keeps re-applying it until the List has laid out its rows and the
   * offset stays at the end. One scrollEdge() right after data arrives runs before the rows exist.
   */
  private anchorToBottom(): void {
    const token = ++this.bottomAnchorToken;
    this.coldStartAnchoring = true;
    let attempts = 0;
    let stableHits = 0;
    const step = (): void => {
      if (token !== this.bottomAnchorToken) {
        return; // superseded by a newer anchor, or cancelled by a user touch
      }
      this.listScroller.scrollEdge(Edge.Bottom);
      this.isAtBottom = true;
      attempts++;
      stableHits = this.listScroller.isAtEnd() ? stableHits + 1 : 0;
      if ((stableHits >= 3 && attempts >= 4) || attempts >= 20) {
        this.coldStartAnchoring = false;
        return;
      }
      setTimeout(step, 60);
    };
    step();
  }

  private cancelBottomAnchor(): void {
    this.bottomAnchorToken++;
    this.coldStartAnchoring = false;
  }

  private updateFlattenedAssets(): void {
    const list: AssetItem[] = [];
    for (const b of this.buckets) {
      for (const a of b.assets) {
        if (this.filterAsset(a)) {
          list.push(a);
        }
      }
    }
    this.allVisibleAssets = list;
  }

  /**
   * Spec 2.1: Source Filter logic (All / Cloud / Local)
   */
  filterAsset(asset: AssetItem): boolean {
    if (this.currentFilter === 'ALL') {
      return true;
    }
    if (this.currentFilter === 'CLOUD') {
      return asset.hasCloudOriginal || asset.syncState === 'CLOUD_ONLY' || asset.syncState === 'SYNCED';
    }
    if (this.currentFilter === 'LOCAL') {
      return asset.hasLocalOriginal || asset.syncState === 'LOCAL_ONLY' || asset.syncState === 'SYNCED' || asset.syncState === 'REMOTE_DELETED_LOCAL_KEPT';
    }
    return true;
  }

  getFilteredBucketAssets(bucket: TimeBucketItem): AssetItem[] {
    return bucket.assets.filter((a: AssetItem) => this.filterAsset(a));
  }

  hasAnyVisibleAssets(): boolean {
    return this.allVisibleAssets.length > 0;
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

  getColumnsTemplate(): string {
    return Array(this.columnCount).fill('1fr').join(' ');
  }

  // --- Pinch-to-zoom (2 to 15 columns) ---
  handlePinchStart(): void {
    if (this.isSelectionMode) {
      return; // Density locked during multi-selection
    }
    this.pinchBaseColumnCount = this.columnCount;
    this.pendingColumnCount = this.columnCount;
  }

  handlePinchUpdate(scale: number): void {
    if (this.isSelectionMode) {
      return; // Density locked during multi-selection
    }
    const target = Math.round(this.pinchBaseColumnCount / Math.max(0.1, scale));
    const clamped = Math.max(2, Math.min(15, target));
    this.pendingColumnCount = clamped;
    if (clamped === this.columnCount) {
      return;
    }
    // Throttle relayouts: each column change rebuilds the whole grid, so apply at most every 150ms
    const now = Date.now();
    if (now - this.lastPinchApplyTime < TimelinePage.PINCH_APPLY_INTERVAL_MS) {
      return;
    }
    this.lastPinchApplyTime = now;
    this.columnCount = clamped;
  }

  handlePinchEnd(): void {
    if (this.isSelectionMode) {
      return;
    }
    if (this.pendingColumnCount !== this.columnCount) {
      this.lastPinchApplyTime = Date.now();
      this.columnCount = this.pendingColumnCount;
    }
  }

  // --- Multi-Selection Logic (Spec 2.2 & 2.3) ---
  enterSelectionMode(initialAssetId?: string): void {
    this.isSelectionMode = true;
    this.selectedAssetIds = new Set<string>();
    if (initialAssetId) {
      this.selectedAssetIds.add(initialAssetId);
    }
    this.preDragSelection = new Set<string>(this.selectedAssetIds);
  }

  exitSelectionMode(): void {
    this.isSelectionMode = false;
    this.selectedAssetIds = new Set<string>();
    this.dragStartIndex = -1;
    this.pendingStartIndex = -1;
    this.gestureLockMode = GestureLockMode.NONE;
    this.isAlbumPickerOpen = false;
  }

  isAllSelected(): boolean {
    return this.allVisibleAssets.length > 0 && this.selectedAssetIds.size === this.allVisibleAssets.length;
  }

  toggleSelectAll(): void {
    if (this.isAllSelected()) {
      this.selectedAssetIds = new Set<string>();
    } else {
      this.selectedAssetIds = new Set<string>(this.allVisibleAssets.map((a: AssetItem) => a.id));
    }
    this.preDragSelection = new Set<string>(this.selectedAssetIds);
  }

  toggleAssetSelection(assetId: string): void {
    const updated = new Set<string>(this.selectedAssetIds);
    if (updated.has(assetId)) {
      updated.delete(assetId);
    } else {
      updated.add(assetId);
    }
    this.selectedAssetIds = updated;
    this.preDragSelection = new Set<string>(updated);
  }

  handleDragSelection(startIndex: number, currentIndex: number): void {
    if (startIndex < 0 || currentIndex < 0) {
      return;
    }
    const min = Math.min(startIndex, currentIndex);
    const max = Math.max(startIndex, currentIndex);

    const updated = new Set<string>(this.preDragSelection);
    for (let i = min; i <= max; i++) {
      if (this.allVisibleAssets[i]) {
        updated.add(this.allVisibleAssets[i].id);
      }
    }
    this.selectedAssetIds = updated;
  }

  // Find asset index by window coordinates for smooth drag selection
  private findAssetIndexAt(winX: number, winY: number): number {
    for (let i = 0; i < this.allVisibleAssets.length; i++) {
      const asset = this.allVisibleAssets[i];
      const rect = this.itemBounds.get(asset.id);
      if (rect) {
        if (winX >= rect.x && winX <= rect.x + rect.w && winY >= rect.y && winY <= rect.y + rect.h) {
          return i;
        }
      }
    }

    let closestIndex = -1;
    let minDistance = 1000000;
    for (let i = 0; i < this.allVisibleAssets.length; i++) {
      const asset = this.allVisibleAssets[i];
      const rect = this.itemBounds.get(asset.id);
      if (rect) {
        const cx = rect.x + rect.w / 2;
        const cy = rect.y + rect.h / 2;
        const dist = (winX - cx) * (winX - cx) + (winY - cy) * (winY - cy);
        if (dist < minDistance) {
          minDistance = dist;
          closestIndex = i;
        }
      }
    }
    return closestIndex;
  }

  private handleTouchDown(winX: number, winY: number): void {
    // A user touch takes over from the cold-start bottom anchoring
    this.cancelBottomAnchor();
    if (this.isSelectionMode) {
      this.touchStartWinX = winX;
      this.touchStartWinY = winY;
      this.pendingStartIndex = this.findAssetIndexAt(winX, winY);
      this.preDragSelection = new Set<string>(this.selectedAssetIds);
      this.gestureLockMode = GestureLockMode.UNDECIDED;
    }
  }

  private handleTouchMove(winX: number, winY: number): void {
    if (this.gestureLockMode === GestureLockMode.DRAG_SELECTION) {
      const currIdx = this.findAssetIndexAt(winX, winY);
      if (currIdx >= 0 && this.dragStartIndex >= 0) {
        this.handleDragSelection(this.dragStartIndex, currIdx);
      }
      return;
    }

    if (this.isSelectionMode && this.gestureLockMode === GestureLockMode.UNDECIDED) {
      const dx = Math.abs(winX - this.touchStartWinX);
      const dy = Math.abs(winY - this.touchStartWinY);
      const dist = Math.sqrt(dx * dx + dy * dy);

      if (dist >= 10) {
        if (dy > dx * 1.5) {
          this.gestureLockMode = GestureLockMode.SCROLL;
        } else {
          this.gestureLockMode = GestureLockMode.DRAG_SELECTION;
          this.dragStartIndex = this.pendingStartIndex >= 0 ? this.pendingStartIndex : this.findAssetIndexAt(winX, winY);
          if (this.dragStartIndex >= 0) {
            const asset = this.allVisibleAssets[this.dragStartIndex];
            if (asset) {
              const updated = new Set<string>(this.preDragSelection);
              updated.add(asset.id);
              this.selectedAssetIds = updated;
            }
          }
        }
      }
    }
  }

  private handleTouchUp(): void {
    this.gestureLockMode = GestureLockMode.NONE;
    this.dragStartIndex = -1;
    this.pendingStartIndex = -1;
  }

  // --- Batch Operations (Spec 2.2 & 2.3 & DELETION_ACCOUNT_SHARING_SPEC) ---

  handleBatchShare(): void {
    const count = this.selectedAssetIds.size;
    if (count === 0) {
      return;
    }
    this.showToast(`已准备分享 ${count} 项照片`);
  }

  async handleBatchAddToAlbum(): Promise<void> {
    if (this.selectedAssetIds.size === 0) {
      return;
    }
    try {
      this.availableAlbums = await AppBridge.fetchAlbums();
      if (this.availableAlbums.length === 0) {
        this.showToast('暂无可用的相册，请先在相册Tab创建');
        return;
      }
      this.isAlbumPickerOpen = true;
    } catch (err) {
      this.showToast('获取相册列表失败');
    }
  }

  async addSelectedToAlbum(album: AlbumItem): Promise<void> {
    const ids = Array.from(this.selectedAssetIds);
    try {
      await AppBridge.addAssetsToAlbum(album.id, ids);
      this.showToast(`已将 ${ids.length} 项照片添加到相册「${album.name}」`);
      this.isAlbumPickerOpen = false;
      this.exitSelectionMode();
    } catch (err) {
      this.showToast('添加到相册失败: ' + (err instanceof Error ? err.message : String(err)));
    }
  }

  async handleBatchFavorite(): Promise<void> {
    const selectedAssets = this.allVisibleAssets.filter(a => this.selectedAssetIds.has(a.id));
    if (selectedAssets.length === 0) {
      return;
    }
    const hasUnfavorite = selectedAssets.some(a => !a.isFavorite);
    const targetState = hasUnfavorite;
    const ids = selectedAssets.map(a => a.id);
    try {
      await AppBridge.batchFavorite(ids, targetState);
      selectedAssets.forEach(a => {
        a.isFavorite = targetState;
      });
      this.showToast(targetState ? `已将 ${ids.length} 项照片加入收藏` : `已取消 ${ids.length} 项照片收藏`);
    } catch (err) {
      this.showToast('收藏操作失败: ' + (err instanceof Error ? err.message : String(err)));
    }
  }

  async handleBatchDelete(): Promise<void> {
    const selectedIds = Array.from(this.selectedAssetIds);
    if (selectedIds.length === 0) {
      return;
    }
    const selectedAssets = this.allVisibleAssets.filter(a => this.selectedAssetIds.has(a.id));
    const cloudAssets = selectedAssets.filter(a => a.hasCloudOriginal || a.syncState === 'CLOUD_ONLY' || a.syncState === 'SYNCED');
    const localAssets = selectedAssets.filter(a => a.hasLocalOriginal || a.syncState === 'LOCAL_ONLY');

    let confirmTitle = '删除确认';
    let confirmMsg = `确定删除选中的 ${selectedIds.length} 项照片吗？`;
    if (cloudAssets.length > 0 && localAssets.length === 0) {
      confirmTitle = '移入云端回收站';
      confirmMsg = `确定将选中的 ${cloudAssets.length} 项照片移入 Immich 云端回收站吗？`;
    } else if (localAssets.length > 0 && cloudAssets.length === 0) {
      confirmTitle = '删除本机照片';
      confirmMsg = `确定从本机彻底删除选中的 ${localAssets.length} 张照片吗？`;
    } else if (cloudAssets.length > 0 && localAssets.length > 0) {
      confirmTitle = '批量删除与回收';
      confirmMsg = `将 ${cloudAssets.length} 项云端照片移入回收站，并删除 ${localAssets.length} 张本机照片。`;
    }

    AlertDialog.show({
      title: confirmTitle,
      message: confirmMsg,
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {}
      },
      secondaryButton: {
        value: '确认删除',
        fontColor: '#F56C6C',
        action: async () => {
          try {
            if (cloudAssets.length > 0) {
              const cloudIds = cloudAssets.map(a => a.id);
              await AppBridge.trashCloudAssets(cloudIds);
            }
            if (localAssets.length > 0) {
              for (const a of localAssets) {
                await AppBridge.deleteLocalAsset(a.id);
              }
            }
            // Remove from buckets
            for (const b of this.buckets) {
              b.assets = b.assets.filter(a => !this.selectedAssetIds.has(a.id));
            }
            this.updateFlattenedAssets();
            this.showToast(`已删除 ${selectedIds.length} 项照片`);
            this.exitSelectionMode();
          } catch (err) {
            this.showToast('删除失败: ' + (err instanceof Error ? err.message : String(err)));
          }
        }
      }
    });
  }

  getSyncBadgeText(state: SyncState): string {
    switch (state) {
      case 'LOCAL_ONLY':
        return '↑';
      case 'SYNCED':
        return '✓';
      case 'CLOUD_ONLY':
        return '☁';
      case 'REMOTE_DELETED_LOCAL_KEPT':
        return '⊘';
      case 'UPLOADING':
        return '⋯';
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

  build() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column() {
        // Top Header
        Row() {
          if (!this.isSelectionMode) {
            Text('Photos')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.theme.textPrimary)

            Blank()

            // Source Filter Capsule Switcher: All / Cloud / Local (Spec 2.1)
            Row({ space: 0 }) {
              Button('全部')
                .fontSize(11)
                .fontWeight(this.currentFilter === 'ALL' ? FontWeight.Bold : FontWeight.Normal)
                .height(26)
                .padding({ left: 8, right: 8 })
                .fontColor(this.currentFilter === 'ALL' ? '#FFFFFF' : '#909399')
                .backgroundColor(this.currentFilter === 'ALL' ? '#409EFF' : Color.Transparent)
                .borderRadius(13)
                .onClick(() => {
                  this.currentFilter = 'ALL';
                  this.updateFlattenedAssets();
                })

              Button('云端')
                .fontSize(11)
                .fontWeight(this.currentFilter === 'CLOUD' ? FontWeight.Bold : FontWeight.Normal)
                .height(26)
                .padding({ left: 8, right: 8 })
                .fontColor(this.currentFilter === 'CLOUD' ? '#FFFFFF' : '#909399')
                .backgroundColor(this.currentFilter === 'CLOUD' ? '#409EFF' : Color.Transparent)
                .borderRadius(13)
                .onClick(() => {
                  this.currentFilter = 'CLOUD';
                  this.updateFlattenedAssets();
                })

              Button('本机')
                .fontSize(11)
                .fontWeight(this.currentFilter === 'LOCAL' ? FontWeight.Bold : FontWeight.Normal)
                .height(26)
                .padding({ left: 8, right: 8 })
                .fontColor(this.currentFilter === 'LOCAL' ? '#FFFFFF' : '#909399')
                .backgroundColor(this.currentFilter === 'LOCAL' ? '#409EFF' : Color.Transparent)
                .borderRadius(13)
                .onClick(() => {
                  this.currentFilter = 'LOCAL';
                  this.updateFlattenedAssets();
                })
            }
            .backgroundColor('#2C2C2E')
            .borderRadius(15)
            .padding(2)
            .margin({ right: 8 })

            // Density Indicator
            Text(`${this.columnCount}c`)
              .fontSize(10)
              .fontColor('#909399')
              .margin({ right: 4 })

            // Refresh from server
            Button() {
              Image($r('app.media.icon_refresh')).width(18).height(18).fillColor('#409EFF')
            }
              .fontColor('#409EFF')
              .backgroundColor(Color.Transparent)
              .height(24)
              .padding({ left: 4, right: 4 })
              .onClick(() => {
                this.loadTimeline();
              })

            // Select entry
            Button('选择')
              .fontSize(12)
              .fontColor('#409EFF')
              .backgroundColor(Color.Transparent)
              .height(24)
              .padding({ left: 4, right: 4 })
              .margin({ right: 8 })
              .onClick(() => {
                this.enterSelectionMode();
              })

            // Account / Settings Avatar Button in header
            Button({ type: ButtonType.Circle }) {
              Image($r('app.media.icon_person')).width(20).height(20).fillColor('#A4A9B2')
            }
            .width(32)
            .height(32)
            .backgroundColor('#3A3A3C')
            .onClick(() => {
              this.onOpenSettings();
            })
          } else {
            // Selection Mode Header (Spec 2.2)
            Button('取消')
              .fontSize(13)
              .fontColor('#409EFF')
              .backgroundColor(Color.Transparent)
              .onClick(() => {
                this.exitSelectionMode();
              })

            Blank()

            Text(`已选择 ${this.selectedAssetIds.size} 项`)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')

            Blank()

            Button(this.isAllSelected() ? '取消全选' : '全选')
              .fontSize(13)
              .fontColor('#409EFF')
              .backgroundColor(Color.Transparent)
              .onClick(() => {
                this.toggleSelectAll();
              })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        if (this.loadError) {
          Column({ space: 12 }) {
            Text('无法连接服务器照片流').fontSize(16).fontColor('#FFFFFF')
            Text(this.loadError).fontSize(12).fontColor('#F56C6C')
            Button('重试').onClick(() => { this.loadTimeline(); })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (!this.isLoading && (!this.hasAnyVisibleAssets() || this.buckets.length === 0)) {
          Column({ space: 12 }) {
            Text(this.currentFilter === 'ALL' ? '时间线暂无照片' :
              (this.currentFilter === 'CLOUD' ? '云端暂无照片' : '本机暂无照片'))
              .fontSize(15)
              .fontColor('#A4A9B2')
            Button('刷新').onClick(() => { this.loadTimeline(); })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else if (this.isLoading && this.buckets.length === 0) {
          Column() {
            LoadingProgress()
              .width(48)
              .height(48)
              .color('#409EFF')
            Text('正在同步 Immich 时间线...')
              .fontSize(13)
              .fontColor('#909399')
              .margin({ top: 12 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 16, scroller: this.listScroller }) {
            ForEach(this.buckets, (bucket: TimeBucketItem) => {
              if (this.getFilteredBucketAssets(bucket).length > 0) {
                ListItem() {
                  Column({ space: 8 }) {
                    // Bucket Header
                    Row() {
                      Text(this.formatBucketTitle(bucket.timeBucket))
                        .fontSize(15)
                        .fontWeight(FontWeight.Bold)
                        .fontColor('#E4E7ED')
                      Blank()
                      Text(`${this.getFilteredBucketAssets(bucket).length} 项`)
                        .fontSize(11)
                        .fontColor('#909399')
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16 })

                    // Dynamic Column Asset Grid (2 to 15 columns)
                    Grid() {
                      ForEach(this.getFilteredBucketAssets(bucket), (asset: AssetItem) => {
                        GridItem() {
                          Stack({ alignContent: Alignment.TopEnd }) {
                            AssetThumbnail({ asset: asset })
                              .width('100%')
                              .height('100%')

                            // Multi-Selection Checkbox (Top-Left)
                            if (this.isSelectionMode) {
                              Stack({ alignContent: Alignment.Center }) {
                                Row()
                                  .width(20)
                                  .height(20)
                                  .borderRadius(10)
                                  .backgroundColor(this.selectedAssetIds.has(asset.id) ? '#409EFF' : '#80000000')
                                  .border({ width: 1.5, color: '#FFFFFF' })

                                if (this.selectedAssetIds.has(asset.id)) {
                                  Text('✓')
                                    .fontSize(11)
                                    .fontColor('#FFFFFF')
                                    .fontWeight(FontWeight.Bold)
                                }
                              }
                              .width(26)
                              .height(26)
                              .margin({ top: 4, left: 4 })
                              .align(Alignment.TopStart)
                            }

                            // Live Photo / Video Badge (Top-Right)
                            if (this.columnCount <= 8) {
                              if (asset.isLivePhoto) {
                                Text('LIVE')
                                  .fontSize(this.columnCount <= 4 ? 8 : 6)
                                  .fontColor('#FFFFFF')
                                  .backgroundColor('#99000000')
                                  .borderRadius(2)
                                  .padding({ left: 2, right: 2 })
                                  .margin({ top: 2, right: 2 })
                              } else if (asset.isVideo) {
                                Text('▶')
                                  .fontSize(this.columnCount <= 4 ? 8 : 6)
                                  .fontColor('#FFFFFF')
                                  .backgroundColor('#99000000')
                                  .borderRadius(2)
                                  .padding({ left: 2, right: 2 })
                                  .margin({ top: 2, right: 2 })
                              }
                            }

                            // Bottom-Right: Sync State Badge (Spec: bottom-right icon, adapted for high density)
                            if (this.columnCount <= 10) {
                              Row() {
                                if (asset.syncState === 'CLOUD_ONLY') {
                                  Image($r('app.media.icon_cloud'))
                                    .width(this.columnCount <= 4 ? 12 : 10)
                                    .height(this.columnCount <= 4 ? 12 : 10)
                                    .fillColor('#FFFFFF')
                                } else {
                                  Text(this.getSyncBadgeText(asset.syncState))
                                    .fontSize(this.columnCount <= 4 ? 10 : 8)
                                    .fontColor('#FFFFFF')
                                    .fontWeight(FontWeight.Bold)
                                }
                              }
                                .backgroundColor(this.getSyncBadgeBgColor(asset.syncState))
                                .borderRadius(8)
                                .padding({ left: 3, right: 3, top: 1, bottom: 1 })
                                .margin({ right: 2, bottom: 2 })
                                .align(Alignment.BottomEnd)
                            } else {
                              // High-density (11-15 columns) micro indicator dot
                              Row()
                                .width(5)
                                .height(5)
                                .borderRadius(2.5)
                                .backgroundColor(this.getSyncBadgeBgColor(asset.syncState))
                                .margin({ right: 1.5, bottom: 1.5 })
                                .align(Alignment.BottomEnd)
                            }
                          }
                          .width('100%')
                          .aspectRatio(1)
                          .backgroundColor('#2C2C2E')
                          .onAreaChange((_oldArea: Area, newArea: Area) => {
                            this.itemBounds.set(asset.id, {
                              x: newArea.globalPosition.x as number,
                              y: newArea.globalPosition.y as number,
                              w: newArea.width as number,
                              h: newArea.height as number
                            });
                          })
                          .onClick(() => {
                            if (this.isSelectionMode) {
                              this.toggleAssetSelection(asset.id);
                            } else {
                              this.onSelectAsset(asset, this.allVisibleAssets);
                            }
                          })
                          .gesture(
                            LongPressGesture({ repeat: false })
                              .onAction(() => {
                                if (!this.isSelectionMode) {
                                  this.enterSelectionMode(asset.id);
                                  const idx = this.allVisibleAssets.findIndex((a: AssetItem) => a.id === asset.id);
                                  this.dragStartIndex = idx;
                                  this.preDragSelection = new Set<string>(this.selectedAssetIds);
                                  this.gestureLockMode = GestureLockMode.DRAG_SELECTION;
                                }
                              })
                          )
                        }
                      }, (asset: AssetItem) => asset.id + ':' + this.thumbEpoch)
                    }
                    .columnsTemplate(this.getColumnsTemplate())
                    .columnsGap(this.columnCount > 12 ? 1 : (this.columnCount > 8 ? 1.5 : 2))
                    .rowsGap(this.columnCount > 12 ? 1 : (this.columnCount > 8 ? 1.5 : 2))
                    .width('100%')
                  }
                  .width('100%')
                }
              }
            }, (bucket: TimeBucketItem) => bucket.timeBucket)
          }
          .width('100%')
          .layoutWeight(1)
          .onScrollIndex((first: number, last: number) => {
            // Track if user is at the bottom
            this.isAtBottom = (last >= this.buckets.length - 1);
            if (first <= 1 && !this.isLoadingOlder && this.oldestLoadedBucketIdx > 0) {
              this.loadOlderBuckets();
            }
          })
          .onReachStart(() => {
            if (!this.isLoadingOlder && this.oldestLoadedBucketIdx > 0) {
              this.loadOlderBuckets();
            }
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
              .onActionEnd(() => {
                this.handlePinchEnd();
              })
          )
        }

        // Multi-Selection Bottom Batch Action Bar (Spec 2.2 & 2.3)
        if (this.isSelectionMode) {
          Row() {
            // 1. Share
            Column({ space: 3 }) {
              Image($r('app.media.icon_share'))
                .width(20)
                .height(20)
                .fillColor(this.selectedAssetIds.size > 0 ? '#409EFF' : '#555558')
              Text('分享')
                .fontSize(11)
                .fontColor(this.selectedAssetIds.size > 0 ? '#409EFF' : '#555558')
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .height('100%')
            .enabled(this.selectedAssetIds.size > 0)
            .onClick(() => {
              this.handleBatchShare();
            })

            // 2. Add to Album
            Column({ space: 3 }) {
              Image($r('app.media.icon_albums'))
                .width(20)
                .height(20)
                .fillColor(this.selectedAssetIds.size > 0 ? '#409EFF' : '#555558')
              Text('加相册')
                .fontSize(11)
                .fontColor(this.selectedAssetIds.size > 0 ? '#409EFF' : '#555558')
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .height('100%')
            .enabled(this.selectedAssetIds.size > 0)
            .onClick(() => {
              this.handleBatchAddToAlbum();
            })

            // 3. Favorite
            Column({ space: 3 }) {
              Image($r('app.media.icon_heart'))
                .width(20)
                .height(20)
                .fillColor(this.selectedAssetIds.size > 0 ? '#409EFF' : '#555558')
              Text('收藏')
                .fontSize(11)
                .fontColor(this.selectedAssetIds.size > 0 ? '#409EFF' : '#555558')
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .height('100%')
            .enabled(this.selectedAssetIds.size > 0)
            .onClick(() => {
              this.handleBatchFavorite();
            })

            // 4. Delete / Trash
            Column({ space: 3 }) {
              Image($r('app.media.icon_trash'))
                .width(20)
                .height(20)
                .fillColor(this.selectedAssetIds.size > 0 ? '#F56C6C' : '#555558')
              Text('删除')
                .fontSize(11)
                .fontColor(this.selectedAssetIds.size > 0 ? '#F56C6C' : '#555558')
            }
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
            .height('100%')
            .enabled(this.selectedAssetIds.size > 0)
            .onClick(() => {
              this.handleBatchDelete();
            })
          }
          .width('100%')
          .height(56)
          .backgroundColor('#1C1C1E')
          .border({ width: { top: 1 }, color: '#2C2C2E' })
        }
      }
      .width('100%')
      .height('100%')

      // "Back to Latest" Floating Button (Spec 2.4: Return to latest photos at bottom)
      if (!this.isAtBottom && !this.isSelectionMode) {
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
          this.scrollToLatest();
        })
      }

      // Add to Album Picker Modal
      if (this.isAlbumPickerOpen) {
        Stack({ alignContent: Alignment.Bottom }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#88000000')
            .onClick(() => {
              this.isAlbumPickerOpen = false;
            })

          Column({ space: 12 }) {
            Row() {
              Text('添加到相册')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
              Blank()
              Button('取消')
                .fontSize(13)
                .fontColor('#909399')
                .backgroundColor(Color.Transparent)
                .onClick(() => {
                  this.isAlbumPickerOpen = false;
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 16 })

            List({ space: 8 }) {
              ForEach(this.availableAlbums, (album: AlbumItem) => {
                ListItem() {
                  Row({ space: 12 }) {
                    Image($r('app.media.icon_albums'))
                      .width(28)
                      .height(28)
                      .fillColor('#409EFF')

                    Column({ space: 2 }) {
                      Text(album.name)
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                        .fontColor('#FFFFFF')
                      Text(`${album.count} 项`)
                        .fontSize(12)
                        .fontColor('#909399')
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                  }
                  .width('100%')
                  .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                  .backgroundColor('#2C2C2E')
                  .borderRadius(10)
                  .onClick(() => {
                    this.addSelectedToAlbum(album);
                  })
                }
              }, (album: AlbumItem) => album.id)
            }
            .width('100%')
            .height(260)
            .padding({ left: 16, right: 16, bottom: 20 })
          }
          .width('100%')
          .backgroundColor('#1C1C1E')
          .borderRadius({ topLeft: 16, topRight: 16 })
        }
        .width('100%')
        .height('100%')
      }

      // In-page Toast overlay
      if (this.toastText) {
        Row() {
          Text(this.toastText)
            .fontSize(12)
            .fontColor('#FFFFFF')
        }
        .backgroundColor('#DD333336')
        .borderRadius(18)
        .padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .margin({ bottom: 70 })
        .align(Alignment.Bottom)
        .shadow({ radius: 8, color: '#44000000', offsetY: 3 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bg)
    .onTouch((event: TouchEvent) => {
      if (event.touches.length > 0) {
        const touch = event.touches[0];
        if (event.type === TouchType.Down) {
          this.handleTouchDown(touch.windowX, touch.windowY);
        } else if (event.type === TouchType.Move) {
          this.handleTouchMove(touch.windowX, touch.windowY);
        } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
          this.handleTouchUp();
        }
      }
    })
  }
}
