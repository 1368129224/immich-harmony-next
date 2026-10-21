// Index.ets — Main Entry View (ArkUI V2)
// Full 4-Tab Architecture: Photos, Albums, Search, Library with Top Header Account Entry
import { LoginPage } from './LoginPage';
import { TimelinePage } from './TimelinePage';
import { AlbumsPage } from './AlbumsPage';
import { AlbumDetailPage } from './AlbumDetailPage';
import { SearchPage } from './SearchPage';
import { LibraryPage } from './LibraryPage';
import { AssetViewerPage } from './AssetViewerPage';
import { AccountSettingsDialog } from '../components/AccountSettingsDialog';
import { AssetItem, AlbumItem } from '../models/AssetModels';
import { ImmichApiService, collectionTitle } from '../services/ImmichApiService';
import { ThemeService } from '../services/ThemeService';

@Entry
@ComponentV2
struct Index {
  @Local isLoggedIn: boolean = false; // Show LoginPage first for clean authentication
  @Local currentTabIndex: number = 0;
  @Local selectedAsset: AssetItem | null = null;
  @Local viewingAssetList: AssetItem[] = [];
  @Local selectedAlbum: AlbumItem | null = null;
  // Library collection currently open (empty string = none)
  @Local collectionKind: string = '';
  @Local isSettingsOpen: boolean = false;
  @Local scrollToLatestTrigger: number = 0;
  @Local theme: ThemeService = ThemeService.getInstance();
  // Bumped after the thumbnail cache is cleared so visible thumbnails reload from the server
  @Local mediaVersion: number = 0;

  private tabController: TabsController = new TabsController();
  private lastPhotosTabClickTime: number = 0;

  aboutToAppear(): void {
    const hasSession = ImmichApiService.getInstance().loadSavedSession();
    if (hasSession) {
      this.isLoggedIn = true;
      console.info('[Index] Auto-restored login session');
    }
  }

  private handleTabClick(index: number): void {
    if (index === 0) {
      const now = Date.now();
      if (this.currentTabIndex === 0 && (now - this.lastPhotosTabClickTime < 450)) {
        // Double click on Photos tab -> jump to latest photos at bottom
        console.info('[Index] Photos Tab double-clicked -> jump to latest');
        this.scrollToLatestTrigger++;
        this.lastPhotosTabClickTime = 0;
      } else {
        this.lastPhotosTabClickTime = now;
      }
    }
    this.currentTabIndex = index;
    this.tabController.changeIndex(index);
  }

  @Builder
  buildTabItem(title: string, icon: Resource, index: number) {
    Column({ space: 3 }) {
      Image(icon)
        .width(20)
        .height(20)
        .fillColor(this.currentTabIndex === index ? '#409EFF' : '#909399')
      Text(title)
        .fontSize(10)
        .fontWeight(this.currentTabIndex === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.currentTabIndex === index ? '#409EFF' : '#909399')
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
    .height('100%')
    .onClick(() => {
      this.handleTabClick(index);
    })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (!this.isLoggedIn) {
        LoginPage({
          onLoginSuccess: () => {
            this.isLoggedIn = true;
          }
        })
      } else {
        // Main Authenticated Shell with 4-Tab Bar
        Stack({ alignContent: Alignment.TopEnd }) {
          Tabs({ barPosition: BarPosition.End, controller: this.tabController }) {
            // Tab 1: Photos (Timeline)
            TabContent() {
              TimelinePage({
                scrollToLatestTrigger: this.scrollToLatestTrigger,
                mediaVersion: this.mediaVersion,
                onSelectAsset: (asset: AssetItem, allAssets?: AssetItem[]) => {
                  this.selectedAsset = asset;
                  this.viewingAssetList = allAssets ?? [asset];
                },
                onOpenSettings: () => {
                  this.isSettingsOpen = true;
                }
              })
            }
            .tabBar(this.buildTabItem('照片', $r('app.media.icon_photos'), 0))

            // Tab 2: Albums
            TabContent() {
              AlbumsPage({
                onOpenAlbum: (album: AlbumItem) => {
                  this.selectedAlbum = album;
                }
              })
            }
            .tabBar(this.buildTabItem('相册', $r('app.media.icon_albums'), 1))

            // Tab 3: Search
            TabContent() {
              SearchPage()
            }
            .tabBar(this.buildTabItem('搜索', $r('app.media.icon_search'), 2))

            // Tab 4: Library
            TabContent() {
              LibraryPage({
                onSelectItem: (cat: string) => {
                  this.collectionKind = cat;
                },
                onClearThumbnailCache: () => {
                  ImmichApiService.getInstance().clearMediaCache();
                  this.mediaVersion++;
                }
              })
            }
            .tabBar(this.buildTabItem('资料库', $r('app.media.icon_library'), 3))
          }
          .onChange((index: number) => {
            this.currentTabIndex = index;
          })
          .barHeight(56)
          .barBackgroundColor(this.theme.tabBarBg)
          .width('100%')
          .height('100%')
        }
        .width('100%')
        .height('100%')
      }

      // Keep album detail mounted behind the viewer so dismissal restores its scroll/page state.
      if (this.selectedAlbum !== null) {
        AlbumDetailPage({
          album: this.selectedAlbum,
          onBack: () => {
            this.selectedAlbum = null;
          },
          onSelectAsset: (asset: AssetItem, allAssets?: AssetItem[]) => {
            this.selectedAsset = asset;
            this.viewingAssetList = allAssets ?? [asset];
          }
        })
      }

      // Library collections (favorites, videos, live photos, archive, trash, recently added)
      if (this.collectionKind !== '') {
        TimelinePage({
          collectionKind: this.collectionKind,
          collectionTitle: collectionTitle(this.collectionKind),
          mediaVersion: this.mediaVersion,
          onBack: () => {
            this.collectionKind = '';
          },
          onSelectAsset: (asset: AssetItem, allAssets?: AssetItem[]) => {
            this.selectedAsset = asset;
            this.viewingAssetList = allAssets ?? [asset];
          },
          onOpenSettings: () => {
            this.isSettingsOpen = true;
          }
        })
      }

      // Full-screen Asset Viewer Overlay
      if (this.selectedAsset !== null) {
        AssetViewerPage({
          currentAsset: this.selectedAsset,
          allAssets: this.viewingAssetList,
          onDismiss: () => {
            this.selectedAsset = null;
          }
        })
      }

      // Account & Settings Modal Bottom Sheet
      AccountSettingsDialog({
        isVisible: this.isSettingsOpen,
        onClose: () => {
          this.isSettingsOpen = false;
        },
        onLogout: () => {
          this.isSettingsOpen = false;
          this.selectedAsset = null;
          this.selectedAlbum = null;
          ImmichApiService.getInstance().logout();
          this.isLoggedIn = false;
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.theme.bg)
  }
}
