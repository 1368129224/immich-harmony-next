// Clean-room REST response adapter. No UI or network dependencies.
export interface TimelineAssetDto {
  id: string;
  type?: string;
  fileCreatedAt?: string;
  localDateTime?: string;
  isFavorite?: boolean;
  livePhotoVideoId?: string;
  duration?: string;
}

interface ColumnarAssetsDto {
  id: string[];
  type?: string[];
  fileCreatedAt?: string[];
  localDateTime?: string[];
  isFavorite?: boolean[];
  livePhotoVideoId?: string[];
  duration?: string[];
}

export function parseTimelineAssets(json: string): TimelineAssetDto[] {
  const raw: Object = JSON.parse(json) as Object;
  if (Array.isArray(raw)) {
    const rows = raw as TimelineAssetDto[];
    for (const row of rows) {
      if (typeof row.id !== 'string' || !row.id) {
        throw new Error('Invalid timeline asset ID');
      }
    }
    return rows;
  }
  const columns = raw as ColumnarAssetsDto;
  if (!columns || !Array.isArray(columns.id)) {
    throw new Error('Unsupported timeline response: expected asset array or ID columns');
  }
  const rows: TimelineAssetDto[] = [];
  for (let i = 0; i < columns.id.length; i++) {
    if (typeof columns.id[i] !== 'string' || !columns.id[i]) {
      throw new Error('Invalid timeline asset ID');
    }
    rows.push({
      id: columns.id[i],
      type: columns.type?.[i] || 'IMAGE',
      fileCreatedAt: columns.fileCreatedAt?.[i] || columns.localDateTime?.[i] || '',
      isFavorite: columns.isFavorite?.[i] || false,
      livePhotoVideoId: columns.livePhotoVideoId?.[i] || undefined,
      duration: columns.duration?.[i] || undefined,
    });
  }
  return rows;
}
