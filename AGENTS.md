# AGENTS.md — Immich 原生多端客户端指南

## 1. 项目概览与架构
本仓库为 **Immich** 的商用级原生客户端（支持 HarmonyOS NEXT API 12+ 与 iOS 15+），采用 **跨平台 Rust 核心 (`immich-core`) + 轻量 FFI 桥接 + 纯原生 UI** 架构。

- **开源许可合规（极其重要）：** Immich 官方客户端为 AGPLv3。本项目为 **100% 洁室净室实现**，仅通过 HTTP REST API 通信。**严禁** 复制、参考或翻译官方 Flutter/Dart 源码。
- **跨平台分工：**
  - **Linux NAS（后端与核心）：** 开发测试 `immich-core`，执行 `immich-ohos-napi` 交叉编译生成 `.so`，执行 `immich-ios-ffi` 构建，监控 GitHub Actions CI 及更新本地 LiveContainer IPA 源。
  - **Windows PC（鸿蒙 UI 与模拟器）：** 使用 DevEco Studio 开发调试 `harmony-app`。
  - **MacBook（iOS 构建与真机）：** 执行 Xcode 编译、XCTest、签名与真机安装。

## 2. 目录结构
~~~text
.
├── AGENTS.md                        # AI Agent 行为准则与工作流
├── Cargo.toml                       # Rust workspace 配置
├── scripts/                         # 跨平台构建、检查与发布脚本
├── crates/
│   ├── immich-core/                 # 平台无关 Rust 核心（HTTP、缓存、SQLite、API 适配）
│   ├── immich-ohos-napi/            # 鸿蒙 N-API 桥接
│   └── immich-ios-ffi/              # iOS C-FFI 桥接
├── harmony-app/                     # HarmonyOS NEXT 原生工程 (ArkUI V2)
└── ios-app/                         # iOS 原生工程 (SwiftUI / PhotoKit)
~~~

## 3. 必须执行的验证循环 (Mandatory Verification Loops)
1. **Rust 核心测试：**
   修改 `crates/` 后必须执行：
   ~~~bash
   ~/.cargo/bin/cargo test --workspace
   ~~~
2. **鸿蒙 N-API 编译：**
   `immich-core` 验证通过后，为模拟器 (`x86_64`) 与真机 (`arm64`) 编译 `.so`：
   ~~~bash
   bash scripts/build_ohos_so.sh
   ~~~
3. **iOS 本地合规检查：**
   修改 iOS 源码后在 Linux NAS 执行：
   ~~~bash
   python3 scripts/check_native_ios.py
   ~~~
4. **鸿蒙 UI 优先沙箱调试：**
   在 `harmony-app/.../AppBridge.ets` 中保持 `USE_MOCK_BRIDGE = true` 进行快速手势调优。
5. **推送后 CI 监控与 LiveContainer 源刷新（必须）：**
   `git push` 后须等待 GitHub Actions 编译，若编译失败须修复直到编译成功；编译成功后运行 `bash scripts/update_livecontainer_ipa.sh` 拉取并刷新 LiveContainer 源。

## 4. 技术规范与红线 (Technical Guardrails)
- **纯 Rust TLS 与内置 SQLite：** `immich-core` 必须使用 pure rustls (`default-features = false, features = ["json", "rustls-tls", "stream", "gzip"]`) 与 bundled rusqlite，严禁引入 `openssl-sys`。
- **轻量 FFI 边界：** FFI 接口仅传递基本类型 (`String`, `i64`, `bool` 等) 或扁平结构体；iOS 端必须调用 `immich_ios_free_string` 释放 Rust 导出的 C 字符串；耗时 IO 与 FFI 调用严禁阻塞主线程。
- **沙箱路径传递：** 缩略图、预览图和实况视频缓存在写入沙箱后返回本地路径供 UI 渲染。
- **多版本 API 兼容：** 时间线桶响应支持现代 Columnar 与旧版对象数组自动降级解析。
- **ArkUI V2 规范：** 仅使用 `@ComponentV2`、`@ObservedV2`、`@Trace`、`@Local`，模块化引入 `@kit.*`。

## 5. 进度与备忘 (Append-Only Zone)
<!-- Agent: 追加发现的服务端特性、已完成里程碑或架构变更 -->
- [Init] 架构设计确定，创建核心工程与基础测试。
- [Milestone] 核心 crates 与鸿蒙工程搭建完成，双版本适配器与 SQLite 缓存就绪。
- [Documentation] 文档归拢为三份核心规范：[开发行为规范](docs/DEVELOPMENT_RULES.md)、[Agent 详细设计规范](docs/AGENT_DESIGN_SPEC.md) 与 [功能与 UI 设计简案](docs/PRODUCT_UI_OVERVIEW.md)。
- [iOS] `ios-app`: 原生 SwiftUI/UIKit + PhotoKit，经 `immich-ios-ffi` 连接 Rust 核心；CI 产出无签名 IPA。
- [iOS Verification] Linux 端运行 `python3 scripts/check_native_ios.py`；push 后自动触发 CI 构建并更新 LiveContainer 源。
