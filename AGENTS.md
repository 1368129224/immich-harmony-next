# AGENTS.md — Immich HarmonyOS NEXT Native Client

## 1. Project Overview & Architecture
This repository contains a commercial-grade, clean-room native HarmonyOS NEXT (API 12+) client for **Immich**, built with a **Rust Cross-Platform Core (`immich-core`) + Thin N-API Bridge (`immich-ohos-napi`) + Pure ArkTS/ArkUI V2 (`harmony-app`)** architecture.

- **License Compliance (CRITICAL):** Immich official server/mobile is AGPLv3. This project is a **100% clean-room implementation** communicating strictly via HTTP REST APIs. **NEVER** copy, reference, or translate Dart/Flutter source code from the official Immich repository.
- **Dual-Machine Workflow:**
  - **Linux NAS (Backend & Core Host):** Develops and tests `crates/immich-core`, and runs `ohrs build` inside `crates/immich-ohos-napi` to cross-compile `.so` binaries (`x86_64` for Windows emulator, `arm64-v8a` for real device) and generate `index.d.ts`.
  - **Windows PC (UI & Emulator Host):** Runs DevEco Studio to develop and debug `harmony-app` using the Previewer and x86_64 HarmonyOS NEXT Emulator.

## 2. Directory Structure
~~~text
.
├── AGENTS.md                        # AI Agent constitution & workflow rules
├── Cargo.toml                       # Rust workspace manifest
├── .gitignore                       # Whitelists harmony-app/entry/libs/**/*.so for Git sync
├── .gitattributes                   # Enforces LF line endings across Linux NAS & Windows PC
├── scripts/
│   └── build_ohos_so.sh             # Linux NAS one-click N-API build & copy script
├── crates/
│   ├── immich-core/                 # Platform-agnostic Rust core (HTTP, Adapter, SQLite, Cache)
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── adapter.rs           # Dual-version API adapter (Columnar vs Legacy Array)
│   │       ├── client.rs            # Reqwest rustls HTTP client & thumbnail downloader
│   │       └── db.rs                # Bundled rusqlite local cache engine
│   └── immich-ohos-napi/            # Thin N-API FFI bridge (<200 lines, ohos-rs)
│       ├── Cargo.toml
│       ├── build.rs
│       └── src/lib.rs
└── harmony-app/                     # DevEco Studio project root (HarmonyOS NEXT API 12+)
    └── entry/
        ├── libs/                    # Prebuilt .so libraries synced via Git from Linux NAS
        └── src/main/ets/
            ├── bridge/AppBridge.ets # Toggleable Mock/Native bridge (USE_MOCK_BRIDGE)
            ├── models/AssetModels.ets # ArkUI V2 @ObservedV2 & @Trace models
            ├── pages/               # LoginPage, TimelinePage, AssetViewerPage
            └── components/          # FilmstripScrubber, ExifDrawer, DebugOverlay
~~~

## 3. Mandatory Verification Loops (Self-Healing Rules)
1. **Rust Core Check & Test (Linux NAS):**
   After modifying any file in `crates/immich-core`, ALWAYS run:
   ~~~bash
   cargo test --package immich-core -- --nocapture
   ~~~
2. **HarmonyOS N-API Cross-Compile (Linux NAS):**
   After `immich-core` tests pass, build the `.so` binaries for Windows emulator (`x64`) and real device (`arm64`):
   ~~~bash
   bash scripts/build_ohos_so.sh
   ~~~
3. **UI Sandbox First (Windows DevEco Studio):**
   Keep `AppBridge.USE_MOCK_BRIDGE = true` in `harmony-app/entry/src/main/ets/bridge/AppBridge.ets` when iterating on UI layout or gestures. Expose spring/damping gesture parameters (`springResponse`, `springDamping`, `dismissThresholdVp`) to an on-screen `DebugOverlay` slider panel instead of guessing magic numbers.

## 4. Strict Technical Guardrails (Anti-Hallucination)
- **Pure Rust TLS & Bundled SQLite:** In `crates/immich-core/Cargo.toml`, ALWAYS use `reqwest` with `default-features = false, features = ["json", "rustls-tls", "stream", "gzip"]` and `rusqlite` with `features = ["bundled"]`. **NEVER** introduce `openssl-sys` or system C library dependencies that break OpenHarmony cross-compilation.
- **Thin FFI Boundary:** Across `immich-ohos-napi`, ONLY pass primitive types (`String`, `i64`, `f64`, `bool`) or flat `#[napi(object)]` structs (`init_core_engine`, `login_server`, `sync_and_get_buckets`, `fetch_bucket_assets_json`, `ensure_asset_cached`, `prepare_asset_viewer_bundle`).
- **Sandbox File Path Delivery for Media:** Rust `immich-core` MUST download thumbnails (`size=thumbnail`), preview images (`size=preview`), and live-photo videos into the HarmonyOS app sandbox `cacheDir`, returning local file paths to ArkTS.
- **Multi-Version Immich API Compatibility:** Route `/api/timeline/bucket` responses through an untagged enum `RawBucketResponse` (`#[serde(untagged)]`) supporting both modern columnar `{ id: [...], type: [...] }` and legacy object array `[{ id, type, ... }]`. Automatically fall back from `visibility=timeline&withPartners=true` to `size=MONTH&isArchived=false` on HTTP 400.
- **HarmonyOS NEXT ArkUI V2 Only:**
  - Use `@ComponentV2`, `@ObservedV2`, `@Trace`, `@Local`, `@Param`, `@Event`. Never mix legacy V1 `@State` or `@Prop` inside `@ComponentV2`.
  - Use modular `@kit.*` imports ONLY (`@kit.MediaLibraryKit`, `@kit.CoreFileKit`, `@kit.ArkUI`).
  - Synthesize Live Photos natively via `fileUri.getUriFromPath(sandboxPath)` and `await movingPhotoManager.createMovingPhoto(imageUri, videoUri)` rendered inside `MovingPhotoView`.

## 5. Progress & Dynamic Agent Notes (Append-Only Zone)
<!-- Agent: Append discovered server quirks, completed milestones, or schema migrations below this line. Do not delete sections 1-4. -->
- [Init] Architecture specification locked. Ready to scaffold workspace crates and run initial unit tests.
- [Milestone] Workspace crates and HarmonyOS project structure created.
  - `crates/immich-core`: Dual-version adapter (columnar vs legacy), bundled rusqlite engine, pure rustls reqwest client, sandbox path cache delivery. All 8 unit tests passed.
  - `crates/immich-ohos-napi`: Thin N-API bridge (<200 lines) with flat DTO boundary and primitive types via `ohos-rs`.
  - `scripts/build_ohos_so.sh`: Cross-compilation and automated binary sync script configured.
  - `harmony-app`: ArkUI V2 models (`@ObservedV2`, `@Trace`), toggleable `AppBridge` (`USE_MOCK_BRIDGE = true`), pages (`LoginPage`, `TimelinePage`, `AssetViewerPage`), and components (`DebugOverlay`, `FilmstripScrubber`, `ExifDrawer`).
- [Documentation] `docs/` is consolidated into three maintained documents. Before implementation, read [Development Rules](docs/DEVELOPMENT_RULES.md), then [Agent Design Specification](docs/AGENT_DESIGN_SPEC.md); the human-facing summary is [Product & UI Overview](docs/PRODUCT_UI_OVERVIEW.md). The design specification distinguishes confirmed requirements, current implementation, and pending validation. iOS now has a native project and C-FFI bridge; earlier milestone notes above remain historical.
- [iOS] `ios-app/Runner.xcodeproj`: SwiftUI/UIKit + PhotoKit; `crates/immich-ios-ffi` bridges `immich-core` through `ImmichCoreBridge.swift`. Free Rust-returned strings with `immich_ios_free_string`; keep blocking FFI/IO off the UI thread.
- [iOS Verification] Run `python3 scripts/check_native_ios.py` and `python3 -m unittest discover -s scripts -p 'test_*.py'`; FFI changes also require `cargo test` and `bash scripts/build_ios_lib.sh release`. Xcode builds/tests require macOS (`.github/workflows/build-ios.yml`); Linux checks do not prove device behavior.


