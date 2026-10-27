# Android App

Android 原生客户端预留目录。目前仅建立目录与说明，尚未创建 Gradle 工程或实现平台桥接。

## 建议技术方向（待确认）

- Kotlin + Jetpack Compose，使用 Material 设计规范并按需定制品牌样式。
- 复用 `../crates/immich-core` 的平台无关业务逻辑；另行设计 Kotlin 可调用的 FFI / JNI，不直接使用鸿蒙 N-API 桥接。
- 照片库授权、系统分享、凭据安全存储及后台任务由 Android 平台层负责，适配系统版本与设备后台执行限制。
- 后续创建工程时明确 SDK、Android Gradle Plugin、Kotlin 与 NDK 版本。

## 产品与设计

开发前阅读 [开发行为规范](../docs/DEVELOPMENT_RULES.md) 与 [Agent 详细设计规范](../docs/AGENT_DESIGN_SPEC.md)：统一产品语义与品牌，适配平台原生操作习惯。产品概览见 [功能与 UI 设计简案](../docs/PRODUCT_UI_OVERVIEW.md)。

## 合规

遵循根目录 `AGENTS.md` 的 clean-room 约束，仅通过公开 REST API 对接 Immich，不参考、复制或转译官方 Flutter/Dart 客户端源码。
