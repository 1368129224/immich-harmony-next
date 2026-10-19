# iOS App

iOS 原生客户端预留目录。目前仅建立目录与说明，尚未创建 Xcode 工程或实现平台桥接。

## 建议技术方向（待确认）

- Swift + SwiftUI；高密度照片网格、复杂手势等性能敏感区域按需使用 UIKit。
- 复用 `../crates/immich-core` 的平台无关业务逻辑；另行设计 Swift 可调用的 FFI，不直接使用鸿蒙 N-API 桥接。
- 照片库授权、系统分享、凭据安全存储及后台任务由 iOS 平台层负责，后台执行遵守系统调度限制。
- Xcode 工程构建、模拟器运行及签名需要 macOS / Xcode。

## 产品与设计

遵循 [跨平台 UI 与交互策略](../docs/CROSS_PLATFORM_UX_STRATEGY.md)：统一产品语义与品牌，适配平台原生操作习惯。

## 合规

遵循根目录 `AGENTS.md` 的 clean-room 约束，仅通过公开 REST API 对接 Immich，不参考、复制或转译官方 Flutter/Dart 客户端源码。
