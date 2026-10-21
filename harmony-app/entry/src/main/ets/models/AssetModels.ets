// ArkUI V2 Models for Immich Assets, Albums, and Timeline Buckets

export type SyncState = 'LOCAL_ONLY' | 'SYNCED' | 'CLOUD_ONLY' | 'REMOTE_DELETED_LOCAL_KEPT' | 'UPLOADING';

export interface AssetItemOptions {
  id: string;
  assetType?: string;
  fileCreatedAt: string;
  fileModifiedAt?: string;
  isFavorite?: boolean;
  duration?: string;
  livePhotoVideoId?: string;
  thumbhash?: string;
  localThumbPath?: string | Resource;
  localPreviewPath?: string | Resource;
  localVideoPath?: string;
  bucketId?: string;
  syncState?: SyncState;
  hasLocalOriginal?: boolean;
  hasCloudOriginal?: boolean;
}

@ObservedV2
export class AssetItem {
  @Trace id: string = '';
  @Trace assetType: string = 'IMAGE'; // 'IMAGE' | 'VIDEO'
  @Trace fileCreatedAt: string = '';
  @Trace fileModifiedAt?: string;
  @Trace isFavorite: boolean = false;
  @Trace duration?: string;
  @Trace livePhotoVideoId?: string;
  @Trace thumbhash?: string;
  @Trace localThumbPath?: string | Resource;
  @Trace localPreviewPath?: string | Resource;
  @Trace localVideoPath?: string;
  @Trace bucketId?: string;
  @Trace syncState: SyncState = 'SYNCED';
  @Trace hasLocalOriginal: boolean = true;
  @Trace hasCloudOriginal: boolean = true;

  constructor(options?: AssetItemOptions) {
    if (options) {
      this.id = options.id;
      if (options.assetType) {
        this.assetType = options.assetType;
      }
      this.fileCreatedAt = options.fileCreatedAt;
      this.fileModifiedAt = options.fileModifiedAt;
      this.isFavorite = options.isFavorite ?? false;
      this.duration = options.duration;
      this.livePhotoVideoId = options.livePhotoVideoId;
      this.thumbhash = options.thumbhash;
      this.localThumbPath = options.localThumbPath;
      this.localPreviewPath = options.localPreviewPath;
      this.localVideoPath = options.localVideoPath;
      this.bucketId = options.bucketId;
      if (options.syncState) {
        this.syncState = options.syncState;
      }
      this.hasLocalOriginal = options.hasLocalOriginal ?? (this.syncState !== 'CLOUD_ONLY');
      this.hasCloudOriginal = options.hasCloudOriginal ?? (this.syncState !== 'LOCAL_ONLY' && this.syncState !== 'REMOTE_DELETED_LOCAL_KEPT');
    }
  }

  get isLivePhoto(): boolean {
    return !!(this.livePhotoVideoId && this.livePhotoVideoId.length > 0);
  }

  get isVideo(): boolean {
    return this.assetType.toUpperCase() === 'VIDEO';
  }
}

@ObservedV2
export class TimeBucketItem {
  @Trace timeBucket: string = '';
  @Trace count: number = 0;
  @Trace assets: AssetItem[] = [];
  @Trace isLoaded: boolean = false;

  constructor(timeBucket: string, count: number, assets: AssetItem[] = []) {
    this.timeBucket = timeBucket;
    this.count = count;
    this.assets = assets;
  }
}

export type AlbumSource = 'LOCAL' | 'CLOUD' | 'MERGED';

@ObservedV2
export class AlbumItem {
  @Trace id: string = '';
  @Trace name: string = '';
  @Trace coverUri: string | Resource = '';
  @Trace thumbnailAssetId: string = '';
  @Trace coverAsset?: AssetItem;
  @Trace count: number = 0;
  @Trace isPinned: boolean = false;
  @Trace source: AlbumSource = 'MERGED';
  @Trace localCount: number = 0;
  @Trace cloudCount: number = 0;

  constructor(
    id: string,
    name: string,
    coverUri: string | Resource,
    count: number,
    source: AlbumSource = 'MERGED',
    isPinned: boolean = false,
    localCount: number = 0,
    cloudCount: number = 0
  ) {
    this.id = id;
    this.name = name;
    this.coverUri = coverUri;
    this.count = count;
    this.source = source;
    this.isPinned = isPinned;
    this.localCount = localCount;
    this.cloudCount = cloudCount;
  }
}

export interface AlbumAssetPage {
  assets: AssetItem[];
  nextPage?: number;
  nextCursor?: string;
}

@ObservedV2
export class AccountInfo {
  @Trace id: string = '';
  @Trace serverUrl: string = '';
  @Trace email: string = '';
  @Trace name: string = '';
  @Trace avatarUrl: string = '';
  @Trace isCurrent: boolean = false;
  @Trace cacheSizeMB: number = 0;

  constructor(id: string, serverUrl: string, email: string, name: string, isCurrent: boolean = false, cacheSizeMB: number = 128) {
    this.id = id;
    this.serverUrl = serverUrl;
    this.email = email;
    this.name = name;
    this.isCurrent = isCurrent;
    this.cacheSizeMB = cacheSizeMB;
  }
}

@ObservedV2
export class BackupConfig {
  @Trace enabled: boolean = false;
  @Trace wifiOnly: boolean = true;
  @Trace requireCharging: boolean = false;
  @Trace selectedAlbumNames: string[] = [];

  constructor(enabled: boolean = false, wifiOnly: boolean = true, requireCharging: boolean = false) {
    this.enabled = enabled;
    this.wifiOnly = wifiOnly;
    this.requireCharging = requireCharging;
  }
}

export interface AssetViewerBundle {
  assetId: string;
  assetType: string;
  imagePath: string | Resource;
  videoPath?: string;
  isLivePhoto: boolean;
  duration?: string;
  syncState?: SyncState;
  hasLocalOriginal?: boolean;
  hasCloudOriginal?: boolean;
}

export interface ExifInfo {
  cameraMake?: string;
  cameraModel?: string;
  lensModel?: string;
  focalLength?: string;
  fNumber?: string;
  exposureTime?: string;
  iso?: string;
  dateTimeOriginal?: string;
  fileSize?: string;
  resolution?: string;
  city?: string;
  country?: string;
  latitude?: number;
  longitude?: number;
}

export interface BucketRawItem {
  timeBucket: string;
  count: number;
}

export interface AssetRawItem {
  id: string;
  type?: string;
  assetType?: string;
  fileCreatedAt: string;
  fileModifiedAt?: string;
  isFavorite?: boolean;
  duration?: string;
  livePhotoVideoId?: string;
  thumbhash?: string;
  localThumbPath?: string;
  localPreviewPath?: string;
  localVideoPath?: string;
  syncState?: SyncState;
}
