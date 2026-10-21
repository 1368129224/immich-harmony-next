// ImmichApiService.ets — Native ArkTS HTTP Communication Layer for Immich API
import { http } from '@kit.NetworkKit';
import { AssetItem, TimeBucketItem, AccountInfo, AlbumItem, AlbumAssetPage } from '../models/AssetModels';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { parseTimelineAssets, TimelineAssetDto } from './TimelineAdapter';
import { parseAlbums, parseAlbumAssetPage } from './AlbumAdapter';
import { formatApiError } from './ApiErrors';

export interface ImmichServerInfo {
  serverUrl: string;
  apiKey: string;
  accessToken?: string;
  userEmail: string;
  userName: string;
  isConnected: boolean;
}

export class ImmichApiService {
  private static instance: ImmichApiService | null = null;
  private cacheDir: string = '';
  private filesDir: string = '';
  private assets: Map<string, AssetItem> = new Map<string, AssetItem>();
  private albums: Map<string, AlbumItem> = new Map<string, AlbumItem>();
  private pendingMedia: Map<string, Promise<string>> = new Map<string, Promise<string>>();
  private activeDownloads: number = 0;
  private downloadWaiters: Array<() => void> = [];

  public setCacheDir(path: string): void {
    this.cacheDir = path;
  }

  public setFilesDir(path: string): void {
    this.filesDir = path;
  }

  private fileExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (_) {
      return false;
    }
  }

  private ensureDir(dir: string): void {
    if (!this.fileExists(dir)) {
      try {
        fs.mkdirSync(dir, true);
      } catch (err) {
        if (!this.fileExists(dir)) {
          console.error('[ImmichApi] Failed to create directory: ' + formatApiError(err));
        }
      }
    }
  }

  private getSessionFilePath(): string {
    return `${this.filesDir}/immich_session.json`;
  }

  public saveSession(): void {
    if (!this.filesDir) {
      return;
    }
    try {
      const sessionData = JSON.stringify(this.currentServer);
      const path = this.getSessionFilePath();
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, sessionData);
      } finally {
        fs.closeSync(file);
      }
      console.info('[ImmichApi] Saved session to ' + path);
    } catch (err) {
      console.error('[ImmichApi] Failed to save session: ' + formatApiError(err));
    }
  }

  public loadSavedSession(): boolean {
    if (!this.filesDir) {
      return false;
    }
    try {
      const path = this.getSessionFilePath();
      if (!this.fileExists(path)) {
        return false;
      }
      const content = fs.readTextSync(path);
      if (!content) {
        return false;
      }
      const data = JSON.parse(content) as ImmichServerInfo;
      if (data && data.serverUrl && (data.accessToken || data.apiKey)) {
        this.currentServer = {
          serverUrl: data.serverUrl,
          apiKey: data.apiKey || '',
          accessToken: data.accessToken,
          userEmail: data.userEmail || '',
          userName: data.userName || 'Immich User',
          isConnected: true,
        };
        console.info('[ImmichApi] Restored saved session for ' + this.currentServer.userEmail);
        return true;
      }
    } catch (err) {
      console.warn('[ImmichApi] Could not load saved session: ' + formatApiError(err));
    }
    return false;
  }

  public logout(): void {
    this.currentServer = {
      serverUrl: this.currentServer.serverUrl,
      apiKey: '',
      accessToken: undefined,
      userEmail: '',
      userName: '',
      isConnected: false,
    };
    this.assets.clear();
    this.albums.clear();
    if (this.filesDir) {
      try {
        const path = this.getSessionFilePath();
        if (fs.accessSync(path)) {
          fs.unlinkSync(path);
          console.info('[ImmichApi] Session file deleted on logout');
        }
      } catch (err) {
        console.error('[ImmichApi] Failed to remove session file: ' + formatApiError(err));
      }
    }
  }

  private authHeaders(): Record<string, string> {
    const header: Record<string, string> = {};
    if (this.currentServer.accessToken) {
      header['Authorization'] = `Bearer ${this.currentServer.accessToken}`;
    } else if (this.currentServer.apiKey) {
      header['x-api-key'] = this.currentServer.apiKey;
    }
    return header;
  }

  private async timelineRequest(endpoint: string, extraQuery: string = ''): Promise<string> {
    const request = http.createHttp();
    try {
      const prefix = `${this.currentServer.serverUrl}/api/timeline/${endpoint}?${extraQuery}`;
      const header = this.authHeaders();
      header['Accept'] = 'application/json';
      let response = await request.request(prefix + 'visibility=timeline&withPartners=true', {
        method: http.RequestMethod.GET, header: header, connectTimeout: 10000, readTimeout: 15000,
      });
      if (response.responseCode === 400) {
        response = await request.request(prefix + 'size=MONTH&isArchived=false', {
          method: http.RequestMethod.GET, header: header, connectTimeout: 10000, readTimeout: 15000,
        });
      }
      console.info(`[ImmichApi] Timeline ${endpoint}: HTTP ${response.responseCode}`);
      if (response.responseCode !== 200) {
        throw new Error(`Timeline ${endpoint}: HTTP ${response.responseCode}`);
      }
      return response.result as string;
    } catch (error) {
      throw new Error(formatApiError(error));
    } finally {
      request.destroy();
    }
  }

  /** Deletes every cached thumbnail/preview. Files are re-downloaded from the server on next view. */
  public clearMediaCache(): void {
    this.pendingMedia.clear();
    if (!this.cacheDir) {
      return;
    }
    this.removeTree(`${this.cacheDir}/immich-media`);
  }

  private removeTree(path: string): void {
    if (!this.fileExists(path)) {
      return;
    }
    const stat = fs.statSync(path);
    if (stat.isDirectory()) {
      for (const name of fs.listFileSync(path)) {
        this.removeTree(`${path}/${name}`);
      }
      fs.rmdirSync(path);
    } else {
      fs.unlinkSync(path);
    }
  }

  public getAsset(id: string): AssetItem | undefined {
    return this.assets.get(id);
  }

  public async cacheAssetImage(id: string, size: string = 'thumbnail'): Promise<string> {
    if (size !== 'thumbnail' && size !== 'preview') {
      throw new Error('Unsupported image size');
    }
    if (!this.cacheDir || !this.currentServer.isConnected) {
      throw new Error('Media cache or authenticated session is unavailable');
    }
    // Account-scoped cache prevents another account reusing cached private media.
    const scope = encodeURIComponent(this.currentServer.serverUrl + '|' + this.currentServer.userEmail);
    const directory = `${this.cacheDir}/immich-media/${scope}`;
    const path = `${directory}/${encodeURIComponent(id)}-${size}.jpg`;
    if (this.fileExists(path)) {
      return fileUri.getUriFromPath(path);
    }
    const pending = this.pendingMedia.get(path);
    if (pending) {
      return pending;
    }
    const serverUrl = this.currentServer.serverUrl;
    const header = this.authHeaders();
    const task = this.downloadImage(serverUrl, header, id, size, directory, path);
    this.pendingMedia.set(path, task);
    try {
      return await task;
    } finally {
      this.pendingMedia.delete(path);
    }
  }

  private async downloadImage(serverUrl: string, header: Record<string, string>, id: string,
    size: string, directory: string, path: string): Promise<string> {
    if (this.activeDownloads >= 3) {
      await new Promise<void>((resolve) => { this.downloadWaiters.push(resolve); });
    } else {
      this.activeDownloads++;
    }
    const request = http.createHttp();
    try {
      // Endpoint compatibility: try /api/assets/{id}/thumbnail?size={size} first, then fallback to /api/asset/thumbnail/{id}?size={size}
      let url = `${serverUrl}/api/assets/${encodeURIComponent(id)}/thumbnail?size=${size}`;
      let response = await request.request(url, {
        method: http.RequestMethod.GET, header: header,
        expectDataType: http.HttpDataType.ARRAY_BUFFER, connectTimeout: 10000, readTimeout: 20000,
      });

      // Only fall back when the modern endpoint is unavailable; authentication failures must surface.
      if (response.responseCode === 404 || response.responseCode === 405) {
        url = `${serverUrl}/api/asset/thumbnail/${encodeURIComponent(id)}?size=${size}`;
        response = await request.request(url, {
          method: http.RequestMethod.GET, header: header,
          expectDataType: http.HttpDataType.ARRAY_BUFFER, connectTimeout: 10000, readTimeout: 20000,
        });
      }

      if (response.responseCode !== 200) {
        throw new Error(`Image ${size}: HTTP ${response.responseCode}`);
      }
      const data = response.result as ArrayBuffer;
      if (data.byteLength === 0) {
        throw new Error('Server returned an empty image');
      }

      this.ensureDir(directory);
      const temporary = path + '.part';
      const file = fs.openSync(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        const written = fs.writeSync(file.fd, data);
        if (written !== data.byteLength) {
          throw new Error('Incomplete image cache write');
        }
      } finally {
        fs.closeSync(file);
      }
      try {
        if (this.fileExists(path)) {
          fs.unlinkSync(path);
        }
        fs.renameSync(temporary, path);
      } catch (err) {
        console.warn('[ImmichApi] Rename cached file warning: ' + formatApiError(err));
      }
      return fileUri.getUriFromPath(path);
    } catch (error) {
      throw new Error(formatApiError(error));
    } finally {
      request.destroy();
      const next = this.downloadWaiters.shift();
      if (next) {
        next();
      } else {
        this.activeDownloads--;
      }
    }
  }

  public currentServer: ImmichServerInfo = {
    serverUrl: 'https://photo.v6.sora233.eu.org:59418',
    apiKey: '',
    accessToken: undefined,
    userEmail: 'user@immich.cloud',
    userName: 'Immich Cloud User',
    isConnected: false,
  };

  public static getInstance(): ImmichApiService {
    if (!ImmichApiService.instance) {
      ImmichApiService.instance = new ImmichApiService();
    }
    return ImmichApiService.instance;
  }

  private normalizeUrl(url: string): string {
    let clean = url.trim();
    if (clean.endsWith('/')) {
      clean = clean.substring(0, clean.length - 1);
    }
    if (!clean.startsWith('http://') && !clean.startsWith('https://')) {
      clean = 'https://' + clean;
    }
    return clean;
  }

  /**
   * Ping & Login with Email + Password (Spec primary login method)
   */
  public async loginWithPassword(serverUrl: string, email: string, pass: string): Promise<boolean> {
    const cleanUrl = this.normalizeUrl(serverUrl);
    console.info('[ImmichApi] Attempting password login');

    const httpRequest = http.createHttp();
    try {
      // Step 1: Login POST
      const loginResp = await httpRequest.request(`${cleanUrl}/api/auth/login`, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        extraData: JSON.stringify({
          email: email.trim(),
          password: pass,
        }),
        connectTimeout: 10000,
        readTimeout: 10000,
      });

      console.info(`[ImmichApi] Login HTTP status: ${loginResp.responseCode}`);
      if (loginResp.responseCode !== 200 && loginResp.responseCode !== 201) {
        let msg = 'Incorrect email or password';
        if (loginResp.result) {
          try {
            const errObj = JSON.parse(loginResp.result as string) as Record<string, string>;
            if (errObj.message) {
              msg = errObj.message;
            }
          } catch (_) {}
        }
        throw new Error(msg);
      }

      const resData = JSON.parse(loginResp.result as string) as Record<string, Object>;
      const token = (resData['accessToken'] as string) || '';
      const userObj = resData['user'] as Record<string, string> || {};
      if (typeof token !== 'string' || token.trim().length === 0) {
        throw new Error('Server did not return an access token');
      }

      this.currentServer.serverUrl = cleanUrl;
      this.currentServer.accessToken = token;
      this.currentServer.apiKey = '';
      this.currentServer.userEmail = userObj.email || (resData['userEmail'] as string) || email.trim();
      this.currentServer.userName = userObj.name || (resData['name'] as string) || 'Immich User';
      this.currentServer.isConnected = true;
      this.assets.clear();
      this.albums.clear();
      this.saveSession();

      return true;
    } catch (err) {
      console.error('[ImmichApi] Password login failed: ' + formatApiError(err));
      throw new Error(formatApiError(err));
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * Ping & Login to Immich server via API Key
   */
  public async login(serverUrl: string, apiKey: string): Promise<boolean> {
    const cleanUrl = this.normalizeUrl(serverUrl);
    const cleanKey = apiKey.trim();
    if (!cleanKey) {
      throw new Error('Please enter an API Key');
    }
    console.info(`[ImmichApi] Attempting login to: ${cleanUrl}`);

    const httpRequest = http.createHttp();
    try {
      // Step 1: Ping server
      const pingResp = await httpRequest.request(`${cleanUrl}/api/server/ping`, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
      });

      console.info(`[ImmichApi] Ping status: ${pingResp.responseCode}`);
      if (pingResp.responseCode !== 200) {
        // Try fallback legacy ping
        const fallbackPing = await httpRequest.request(`${cleanUrl}/api/server-info/ping`, {
          method: http.RequestMethod.GET,
          connectTimeout: 6000,
          readTimeout: 6000,
        });
        if (fallbackPing.responseCode !== 200) {
          throw new Error(`Server ping failed (HTTP ${pingResp.responseCode})`);
        }
      }

      // Authenticate before replacing the current session. Ping alone is not login.
      const userResp = await httpRequest.request(`${cleanUrl}/api/users/me`, {
        method: http.RequestMethod.GET,
        header: {
          'x-api-key': cleanKey,
          'Accept': 'application/json',
        },
        connectTimeout: 8000,
        readTimeout: 8000,
      });
      if (userResp.responseCode !== 200 || !userResp.result) {
        throw new Error(`API Key authentication failed (HTTP ${userResp.responseCode})`);
      }
      const userData = JSON.parse(userResp.result as string) as Record<string, string>;
      this.currentServer = {
        serverUrl: cleanUrl,
        apiKey: cleanKey,
        accessToken: undefined,
        userEmail: userData.email || '',
        userName: userData.name || 'Immich User',
        isConnected: true,
      };
      this.assets.clear();
      this.albums.clear();
      this.saveSession();

      return true;
    } catch (err) {
      console.error('[ImmichApi] Login failed: ' + formatApiError(err));
      throw new Error(formatApiError(err));
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * Fetch timeline buckets from real server or fallback
   */
  public async fetchTimelineBuckets(): Promise<TimeBucketItem[]> {
    if (!this.currentServer.isConnected) {
      console.info('[ImmichApi] Server not connected, no timeline buckets available');
      return [];
    }

    const json = await this.timelineRequest('buckets');
    const rawList = JSON.parse(json) as Array<Record<string, Object>>;
    if (!Array.isArray(rawList)) {
      throw new Error('Unsupported timeline buckets response');
    }
    const buckets: TimeBucketItem[] = [];
    for (const bucket of rawList) {
      const date = bucket['timeBucket'] as string;
      if (typeof date !== 'string' || !date) {
        throw new Error('Invalid timeline bucket date');
      }
      buckets.push(new TimeBucketItem(date, Number(bucket['count'] || 0)));
    }
    // The timeline places the latest month at the bottom.
    buckets.sort((a: TimeBucketItem, b: TimeBucketItem) => a.timeBucket.localeCompare(b.timeBucket));
    console.info(`[ImmichApi] Received ${buckets.length} timeline buckets`);
    return buckets;
  }

  /**
   * Fetch assets in a specific bucket
   */
  public async fetchBucketAssets(timeBucket: string): Promise<AssetItem[]> {
    if (!this.currentServer.isConnected) {
      return [];
    }

    const json = await this.timelineRequest('bucket', `timeBucket=${encodeURIComponent(timeBucket)}&`);
    const rows = parseTimelineAssets(json);
    const assets: AssetItem[] = [];
    for (const row of rows) {
      assets.push(this.assetFromDto(row, timeBucket));
    }
    console.info(`[ImmichApi] Parsed ${assets.length} server assets`);
    return assets;
  }

  private assetFromDto(row: TimelineAssetDto, bucketId?: string): AssetItem {
    const existing = this.assets.get(row.id);
    const asset = new AssetItem({
      id: row.id,
      assetType: (row.type || 'IMAGE').toUpperCase(),
      fileCreatedAt: row.fileCreatedAt || row.localDateTime || '',
      isFavorite: row.isFavorite || false,
      livePhotoVideoId: row.livePhotoVideoId || undefined,
      duration: row.duration || undefined,
      localThumbPath: existing?.localThumbPath,
      localPreviewPath: existing?.localPreviewPath,
      syncState: 'CLOUD_ONLY',
      bucketId: bucketId,
      hasLocalOriginal: false,
      hasCloudOriginal: true,
    });
    this.assets.set(asset.id, asset);
    return asset;
  }

  public async apiRequest(path: string, method: http.RequestMethod = http.RequestMethod.GET, body?: string): Promise<string> {
    if (!this.currentServer.isConnected) {
      throw new Error('Please log in to perform this operation');
    }
    const request = http.createHttp();
    try {
      const headers = this.authHeaders();
      headers['Accept'] = 'application/json';
      if (body !== undefined) {
        headers['Content-Type'] = 'application/json';
      }
      const cleanPath = path.startsWith('/') ? path.substring(1) : path;
      const response = await request.request(`${this.currentServer.serverUrl}/api/${cleanPath}`, {
        method: method,
        header: headers,
        extraData: body,
        connectTimeout: 10000,
        readTimeout: 20000,
      });
      console.info(`[ImmichApi] API ${cleanPath}: HTTP ${response.responseCode}`);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error(`API error: HTTP ${response.responseCode}`);
      }
      return response.result as string;
    } catch (error) {
      throw new Error(formatApiError(error));
    } finally {
      request.destroy();
    }
  }

  public async toggleFavorite(assetId: string, isFavorite: boolean): Promise<boolean> {
    const asset = this.assets.get(assetId);
    await this.apiRequest(`assets/${encodeURIComponent(assetId)}`, http.RequestMethod.PUT, JSON.stringify({
      isFavorite: isFavorite
    }));
    if (asset) {
      asset.isFavorite = isFavorite;
    }
    return isFavorite;
  }

  public async trashAssets(assetIds: string[]): Promise<boolean> {
    if (assetIds.length === 0) {
      return true;
    }
    await this.apiRequest('assets', http.RequestMethod.DELETE, JSON.stringify({
      ids: assetIds
    }));
    for (const id of assetIds) {
      this.assets.delete(id);
    }
    return true;
  }

  public async addAssetsToAlbum(albumId: string, assetIds: string[]): Promise<boolean> {
    if (assetIds.length === 0) {
      return true;
    }
    await this.apiRequest(`albums/${encodeURIComponent(albumId)}/assets`, http.RequestMethod.PUT, JSON.stringify({
      ids: assetIds
    }));
    return true;
  }

  public async fetchAlbums(): Promise<AlbumItem[]> {
    const rows = parseAlbums(await this.apiRequest('albums'));
    const albums: AlbumItem[] = [];
    const updated: Map<string, AlbumItem> = new Map<string, AlbumItem>();
    for (const row of rows) {
      const album = new AlbumItem(row.id, row.albumName, '', row.assetCount, 'CLOUD',
        this.albums.get(row.id)?.isPinned || false, 0, row.assetCount);
      album.thumbnailAssetId = row.albumThumbnailAssetId || '';
      if (album.thumbnailAssetId) {
        album.coverAsset = new AssetItem({
          id: album.thumbnailAssetId, assetType: 'IMAGE', fileCreatedAt: '', syncState: 'CLOUD_ONLY',
        });
      }
      updated.set(album.id, album);
      albums.push(album);
    }
    this.albums = updated;
    console.info(`[ImmichApi] Loaded ${albums.length} server albums`);
    return albums;
  }

  public toggleAlbumPin(id: string): boolean {
    const album = this.albums.get(id);
    if (!album) {
      return false;
    }
    album.isPinned = !album.isPinned;
    return true;
  }

  public async fetchAlbumAssetsPage(albumId: string, page: number = 1, cursor?: string): Promise<AlbumAssetPage> {
    if (!albumId || !Number.isInteger(page) || page < 1) {
      throw new Error('Invalid album page request');
    }
    const body = cursor ? JSON.stringify({ albumIds: [albumId], size: 200, cursor: cursor, order: 'asc' }) :
      JSON.stringify({ albumIds: [albumId], size: 200, page: page, order: 'asc' });
    // Immich 3 album metadata no longer embeds assets; query by album with pagination.
    const result = parseAlbumAssetPage(await this.apiRequest('search/metadata', http.RequestMethod.POST, body));
    if ((result.nextPage !== undefined && result.nextPage <= page && !cursor) ||
      (cursor !== undefined && result.nextCursor === cursor)) {
      throw new Error('Server album pagination did not advance');
    }
    const assets: AssetItem[] = [];
    for (const row of result.items) {
      assets.push(this.assetFromDto(row));
    }
    console.info(`[ImmichApi] Loaded ${assets.length} album photos`);
    return { assets: assets, nextPage: result.nextPage, nextCursor: result.nextCursor };
  }

  /**
   * Build AccountInfo matching the connected server
   */
  public getAccountInfo(): AccountInfo {
    return new AccountInfo(
      'current-immich-server',
      this.currentServer.serverUrl,
      this.currentServer.userEmail,
      this.currentServer.userName,
      true,
      0
    );
  }
}
