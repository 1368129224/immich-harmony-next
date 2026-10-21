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
  const albums = JSON.parse(json) as AlbumDto[];
  if (!Array.isArray(albums)) {
    throw new Error('Unsupported albums response');
  }
  for (const album of albums) {
    if (!album || typeof album.id !== 'string' || !album.id || typeof album.albumName !== 'string') {
      throw new Error('Invalid server album');
    }
    if (typeof album.assetCount !== 'number' || album.assetCount < 0 || !Number.isInteger(album.assetCount)) {
      throw new Error('Invalid server album count');
    }
  }
  return albums;
}

export function parseAlbumAssetPage(json: string): AlbumAssetsDtoPage {
  const response = JSON.parse(json) as SearchAssetsEnvelope;
  if (!response || !response.assets || !Array.isArray(response.assets.items)) {
    throw new Error('Unsupported album assets response');
  }
  const items = parseTimelineAssets(JSON.stringify(response.assets.items));
  let nextPage: number | undefined = undefined;
  if (response.assets.nextPage !== null && response.assets.nextPage !== undefined) {
    nextPage = Number(response.assets.nextPage);
    if (!Number.isInteger(nextPage) || nextPage < 1) {
      throw new Error('Invalid album pagination');
    }
  }
  const nextCursor = response.assets.nextCursor || undefined;
  if (nextCursor !== undefined && typeof nextCursor !== 'string') {
    throw new Error('Invalid album cursor');
  }
  if (items.length === 0 && (nextPage || nextCursor)) {
    throw new Error('Server returned an empty album page with a continuation');
  }
  return { items: items, nextPage: nextPage, nextCursor: nextCursor };
}
