import { parseTimelineAssets, TimelineAssetDto } from './TimelineAdapter';

export interface AlbumDto {
  id: string;
  albumName: string;
  albumThumbnailAssetId?: string | null;
  assetCount: number;
}

interface SearchAssetsEnvelope {
  assets: {
    items: TimelineAssetDto[];
    nextPage?: string | number | null;
    nextCursor?: string | null;
  };
}

export interface AlbumAssetsDtoPage {
  items: TimelineAssetDto[];
  nextPage?: number;
  nextCursor?: string;
}

export function parseAlbums(json: string): AlbumDto[] {
  let albums: AlbumDto[];
  try {
    albums = JSON.parse(json) as AlbumDto[];
  } catch (err) {
    throw new Error(`相册响应不是有效的 JSON：${err}`);
  }
  if (!Array.isArray(albums)) {
    throw new Error('不支持的相册响应');
  }
  for (const album of albums) {
    if (!album || typeof album.id !== 'string' || !album.id || typeof album.albumName !== 'string') {
      throw new Error('服务器相册数据无效');
    }
    if (typeof album.assetCount !== 'number' || album.assetCount < 0 || !Number.isInteger(album.assetCount)) {
      throw new Error('服务器相册数量无效');
    }
  }
  return albums;
}

export function parseAlbumAssetPage(json: string): AlbumAssetsDtoPage {
  let response: SearchAssetsEnvelope;
  try {
    response = JSON.parse(json) as SearchAssetsEnvelope;
  } catch (err) {
    throw new Error(`相册照片响应不是有效的 JSON：${err}`);
  }
  if (!response || !response.assets || !Array.isArray(response.assets.items)) {
    throw new Error('不支持的相册照片响应');
  }
  const items = parseTimelineAssets(JSON.stringify(response.assets.items));
  let nextPage: number | undefined = undefined;
  if (response.assets.nextPage !== null && response.assets.nextPage !== undefined) {
    nextPage = Number(response.assets.nextPage);
    if (!Number.isInteger(nextPage) || nextPage < 1) {
      throw new Error('相册分页数据无效');
    }
  }
  const nextCursor = response.assets.nextCursor || undefined;
  if (nextCursor !== undefined && typeof nextCursor !== 'string') {
    throw new Error('相册游标无效');
  }
  if (items.length === 0 && (nextPage || nextCursor)) {
    throw new Error('服务器返回了空相册页但仍有后续内容');
  }
  return { items: items, nextPage: nextPage, nextCursor: nextCursor };
}
