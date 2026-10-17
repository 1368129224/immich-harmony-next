# Immich 原生鸿蒙客户端（HarmonyOS NEXT API 12+）实现方案与架构文档

> **协议声明与合规说明 (Clean-Room Implementation)**：  
> Immich 官方服务与移动端代码遵循 AGPLv3 许可协议。本项目为 **100% 净室实现 (Clean-Room Implementation)**，仅基于 Immich 官方公开 REST HTTP API 规范实现，**严禁**参考、复制或转译任何官方 Flutter/Dart 客户端源码。

---

## 目录
1. [项目全景架构](#1-项目全景架构)
2. [第一阶段：Rust 核心引擎 (`immich-core`) 深度剖析](#2-第一阶段rust-核心引擎-immich-core-深度剖析)
3. [Immich Server REST API 接口详细调研与兼容处理](#3-immich-server-rest-api-接口详细调研与兼容处理)
4. [第二阶段：鸿蒙 N-API 跨语言桥接 (`immich-ohos-napi`)](#4-第二阶段鸿蒙-n-api-跨语言桥接-immich-ohos-napi)
5. [双机协同开发与调试流程 (Linux 本机 + Win PC 模拟器)](#5-双机协同开发与调试流程-linux-本机--win-pc-模拟器)
6. [测试验证与基准测试报告](#6-测试验证与基准测试报告)
7. [第三阶段：鸿蒙原生 MVP App 实施规划](#7-第三阶段鸿蒙原生-mvp-app-实施规划)

---

## 1. 项目全景架构

系统采取“**Rust 高性能核心 + 极薄 N-API 胶水层 + ArkUI V2 纯原生界面**”的三层分层架构：

```
┌──────────────────────────────────────────────────────────────────┐
│             HarmonyOS NEXT 原生层 (ArkUI V2 / ArkTS)              │
│  - LoginPage.ets (登录鉴权与状态暂存)                               │
│  - TimelinePage.ets (时间桶无限滚动瀑布流 / 60-120fps 流畅滑动)        │
│  - AssetViewerPage.ets (大图手势平滑缩放、实况照片、胶片底部栏)         │
│  - ExifDrawer.ets (拍照参数/地理位置抽屉展示)                       │
│  - DebugOverlay.ets (交互弹簧阻尼参数微调悬浮窗)                    │
└─────────────────────────────────┬────────────────────────────────┘
                                  │ N-API (@kit.ArkUI / ohos-rs)
┌─────────────────────────────────▼────────────────────────────────┐
│           immich-ohos-napi (鸿蒙 N-API 边界封装层, <200 行)        │
│  - 纯简单类型与扁平 DTO 传递 (String, boolean, 扁平 JSON 字符串)     │
│  - 自动映射沙箱绝对路径 (file:/// 模式对齐)                         │
└─────────────────────────────────┬────────────────────────────────┘
                                  │ Rust Arc / Tokio
┌─────────────────────────────────▼────────────────────────────────┐
│                   immich-core (平台无关纯 Rust 核心)               │
│ ┌───────────────────────────┐  ┌───────────────────────────────┐ │
│ │ ImmichClient              │  │ DualModeAdapter               │ │
│ │ - reqwest (rustls-tls)    │  │ - 列式压缩/传统数组双轨适配   │ │
│ │ - 图片/视频沙箱原子下载   │  │ - TimeBucket 动态分页聚合     │ │
│ └─────────────┬─────────────┘  └───────────────┬───────────────┘ │
│               └──────────────┬─────────────────┘                 │
│                              │                                   │
│                 ┌────────────▼──────────────┐                    │
│                 │ DbEngine (rusqlite/bundled│                    │
│                 │ - 本地元数据离线缓存      │                    │
│                 │ - 零系统动态 C 库依赖     │                    │
│                 └───────────────────────────┘                    │
└──────────────────────────────────────────────────────────────────┘
```

---

## 2. 第一阶段：Rust 核心引擎 (`immich-core`) 深度剖析

### 2.1 零系统 C 库依赖决策 (Zero Dynamic C Library Dependency)
在 OpenHarmony / HarmonyOS NEXT 上，系统动态 C 运行时（musl libc）与标准 Linux (glibc) 存在环境差异，如果依赖动态链接的 OpenSSL 或 SQLite，极易导致 `.so` 载入时发生 `symbol lookup error` 崩溃。
- **TLS 解决方案**：`reqwest` 强制指定 `default-features = false`，仅启用 `rustls-tls`，基于纯 Rust 密码学套件实现 TLSv1.2 / TLSv1.3，杜绝任何 OpenSSL 链接。
- **SQLite 解决方案**：`rusqlite` 指定 `features = ["bundled"]`，构建阶段直接将原生 SQLite 源码静态编译进二进制中，消除外部 `libsqlite3.so` 依赖。

### 2.2 本地 SQLite 缓存与索引引擎 (`db.rs`)
本地缓存表结构专门针对相册时间线高频滑动检索优化：
- `server_config`: 存储当前登录的服务器地址、API Key 或 Access Token；
- `buckets`: 缓存时间桶列表及其数量计数；
- `assets`: 缓存图片/视频资产，包含完整文件创建时间、实况动图关联 ID、ThumbHash、沙箱缓存路径及完整的 EXIF 序列化字段。
- **高性能索引**：
  - `idx_assets_bucket`: 针对 `bucket_id` 的 B-Tree 索引，秒级定位当前时间桶的所有资产；
  - `idx_assets_created`: 针对 `file_created_at DESC` 的降序索引，支持跨时间段平滑分页。

### 2.3 原子级媒体沙箱下载机制 (`client.rs`)
针对缩略图（`size=thumbnail`）、高清预览图（`size=preview`）与实况视频（`videos`）：
1. 校验本地沙箱目标文件是否存在且字节数大于 0，存在直接命中缓存返回文件绝对路径；
2. 下载过程中首先写入带进程 PID 标识的 `.tmp` 临时文件；
3. 下载完成通过 `tokio::fs::rename` 完成**原子重命名**，杜绝 UI 渲染时读取到半截文件的破图现象；
4. 记录更新到 SQLite 数据库的 `local_thumb_path` / `local_preview_path` / `local_video_path` 字段。

---

## 3. Immich Server REST API 接口详细调研与兼容处理

通过对 Immich 公开 API 文档与多版本响应特征的深度梳理，Rust 核心已完备处理以下关键接口：

### 3.1 鉴权与服务健康检查
- **接口路径**：`GET /api/server-info/ping`（新版）/ `GET /api/server/version`（回退）
- **认证方式**：
  - Header: `x-api-key: <api_key>`
  - Header: `Authorization: Bearer <access_token>`
- **适配处理**：优先探测 `/api/server-info/ping`，若返回非 200 则自动回退到 `/api/server/version`，确保自建老版本 NAS 服务平滑连通。

### 3.2 时间桶接口 (`/api/timeline/buckets`)
- **多版本查询参数回退机制**：
  - **Modern 参数**（v1.106+）：`GET /api/timeline/buckets?visibility=timeline&withPartners=true`
  - **Legacy 参数**（旧版本）：`GET /api/timeline/buckets?size=MONTH&isArchived=false`
  - **容错逻辑**：客户端首先发起 Modern 请求，若服务端响应 HTTP 400 Bad Request，系统在 Rust 内部无感回退至 Legacy 参数重新请求。
- **返回结构**：
  ```json
  [
    { "timeBucket": "2024-03-01T00:00:00.000Z", "count": 128 },
    { "timeBucket": "2024-02-01T00:00:00.000Z", "count": 64 }
  ]
  ```

### 3.3 时间桶媒体详情接口 (`/api/timeline/bucket`)
这是 Immich 服务端性能优化的核心。新版采用了 Columnar（列式压缩）格式传输海量相片元数据，相比老版本节省超 70% 的 JSON 序列化体积与网络带宽：
- **现代列式格式 (Modern Columnar Format)**：
  ```json
  {
    "id": ["uuid-1", "uuid-2"],
    "type": ["IMAGE", "VIDEO"],
    "fileCreatedAt": ["2024-03-01T12:00:00.000Z", "2024-03-01T13:00:00.000Z"],
    "fileModifiedAt": [null, "2024-03-01T13:30:00.000Z"],
    "updatedAt": ["2024-03-01T12:00:00.000Z", null],
    "isFavorite": [true, false],
    "duration": [null, "0:00:15.000000"],
    "livePhotoVideoId": ["video-uuid-1", null],
    "thumbhash": ["thumbhash1", "thumbhash2"]
  }
  ```
- **传统对象数组格式 (Legacy Array Format)**：
  ```json
  [
    {
      "id": "uuid-legacy-1",
      "type": "IMAGE",
      "fileCreatedAt": "2024-03-01T12:00:00.000Z",
      "isFavorite": true,
      "livePhotoVideoId": "video-uuid-1",
      "exifInfo": { "make": "Sony", "model": "ILCE-7M4" }
    }
  ]
  ```
- **Rust 无感适配器设计 (`adapter.rs`)**：
  采用 Serde 的 `#[serde(untagged)]` 枚举 `RawBucketResponse`，在反序列化阶段自动嗅探 JSON 根节点是列式对象还是扁平数组，统一规整转换为高内聚的 `Vec<Asset>` 实体。

### 3.4 媒体缩略图与视频流接口
- **缩略图获取**：
  - 标准端点：`GET /api/assets/{id}/thumbnail?size=thumbnail` (小图) 或 `size=preview` (高清预览图)
  - 兼容回退：`GET /api/asset/thumbnail/{id}?size={size}` (旧版本格式)
- **视频与实况动图流**：
  - 标准端点：`GET /api/assets/{id}/video/playback`
  - 原画回退：`GET /api/assets/{id}/original`
- **EXIF 详情**：
  - 端点：`GET /api/assets/{id}`，提取其中的 `exifInfo` 结构体（相机型号、光圈、快门、ISO、焦距、拍摄地理位置等）。

---

## 4. 第二阶段：鸿蒙 N-API 跨语言桥接 (`immich-ohos-napi`)

### 4.1 桥接设计准则：极薄边界 (<200 行)
为了确保鸿蒙 ArkTS 与 Rust 之间调用零开销、零泄露：
1. **禁止复杂指针跨边界**：仅传递字符串、数字、布尔以及扁平 JSON 字符串；
2. **异步非阻塞**：除引擎初始化外，所有网络、磁盘 IO 与数据库接口均通过 `async fn` 暴露，在 Rust 侧利用 Tokio 运行时线程池执行，绝不卡死 ArkTS 主 UI 线程；
3. **全局单例保护**：使用 `RwLock<Option<Arc<ImmichCore>>>` 保护底层单例，杜绝空指针调用。

### 4.2 导出接口定义 (`index.d.ts`)
```typescript
export interface AssetViewerBundleDto {
  assetId: string;
  assetType: string;
  imagePath: string;
  videoPath?: string;
  isLivePhoto: boolean;
  duration?: string;
}

export interface ExifInfoDto {
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

export function initCoreEngine(dbDir: string, cacheDir: string): boolean;
export function loginServer(serverUrl: string, apiKey: string): Promise<string>;
export function syncAndGetBuckets(): Promise<string>;
export function fetchBucketAssetsJson(timeBucket: string): Promise<string>;
export function ensureAssetCached(assetId: string, mediaType: string): Promise<string>;
export function prepareAssetViewerBundle(assetId: string): Promise<AssetViewerBundleDto>;
export function getAssetExif(assetId: string): Promise<ExifInfoDto | null>;
```

---

## 5. 双机协同开发与调试流程 (Linux 本机 + Win PC 模拟器)

### 5.1 工作流分工
- **Linux NAS / 本机 (Rust 核心与交叉编译主控)**：
  - 编写、重构与单元测试 `crates/immich-core`；
  - 维护 `crates/immich-ohos-napi`；
  - 运行 `scripts/build_ohos_so.sh` 编译 `x86_64` (Win 模拟器) 与 `arm64-v8a` (真机) 的 `libimmich_ohos_napi.so`，提交到 git；
- **Windows PC (DevEco Studio UI 联调)**：
  - 从 git 检出最新工程；
  - DevEco Studio 导入 `harmony-app`；
  - 启动 x86_64 鸿蒙模拟器，运行调试。

### 5.2 模拟器与 Mock 沙箱机制
在 `harmony-app/entry/src/main/ets/bridge/AppBridge.ets` 中设置：
```typescript
public static USE_MOCK_BRIDGE: boolean = false; // 切换为 false 即连接真实的 Rust Native 核心
```
即使在没有配置 OpenHarmony NDK 的开发机上，前端工程师也可开启 `USE_MOCK_BRIDGE = true` 进行 UI 布局演练；一旦 `.so` 放置到位，切换开关即可进行真实数据流通。

---

## 6. 测试验证与基准测试报告

在本机执行 Rust 单元测试套件：
```bash
cargo test --package immich-core -- --nocapture
```

### 测试结果
```text
running 9 tests
test adapter::tests::test_parse_buckets_response ... ok
test adapter::tests::test_parse_legacy_array ... ok
test adapter::tests::test_parse_legacy_array_with_exif ... ok
test adapter::tests::test_parse_modern_columnar ... ok
test client::tests::test_url_encode ... ok
test client::tests::test_client_url_construction ... ok
test db::tests::test_db_config_and_schema ... ok
test db::tests::test_db_buckets_and_assets ... ok
test tests::test_core_engine_in_memory ... ok

test result: ok. 9 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
```

所有的列式反序列化、传统数组反序列化、EXIF 元数据提取、SQLite Schema 及索引初始化、以及 AssetViewerBundle 实况照片合成链路均通过严格的测试验证。

---

## 7. 第三阶段：鸿蒙原生 MVP App 实施规划

接下来进入 Windows PC 端的 DevEco Studio 联调阶段：

1. **页面流转接入**：
   - `LoginPage`: 输入 Immich 服务器地址（如 `https://immich.yourdomain.com`）与 API Key，调用 `AppBridge.loginServer(...)`；
   - `TimelinePage`: 载入时间桶，滑动触发按需批量下载缩略图（`AppBridge.ensureAssetCached(id, 'thumbnail')`），呈现原生相册瀑布流；
   - `AssetViewerPage`: 单击照片进入全屏查看器，调用 `AppBridge.prepareAssetViewerBundle(id)`，通过鸿蒙原生 `MovingPhotoView` 播放实况动图；
2. **手势体验调优**：
   - 唤出 `DebugOverlay`，滑动调节 `springResponse`（弹簧响应时间）与 `springDamping`（阻尼系数），实现与鸿蒙系统相册完全一致的手势拖拽阻尼感；
3. **EXIF 抽屉联动**：
   - 点击右上角 "Info" 按钮，调起 `ExifDrawer`，从底层 SQLite/网络拉取相机镜头参数与地理信息。
