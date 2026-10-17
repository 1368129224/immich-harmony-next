import { AssetItem, AssetViewerBundle, TimeBucketItem } from '../models/AssetModels';

// Interface matching the Rust N-API exports in immich-ohos-napi
interface NativeImmichNapi {
  initCoreEngine(dbDir: string, cacheDir: string): boolean;
  loginServer(serverUrl: string, apiKey: string): Promise<string>;
  syncAndGetBuckets(): Promise<string>;
  fetchBucketAssetsJson(timeBucket: string): Promise<string>;
  ensureAssetCached(assetId: string, mediaType: string): Promise<string>;
  prepareAssetViewerBundle(assetId: string): Promise<AssetViewerBundle>;
}

export class AppBridge {
  /**
   * UI Sandbox Flag:
   * Keep USE_MOCK_BRIDGE = true when iterating on UI layout, gestures, or previewer
   * Switch to false when testing end-to-end N-API FFI on emulator/device
   */
  public static USE_MOCK_BRIDGE: boolean = true;

  private static nativeModule: NativeImmichNapi | null = null;

  private static getNative(): NativeImmichNapi {
    if (!AppBridge.nativeModule) {
      try {
        // In HarmonyOS NEXT, N-API .so is loaded via standard import/require
        // @ts-ignore
        AppBridge.nativeModule = requireNapi('libimmich_ohos_napi.so') as NativeImmichNapi;
      } catch (err) {
        console.error('[AppBridge] Failed to load libimmich_ohos_napi.so, falling back to mock:', err);
        AppBridge.USE_MOCK_BRIDGE = true;
      }
    }
    return AppBridge.nativeModule!;
  }

  public static async initCoreEngine(dbDir: string, cacheDir: string): Promise<boolean> {
    if (AppBridge.USE_MOCK_BRIDGE) {
      console.info('[AppBridge:Mock] initCoreEngine dbDir=' + dbDir + ' cacheDir=' + cacheDir);
      return true;
    }
    return AppBridge.getNative().initCoreEngine(dbDir, cacheDir);
  }

  public static async loginServer(serverUrl: string, apiKey: string): Promise<string> {
    if (AppBridge.USE_MOCK_BRIDGE) {
      console.info('[AppBridge:Mock] loginServer url=' + serverUrl);
      return 'Mock login successful (Connected to ' + serverUrl + ')';
    }
    return AppBridge.getNative().loginServer(serverUrl, apiKey);
  }

  public static async syncAndGetBuckets(): Promise<TimeBucketItem[]> {
    if (AppBridge.USE_MOCK_BRIDGE) {
      return [
        new TimeBucketItem('2024-03-01T00:00:00.000Z', 12),
        new TimeBucketItem('2024-02-01T00:00:00.000Z', 8),
        new TimeBucketItem('2024-01-01T00:00:00.000Z', 15),
      ];
    }

    const rawJson = await AppBridge.getNative().syncAndGetBuckets();
    const parsed = JSON.parse(rawJson) as Array<{ timeBucket: string; count: number }>;
    return parsed.map(b => new TimeBucketItem(b.timeBucket, b.count));
  }

  public static async fetchBucketAssets(timeBucket: string): Promise<AssetItem[]> {
    if (AppBridge.USE_MOCK_BRIDGE) {
      return [
        new AssetItem({
          id: 'mock-live-photo-1',
          assetType: 'IMAGE',
          fileCreatedAt: '2024-03-15T14:22:10.000Z',
          isFavorite: true,
          livePhotoVideoId: 'mock-live-video-1',
          localThumbPath: 'resources/base/media/mock_thumb_1.jpg',
          localPreviewPath: 'resources/base/media/mock_preview_1.jpg',
          bucketId: timeBucket,
        }),
        new AssetItem({
          id: 'mock-photo-2',
          assetType: 'IMAGE',
          fileCreatedAt: '2024-03-14T09:12:00.000Z',
          isFavorite: false,
          localThumbPath: 'resources/base/media/mock_thumb_2.jpg',
          bucketId: timeBucket,
        }),
        new AssetItem({
          id: 'mock-video-3',
          assetType: 'VIDEO',
          fileCreatedAt: '2024-03-10T18:45:00.000Z',
          isFavorite: true,
          duration: '0:00:32.000000',
          localThumbPath: 'resources/base/media/mock_thumb_3.jpg',
          bucketId: timeBucket,
        }),
      ];
    }

    const rawJson = await AppBridge.getNative().fetchBucketAssetsJson(timeBucket);
    const parsed = JSON.parse(rawJson) as Array<Record<string, unknown>>;
    return parsed.map(item => new AssetItem({
      id: item.id as string,
      assetType: (item.type || item.assetType) as string,
      fileCreatedAt: item.fileCreatedAt as string,
      fileModifiedAt: item.fileModifiedAt as string | undefined,
      isFavorite: !!item.isFavorite,
      duration: item.duration as string | undefined,
      livePhotoVideoId: item.livePhotoVideoId as string | undefined,
      thumbhash: item.thumbhash as string | undefined,
      localThumbPath: item.localThumbPath as string | undefined,
      localPreviewPath: item.localPreviewPath as string | undefined,
      localVideoPath: item.localVideoPath as string | undefined,
      bucketId: timeBucket,
    }));
  }

  public static async ensureAssetCached(assetId: string, mediaType: string): Promise<string> {
    if (AppBridge.USE_MOCK_BRIDGE) {
      return `/data/storage/el2/base/cache/${mediaType}s/${assetId}.${mediaType === 'video' ? 'mp4' : 'jpg'}`;
    }
    return AppBridge.getNative().ensureAssetCached(assetId, mediaType);
  }

  public static async prepareAssetViewerBundle(assetId: string): Promise<AssetViewerBundle> {
    if (AppBridge.USE_MOCK_BRIDGE) {
      const isLive = assetId.includes('live');
      const isVid = assetId.includes('video');
      return {
        assetId: assetId,
        assetType: isVid ? 'VIDEO' : 'IMAGE',
        imagePath: `/data/storage/el2/base/cache/previews/${assetId}.jpg`,
        videoPath: (isLive || isVid) ? `/data/storage/el2/base/cache/videos/${assetId}.mp4` : undefined,
        isLivePhoto: isLive,
        duration: isVid ? '0:00:32.000000' : undefined,
      };
    }
    return AppBridge.getNative().prepareAssetViewerBundle(assetId);
  }
}
