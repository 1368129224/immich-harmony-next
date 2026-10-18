// ArkUI V2 Models for Immich Assets and Timeline Buckets

export interface AssetItemOptions {
  id: string;
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
  bucketId?: string;
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
  @Trace localThumbPath?: string;
  @Trace localPreviewPath?: string;
  @Trace localVideoPath?: string;
  @Trace bucketId?: string;

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

export interface AssetViewerBundle {
  assetId: string;
  assetType: string;
  imagePath: string;
  videoPath?: string;
  isLivePhoto: boolean;
  duration?: string;
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
}
