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
  let raw: Object;
  try {
    raw = JSON.parse(json) as Object;
  } catch (err) {
    throw new Error(`时间线响应不是有效的 JSON：${err}`);
  }
  if (Array.isArray(raw)) {
    const rows = raw as TimelineAssetDto[];
    for (const row of rows) {
      if (typeof row.id !== 'string' || !row.id) {
        throw new Error('时间线资源 ID 无效');
      }
    }
    return rows;
  }
  const columns = raw as ColumnarAssetsDto;
  if (!columns || !Array.isArray(columns.id)) {
    throw new Error('不支持的时间线响应：需要资源数组或 ID 列');
  }
  const rows: TimelineAssetDto[] = [];
  for (let i = 0; i < columns.id.length; i++) {
    if (typeof columns.id[i] !== 'string' || !columns.id[i]) {
      throw new Error('时间线资源 ID 无效');
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
