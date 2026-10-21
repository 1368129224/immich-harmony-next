// Run with Node.js 24+: node --test scripts/test_timeline.cjs
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { stripTypeScriptTypes } = require('node:module');
const vm = require('node:vm');
const { parseTimelineAssets } = require('../harmony-app/entry/src/main/ets/services/TimelineAdapter.ts');
const { formatApiError } = require('../harmony-app/entry/src/main/ets/services/ApiErrors.ts');
const albumSource = readFileSync(require('node:path').join(__dirname, '../harmony-app/entry/src/main/ets/services/AlbumAdapter.ts'), 'utf8')
  .replace(/^import .*;\r?$/gm, '').replace(/^export /gm, '');
const { parseAlbums, parseAlbumAssetPage } = vm.runInNewContext(
  `${stripTypeScriptTypes(albumSource)}\n({parseAlbums, parseAlbumAssetPage});`, { parseTimelineAssets });

const legacy = [{ id: 'one', type: 'IMAGE', fileCreatedAt: '2026-01-01', isFavorite: true }];
test('legacy asset array stays compatible', () => {
  assert.deepEqual(parseTimelineAssets(JSON.stringify(legacy)), legacy);
});
test('modern columns become asset rows', () => {
  const rows = parseTimelineAssets(JSON.stringify({
    id: ['one', 'two'], type: ['IMAGE', 'VIDEO'], localDateTime: ['2026-01-01', '2026-01-02'],
    isFavorite: [true, false], livePhotoVideoId: [null, 'live-id'], duration: [null, '00:10'],
  }));
  assert.equal(rows.length, 2);
  assert.equal(rows[0].fileCreatedAt, '2026-01-01');
  assert.equal(rows[1].type, 'VIDEO');
  assert.equal(rows[1].livePhotoVideoId, 'live-id');
  assert.equal(rows[1].duration, '00:10');
});
test('missing column values use safe defaults', () => {
  const [row] = parseTimelineAssets('{"id":["one"]}');
  assert.equal(row.type, 'IMAGE');
  assert.equal(row.isFavorite, false);
});
test('empty libraries remain empty', () => {
  assert.deepEqual(parseTimelineAssets('[]'), []);
  assert.deepEqual(parseTimelineAssets('{"id":[]}'), []);
});
test('malformed server data surfaces as an error', () => {
  for (const value of ['null', '{}', '[{}]', '{"id":[null]}', 'invalid']) {
    assert.throws(() => parseTimelineAssets(value));
  }
});

// Run the actual service methods with in-memory HTTP/filesystem boundaries.
// No credentials, real server requests, or device media are read by these tests.
function serviceHarness(responses) {
  const calls = [];
  const files = new Map();
  const descriptors = new Map();
  const directories = new Set();
  let nextFd = 0;
  let active = 0;
  let maxActive = 0;
  const http = {
    RequestMethod: { GET: 'GET', POST: 'POST' }, HttpDataType: { ARRAY_BUFFER: 'buffer' },
    createHttp: () => ({
      async request(url, options) {
        calls.push({ url, options });
        active++; maxActive = Math.max(active, maxActive);
        await new Promise(resolve => setImmediate(resolve));
        active--;
        const response = responses.shift();
        if (!response) throw new Error('Unexpected HTTP request');
        if (response.failure) throw response.failure;
        return response;
      },
      destroy() {},
    }),
  };
  const fs = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    accessSync: path => files.has(path) || directories.has(path),
    mkdirSync(path) {
      if (directories.has(path)) throw { code: 13900015, message: 'File exists' };
      directories.add(path);
    },
    openSync(path) { const fd = ++nextFd; descriptors.set(fd, path); return { fd }; },
    writeSync(fd, buffer) { files.set(descriptors.get(fd), buffer); return buffer.byteLength; },
    closeSync() {},
    renameSync(from, to) { files.set(to, files.get(from)); files.delete(from); },
  };
  const source = readFileSync(require('node:path').join(__dirname, '../harmony-app/entry/src/main/ets/services/ImmichApiService.ets'), 'utf8')
    .replace(/^import .*;\r?$/gm, '').replace(/^export /gm, '');
  const js = stripTypeScriptTypes(source);
  const context = { http, fs, fileUri: { getUriFromPath: p => `file://${p}` }, parseTimelineAssets, formatApiError, parseAlbums, parseAlbumAssetPage,
    AlbumItem: class {
      constructor(id, name, coverUri, count, source, isPinned, localCount, cloudCount) {
        Object.assign(this, { id, name, coverUri, count, source, isPinned, localCount, cloudCount });
      }
    },
    AssetItem: class { constructor(data) { Object.assign(this, data); } },
    TimeBucketItem: class { constructor(timeBucket, count) { this.timeBucket = timeBucket; this.count = count; } },
    AccountInfo: class {}, console: { info() {}, warn() {}, error() {} },
  };
  vm.createContext(context);
  const service = vm.runInContext(`${js}\nImmichApiService.getInstance();`, context);
  service.currentServer = { serverUrl: 'https://example.invalid', accessToken: 'test-token', apiKey: '', userEmail: 'test@example.invalid', isConnected: true };
  service.setCacheDir('/sandbox/cache');
  return { service, calls, files, maxActive: () => maxActive };
}
function json(body, status = 200) { return { responseCode: status, result: JSON.stringify(body) }; }

test('timeline sends Bearer header and parses modern columns', async () => {
  const h = serviceHarness([json({ id: ['one'], type: ['IMAGE'] })]);
  const assets = await h.service.fetchBucketAssets('2026-01-01');
  assert.equal(assets.length, 1);
  assert.equal(h.calls[0].options.header.Authorization, 'Bearer test-token');
  assert.match(h.calls[0].url, /visibility=timeline&withPartners=true/);
  assert.equal(assets[0].localThumbPath, undefined);
  assert.ok(!h.calls[0].url.includes('test-token'));
});
test('HTTP 400 alone triggers legacy query fallback', async () => {
  const h = serviceHarness([json({}, 400), json(legacy)]);
  assert.equal((await h.service.fetchBucketAssets('2026-01-01')).length, 1);
  assert.match(h.calls[1].url, /size=MONTH&isArchived=false/);
});
test('HTTP 401 surfaces, never silently becomes sample photos', async () => {
  const h = serviceHarness([json({}, 401)]);
  await assert.rejects(h.service.fetchTimelineBuckets(), /HTTP 401/);
  assert.equal(h.calls.length, 1);
});
test('empty timeline returns zero buckets', async () => {
  const h = serviceHarness([json([])]);
  assert.equal((await h.service.fetchTimelineBuckets()).length, 0);
});
test('thumbnails use authenticated binary requests and sandbox URIs', async () => {
  const h = serviceHarness([{ responseCode: 200, result: new ArrayBuffer(8) }]);
  const uri = await h.service.cacheAssetImage('asset-one');
  assert.match(uri, /^file:\/\/\/sandbox\/cache\/immich-media\//);
  assert.equal(h.calls[0].options.header.Authorization, 'Bearer test-token');
  assert.equal(h.calls[0].options.expectDataType, 'buffer');
  assert.ok(!uri.includes('test-token'));
  assert.equal(h.files.size, 1);
  assert.equal(await h.service.cacheAssetImage('asset-one'), uri);
  assert.equal(h.calls.length, 1);
});
test('duplicate downloads coalesce; global concurrency is at most four', async () => {
  const h = serviceHarness(Array.from({ length: 9 }, () => ({ responseCode: 200, result: new ArrayBuffer(8) })));
  const uris = await Promise.all([h.service.cacheAssetImage('same'), h.service.cacheAssetImage('same'),
    ...Array.from({ length: 8 }, (_, i) => h.service.cacheAssetImage(`asset-${i}`))]);
  assert.equal(uris[0], uris[1]);
  assert.equal(h.calls.length, 9);
  assert.ok(h.maxActive() <= 4);
});
test('failed image downloads can retry and do not poison cache', async () => {
  const h = serviceHarness([json({}, 401), { responseCode: 200, result: new ArrayBuffer(8) }]);
  await assert.rejects(h.service.cacheAssetImage('one'), /HTTP 401/);
  assert.equal(h.files.size, 0);
  assert.equal(h.calls.length, 1);
  await h.service.cacheAssetImage('one');
  assert.equal(h.calls.length, 2);
});
test('unavailable thumbnail endpoints fall back to the legacy path', async () => {
  for (const status of [404, 405]) {
    const h = serviceHarness([json({}, status), { responseCode: 200, result: new ArrayBuffer(8) }]);
    await h.service.cacheAssetImage('one');
    assert.equal(h.calls.length, 2);
    assert.match(h.calls[1].url, /\/api\/asset\/thumbnail\/one\?size=thumbnail$/);
    assert.equal(h.files.size, 1);
  }
});
test('existing sandbox directory does not break the second thumbnail', async () => {
  const h = serviceHarness(Array.from({ length: 2 }, () => ({ responseCode: 200, result: new ArrayBuffer(8) })));
  await h.service.cacheAssetImage('one');
  await h.service.cacheAssetImage('two');
  assert.equal(h.files.size, 2);
});
test('HarmonyOS BusinessError retains diagnostic codes instead of object Object', () => {
  assert.match(formatApiError({ code: 2300006, message: 'resolve failed' }), /无法解析服务器域名（2300006）/);
  assert.match(formatApiError({ code: 2300007 }), /无法连接/);
  assert.match(formatApiError({ code: 2300028 }), /超时/);
  assert.match(formatApiError({ code: 2300060 }), /证书/);
  assert.equal(formatApiError(new Error('HTTP 401')), 'HTTP 401');
});
test('device DNS failure remains identifiable through password login', async () => {
  const h = serviceHarness([{ failure: { code: 2300006, message: 'resolve failed' } }]);
  await assert.rejects(h.service.loginWithPassword('https://example.invalid', 'user@example.invalid', 'synthetic-test-password'), /2300006/);
});
test('API Key session uses x-api-key for media', async () => {
  const h = serviceHarness([{ responseCode: 200, result: new ArrayBuffer(8) }]);
  h.service.currentServer.accessToken = undefined;
  h.service.currentServer.apiKey = 'test-key';
  await h.service.cacheAssetImage('one', 'preview');
  assert.equal(h.calls[0].options.header['x-api-key'], 'test-key');
  assert.ok(!h.calls[0].url.includes('test-key'));
});

const albumFixture = [{ id: 'album-one', albumName: 'Test Album', albumThumbnailAssetId: 'cover-one', assetCount: 12527 }];
test('server albums map real names, counts and authenticated cover assets', async () => {
  const h = serviceHarness([json(albumFixture)]);
  const [album] = await h.service.fetchAlbums();
  assert.equal(album.id, 'album-one');
  assert.equal(album.name, 'Test Album');
  assert.equal(album.count, 12527);
  assert.equal(album.source, 'CLOUD');
  assert.equal(album.coverUri, '');
  assert.equal(album.coverAsset.id, 'cover-one');
  assert.equal(h.calls[0].options.header.Authorization, 'Bearer test-token');
  assert.match(h.calls[0].url, /\/api\/albums$/);
});
test('empty server albums stay empty and coverless albums have no sample cover', async () => {
  const h = serviceHarness([json([]), json([{ ...albumFixture[0], albumThumbnailAssetId: null }])]);
  assert.equal((await h.service.fetchAlbums()).length, 0);
  assert.equal((await h.service.fetchAlbums())[0].coverAsset, undefined);
});
test('server album pin preference survives list refresh within current session', async () => {
  const h = serviceHarness([json(albumFixture), json(albumFixture)]);
  await h.service.fetchAlbums();
  assert.equal(h.service.toggleAlbumPin('album-one'), true);
  assert.equal((await h.service.fetchAlbums())[0].isPinned, true);
});
test('album authorization failures surface instead of returning mock albums', async () => {
  const h = serviceHarness([json({}, 403)]);
  await assert.rejects(h.service.fetchAlbums(), /HTTP 403/);
});
test('album photos are paginated by album filter, not embedded album metadata', async () => {
  const h = serviceHarness([json({ assets: { items: legacy, nextPage: '2', nextCursor: null } }),
    json({ assets: { items: [{ id: 'two', type: 'VIDEO' }], nextPage: null, nextCursor: null } })]);
  const first = await h.service.fetchAlbumAssetsPage('album-one');
  assert.equal(first.assets.length, 1);
  assert.equal(first.nextPage, 2);
  assert.equal(h.service.getAsset('one').id, 'one');
  let body = JSON.parse(h.calls[0].options.extraData);
  assert.deepEqual(body.albumIds, ['album-one']);
  assert.equal(body.size, 200);
  assert.equal(body.page, 1);
  assert.equal(h.calls[0].options.method, 'POST');
  assert.match(h.calls[0].url, /\/search\/metadata$/);
  const last = await h.service.fetchAlbumAssetsPage('album-one', first.nextPage);
  assert.equal(last.nextPage, undefined);
  assert.equal(last.assets[0].assetType, 'VIDEO');
  body = JSON.parse(h.calls[1].options.extraData);
  assert.equal(body.page, 2);
});
test('cursor pagination is forwarded without mixing page numbers', async () => {
  const h = serviceHarness([json({ assets: { items: legacy, nextCursor: 'next', nextPage: null } })]);
  const page = await h.service.fetchAlbumAssetsPage('album-one', 1, 'previous');
  assert.equal(page.nextCursor, 'next');
  const body = JSON.parse(h.calls[0].options.extraData);
  assert.equal(body.cursor, 'previous');
  assert.equal(body.page, undefined);
});
test('invalid album responses and nonadvancing pagination fail visibly', async () => {
  for (const bad of ['null', '{}', '[{}]']) assert.throws(() => parseAlbums(bad));
  for (const bad of ['{}', '{"assets":{"items":[],"nextPage":2}}', '{"assets":{"items":[],"nextPage":"oops"}}']) {
    assert.throws(() => parseAlbumAssetPage(bad));
  }
  const h = serviceHarness([json({ assets: { items: legacy, nextPage: 1 } })]);
  await assert.rejects(h.service.fetchAlbumAssetsPage('album-one'), /没有前进/);
});
