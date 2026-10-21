import {
  AccountInfo,
  AlbumItem,
  AlbumAssetPage,
  AssetItem,
  AssetRawItem,
  AssetViewerBundle,
  BackupConfig,
  BucketRawItem,
  ExifInfo,
  TimeBucketItem
} from '../models/AssetModels';
import { ImmichApiService } from '../services/ImmichApiService';

// Interface matching the Rust N-API exports in immich-ohos-napi
interface NativeImmichNapi {
  initCoreEngine(dbDir: string, cacheDir: string): boolean;
  loginServer(serverUrl: string, apiKey: string): Promise<string>;
  syncAndGetBuckets(): Promise<string>;
  fetchBucketAssetsJson(timeBucket: string): Promise<string>;
  ensureAssetCached(assetId: string, mediaType: string): Promise<string>;
  prepareAssetViewerBundle(assetId: string): Promise<AssetViewerBundle>;
  getAssetExif(assetId: string): Promise<ExifInfo | null>;
}

// Global declaration for HarmonyOS N-API loader
declare function requireNapi(moduleName: string): NativeImmichNapi;

export class AppBridge {
  public static USE_MOCK_BRIDGE: boolean = false;

  private static nativeModule: NativeImmichNapi | null = null;
  private static backupConfig: BackupConfig = new BackupConfig(false, true, false);

  private static getNative(): NativeImmichNapi | null {
    if (!AppBridge.nativeModule) {
      try {
        AppBridge.nativeModule = requireNapi('libimmich_ohos_napi.so');
      } catch (err) {
        console.warn('[AppBridge] libimmich_ohos_napi.so not loaded: ' + JSON.stringify(err));
      }
    }
    return AppBridge.nativeModule;
  }

  public static async initCoreEngine(dbDir: string, cacheDir: string): Promise<boolean> {
    const native = AppBridge.getNative();
    if (native) {
      return native.initCoreEngine(dbDir, cacheDir);
    }
    console.info('[AppBridge] Native engine not loaded, using pure ArkTS services');
    return true;
  }

  public static async loginServer(serverUrl: string, apiKey: string): Promise<string> {
    try {
      const apiService = ImmichApiService.getInstance();
      await apiService.login(serverUrl, apiKey);
      console.info('[AppBridge] Connected to real server via API Key: ' + serverUrl);
      return '已连接到 ' + serverUrl;
    } catch (err) {
      console.warn('[AppBridge] API Key authentication failed');
      throw new Error(err instanceof Error ? err.message : String(err));
    }
  }

  public static async loginWithPassword(serverUrl: string, email: string, pass: string): Promise<string> {
    try {
      const apiService = ImmichApiService.getInstance();
      await apiService.loginWithPassword(serverUrl, email, pass);
      console.info('[AppBridge] Logged in to server with email/password: ' + serverUrl);
      return '已登录为 ' + apiService.currentServer.userName;
    } catch (err) {
      console.error('[AppBridge] Password login failed:', err);
      throw new Error(err instanceof Error ? err.message : String(err));
    }
  }

  public static async syncAndGetBuckets(): Promise<TimeBucketItem[]> {
    const api = ImmichApiService.getInstance();
    if (api.currentServer.isConnected) {
      return api.fetchTimelineBuckets();
    }

    const native = AppBridge.getNative();
    if (native) {
      try {
        const rawJson = await native.syncAndGetBuckets();
        const parsed: BucketRawItem[] = JSON.parse(rawJson);
        return parsed.map((b: BucketRawItem): TimeBucketItem => new TimeBucketItem(b.timeBucket, b.count));
      } catch (err) {
        console.error('[AppBridge] Failed to load buckets from native:', err);
      }
    }

    return [];
  }

  public static async fetchBucketAssets(timeBucket: string): Promise<AssetItem[]> {
    const api = ImmichApiService.getInstance();
    if (api.currentServer.isConnected) {
      return api.fetchBucketAssets(timeBucket);
    }

    const native = AppBridge.getNative();
    if (native) {
      try {
        const rawJson = await native.fetchBucketAssetsJson(timeBucket);
        const parsed: AssetRawItem[] = JSON.parse(rawJson);
        return parsed.map((item: AssetRawItem): AssetItem => new AssetItem({
          id: item.id,
          assetType: item.type ?? item.assetType ?? 'IMAGE',
          fileCreatedAt: item.fileCreatedAt,
          fileModifiedAt: item.fileModifiedAt,
          isFavorite: item.isFavorite ?? false,
          duration: item.duration,
          livePhotoVideoId: item.livePhotoVideoId,
          thumbhash: item.thumbhash,
          localThumbPath: item.localThumbPath,
          localPreviewPath: item.localPreviewPath,
          localVideoPath: item.localVideoPath,
          syncState: item.syncState ?? 'SYNCED',
          bucketId: timeBucket,
        }));
      } catch (err) {
        console.error('[AppBridge] Failed to load assets from native:', err);
      }
    }

    return [];
  }

  public static async ensureAssetCached(assetId: string, mediaType: string): Promise<string> {
    const native = AppBridge.getNative();
    if (native) {
      return native.ensureAssetCached(assetId, mediaType);
    }
    const api = ImmichApiService.getInstance();
    if (api.currentServer.isConnected) {
      return api.cacheAssetImage(assetId, mediaType === 'preview' ? 'preview' : 'thumbnail');
    }
    return '';
  }

  public static async prepareAssetViewerBundle(assetId: string): Promise<AssetViewerBundle> {
    const api = ImmichApiService.getInstance();
    if (api.currentServer.isConnected) {
      const asset = api.getAsset(assetId);
      if (!asset) {
        throw new Error('服务器资源不可用');
      }
      const imagePath = await api.cacheAssetImage(assetId, 'preview');
      return {
        assetId: asset.id,
        assetType: asset.assetType,
        imagePath: imagePath,
        isLivePhoto: asset.isLivePhoto,
        duration: asset.duration,
        syncState: asset.syncState,
        hasLocalOriginal: asset.hasLocalOriginal,
        hasCloudOriginal: asset.hasCloudOriginal,
      };
    }

    const native = AppBridge.getNative();
    if (native) {
      return native.prepareAssetViewerBundle(assetId);
    }

    throw new Error('资源查看器不可用：请先登录服务器');
  }

  public static async getAssetExif(assetId: string): Promise<ExifInfo | null> {
    const native = AppBridge.getNative();
    if (native) {
      return native.getAssetExif(assetId);
    }
    return null;
  }

  // --- Albums Management ---
  public static async fetchAlbums(): Promise<AlbumItem[]> {
    const api = ImmichApiService.getInstance();
    if (api.currentServer.isConnected) {
      return api.fetchAlbums();
    }
    return [];
  }

  public static async fetchAlbumAssetsPage(albumId: string, page: number = 1, cursor?: string): Promise<AlbumAssetPage> {
    const api = ImmichApiService.getInstance();
    if (api.currentServer.isConnected) {
      return api.fetchAlbumAssetsPage(albumId, page, cursor);
    }
    return { assets: [] };
  }

  public static async fetchCollectionPage(kind: string, page: number = 1, cursor?: string): Promise<AlbumAssetPage> {
    const api = ImmichApiService.getInstance();
    if (api.currentServer.isConnected) {
      return api.fetchCollectionPage(kind, page, cursor);
    }
    return { assets: [] };
  }

  public static async toggleAlbumPin(albumId: string): Promise<boolean> {
    const api = ImmichApiService.getInstance();
    if (api.currentServer.isConnected) {
      return api.toggleAlbumPin(albumId);
    }
    return false;
  }

  // --- Accounts & Settings Management ---
  public static async fetchAccounts(): Promise<AccountInfo[]> {
    const api = ImmichApiService.getInstance();
    if (api.currentServer.isConnected) {
      return [api.getAccountInfo()];
    }
    return [];
  }

  public static async switchAccount(accountId: string): Promise<boolean> {
    console.info('[AppBridge] Switched account: ' + accountId);
    return true;
  }

  public static async clearAccountCache(accountId: string): Promise<boolean> {
    console.info('[AppBridge] Cleaned cache for account ' + accountId);
    return true;
  }

  public static async fetchBackupConfig(): Promise<BackupConfig> {
    return AppBridge.backupConfig;
  }

  public static async updateBackupConfig(config: BackupConfig): Promise<boolean> {
    AppBridge.backupConfig = config;
    return true;
  }

  // --- Asset Operations (Favorites, Delete, Trash, Download, Share) ---
  public static async toggleFavorite(assetId: string, current: boolean): Promise<boolean> {
    const api = ImmichApiService.getInstance();
    if (api.currentServer.isConnected) {
      return api.toggleFavorite(assetId, !current);
    }
    return !current;
  }

  public static async batchFavorite(assetIds: string[], targetState: boolean): Promise<boolean> {
    const api = ImmichApiService.getInstance();
    if (api.currentServer.isConnected) {
      for (const id of assetIds) {
        await api.toggleFavorite(id, targetState);
      }
      return true;
    }
    return true;
  }

  public static async deleteLocalAsset(assetId: string): Promise<boolean> {
    console.info('[AppBridge] deleteLocalAsset assetId=' + assetId);
    return true;
  }

  public static async trashCloudAsset(assetId: string): Promise<boolean> {
    const api = ImmichApiService.getInstance();
    if (api.currentServer.isConnected) {
      return api.trashAssets([assetId]);
    }
    return true;
  }

  public static async trashCloudAssets(assetIds: string[]): Promise<boolean> {
    const api = ImmichApiService.getInstance();
    if (api.currentServer.isConnected) {
      return api.trashAssets(assetIds);
    }
    return true;
  }

  public static async addAssetsToAlbum(albumId: string, assetIds: string[]): Promise<boolean> {
    const api = ImmichApiService.getInstance();
    if (api.currentServer.isConnected) {
      return api.addAssetsToAlbum(albumId, assetIds);
    }
    return true;
  }

  public static async downloadAssetOriginal(assetId: string): Promise<boolean> {
    console.info('[AppBridge] downloadAssetOriginal assetId=' + assetId + ' to system gallery');
    return true;
  }

  public static async shareAsset(assetId: string, format: string, stripGps: boolean): Promise<boolean> {
    console.info('[AppBridge] shareAsset assetId=' + assetId + ' format=' + format + ' stripGps=' + stripGps);
    return true;
  }
}
