# Immich iOS 原生客户端 (Native iOS App)

基于 Swift、SwiftUI、UIKit 和跨平台 Rust 核心（`crates/immich-core`）实现的高性能 Immich 原生 iOS 客户端。

## 架构设计

系统采用“**Rust 高性能核心 + C-FFI 桥接胶水层 + Swift/SwiftUI/UIKit 原生交互层**”的三层架构：

```text
┌──────────────────────────────────────────────────────────────────┐
│                   iOS 原生交互层 (Swift / SwiftUI / UIKit)       │
│  - AppDelegate.swift (UIHostingController 原生宿主入口)          │
│  - NativeImmichApp.swift (时间线瀑布流、双向手势、查看器交互)     │
│  - NativeFeatures.swift (相册网格、搜索、多源混合过滤)            │
│  - NativeLibrary.swift (库集合浏览)                               │
│  - NativeCachedTimelinePreview.swift (平滑时间线骨架预览)        │
│  - NativeCloudStatus.swift (多账号云端与本地同步状态匹配)        │
└─────────────────────────────────┬────────────────────────────────┘
                                  │ @_silgen_name / Bridging-Header
┌─────────────────────────────────▼────────────────────────────────┐
│           immich-ios-ffi (C-FFI 跨语言安全边界封装层)             │
│  - JSON Envelope 契约传递 ({success, data, error})               │
│  - 纯 C ABI 导出 (immich_ios_*) 与跨语言字符串安全生命周期释放    │
│  - Tokio 多线程运行时隔离与同步阻塞/异步调度                      │
└─────────────────────────────────┬────────────────────────────────┘
                                  │ Rust Arc / Tokio
┌─────────────────────────────────▼────────────────────────────────┐
│                   immich-core (平台无关纯 Rust 核心)             │
│  - ImmichClient (reqwest rustls-tls 网络与媒体缓存原子下载)      │
│  - DualModeAdapter (列式压缩与旧版对象数组双轨兼容解析)          │
│  - DbEngine (rusqlite/bundled 本地 SQLite 元数据持久缓存)        │
└──────────────────────────────────────────────────────────────────┘
```

## 客户端原生 UI 手势与交互特性

继承并深度打磨来自 `immich-z` 的全套手势体系：

1. **时间线网格缩放手势 (Pinch-to-Zoom)**：
   - 使用 `MagnificationGesture` 实现 2 列至 15 列无缝平滑缩放。
   - 带有 0.12 阻尼死区过滤，防止误触。
   - 步进时触发原生触感反馈（`UIImpactFeedbackGenerator(style: .medium)`）。
   - 自动计算并锁定屏幕中心可见照片（`centerVisibleAssetID`），缩放前后视觉焦点不偏移。

2. **连续框选手势 (Drag-to-Select)**：
   - 0.28s 长按激活多选模式，滑动时根据与网格项坐标交集批量选择。
   - 智能区分垂直浏览意图与横向/连续选择意图。

3. **大图查看器交互手势 (Unified Asset Viewer)**：
   - **交互式下拉下沉退出 (Swipe-to-Dismiss)**：配合弹性阻尼物理动画与缩放，平滑飞回时间线缩略图原位。
   - **上滑抽屉手势**：轻快上滑直接展开 EXIF 拍摄参数、机型镜头信息与地理位置地图。
   - **双击缩放 (Double-Tap to Zoom)**：UIKit `UIScrollView` 底层实现，双击以轻触点为中心在 1x 与 3x 之间平滑切换。
   - **实况照片长按播放 (Live Photo Press-and-Hold)**：长按触发震动反馈并播放动态视轨，抬手无缝恢复静态原图。
   - **底部胶片轮播手势 (Filmstrip Scrubber)**：拖动底部小图胶卷快速换图，带刻度触感微震动。

4. **全局辅助手势**：
   - 底栏照片 Tab 双击快速回顶/跳至底部最新照片。
   - 顶部与底部双向下拉/上拉刷新触发器（Bottom Pull-to-Refresh）。

## 工程结构

- `Runner.xcodeproj`：Xcode 原生工程，包含 `Runner` 主应用 target 与 `RunnerTests` 单元测试 target。
- `Runner/`：
  - `AppDelegate.swift`：应用生命周期与根视图加载。
  - `ImmichCoreBridge.swift`：Rust `immich-core` 的 Swift 桥接封装，支持 Native FFI 与 Mock 模式。
  - `immich_core_ffi.h` & `Runner-Bridging-Header.h`：C-FFI 头文件与 Objective-C 桥接头。
  - `NativeImmichApp.swift`：时间线核心界面与多功能大图查看器。
  - `NativeFeatures.swift`：设备相册、搜索、多源过滤面板。
  - `NativeCloudStatus.swift`：本地与服务端照片状态校验。
  - `NativeLibrary.swift`：共享库、探索合集。
  - `NativeCachedTimelinePreview.swift`：时间线预渲染占位层。
  - `Assets.xcassets`：全套 App 图标资源。
  - `libs/`：存放编译出的 Rust 静态库产物。
- `RunnerTests/`：原生 XCTest 测试套件，覆盖手势判定、时间线边界、缩略图缓存及 FFI Bridge 契约。

## 构建与测试

### 1. 编译 Rust iOS FFI 静态库

在仓库根目录下运行：

```bash
# 生成本地调试库或 iOS/模拟器静态库
bash scripts/build_ios_lib.sh release
```

- 在 macOS 上运行时，脚本会自动交叉编译 `aarch64-apple-ios`（真机）与 `aarch64-apple-ios-sim` / `x86_64-apple-ios`（模拟器），并通过 `lipo` 生成通用二进制静态库。
- 在 Linux / NAS 主机上运行时，会自动构建主机静态库并同步头文件至 `ios-app/Runner/`，供交叉测试验证。

### 2. 编译与运行 iOS App（macOS）

```bash
cd ios-app

# 构建未签名真机安装包
xcodebuild -project Runner.xcodeproj -scheme Runner \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

# 运行全套单元测试
xcodebuild -project Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## 合规说明

本项目严格遵守 `AGENTS.md` 的净室实现（Clean-Room Implementation）准则，仅使用 Immich 官方公开 REST HTTP API 规范，不包含任何第三方封闭运行时或官方 Flutter/Dart 客户端源码。
