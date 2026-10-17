// Index.ets — Main Entry View (ArkUI V2)
import { LoginPage } from './LoginPage';
import { TimelinePage } from './TimelinePage';
import { AssetViewerPage } from './AssetViewerPage';
import { AssetItem } from '../models/AssetModels';

@Entry
@ComponentV2
struct Index {
  @Local isLoggedIn: boolean = false;
  @Local selectedAsset: AssetItem | null = null;

  build() {
    Stack() {
      if (!this.isLoggedIn) {
        LoginPage({
          onLoginSuccess: () => {
            this.isLoggedIn = true;
          }
        })
      } else {
        TimelinePage({
          onSelectAsset: (asset: AssetItem) => {
            this.selectedAsset = asset;
          }
        })
      }

      // Viewer Overlay
      if (this.selectedAsset !== null) {
        AssetViewerPage({
          currentAsset: this.selectedAsset,
          onDismiss: () => {
            this.selectedAsset = null;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
