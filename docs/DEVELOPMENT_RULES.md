# 开发行为规范

## 1. 三份文档的职责与阅读顺序

| 文档 | 读者与用途 |
| --- | --- |
| [开发行为规范](DEVELOPMENT_RULES.md)（本文） | 开发者、Agent：合规、职责边界、协作、验证与交付要求 |
| [Agent 详细设计规范](AGENT_DESIGN_SPEC.md) | Agent、工程师：产品契约、状态模型、平台约束、验收及设计差距 |
| [功能与 UI 设计简案](PRODUCT_UI_OVERVIEW.md) | 产品负责人、普通读者：功能范围、页面结构与主要交互 |

开始任务先读根目录 `AGENTS.md` 与本文，再按详细规范定位需求。人类讨论产品可先读简案。根目录 `AGENTS.md` 仍是执行入口，不因整理 `docs/` 被删除。

- 用户最新明确决策优先于旧建议；发生实质冲突时说明冲突，不自行扩大产品范围。
- 详细规范是产品规则的统一维护位置；简案保持简短，不复制全部技术条款。
- “已确认设计”“已有代码路径”“已在目标设备验收”是三种不同状态。不能由界面入口、静态检查或 Mock 推导功能已完成。
- 未决事项保持待定，不把调研建议和早期方案当成新要求。

## 2. Clean-room 与安全底线

1. Immich 官方客户端为 AGPLv3。本项目仅依据公开 REST API、公开产品 / 平台文档及可见界面独立实现，可参考immich官方在GitHub开源的代码中的设计思路和逻辑，自行进行实现；严禁直接转译官方 `mobile/` Flutter / Dart 业务源码。
2. 不静默上传原件、创建公开链接、扩大备份范围或把媒体转交第三方分析 / 中转服务。
3. 密码、Token、API Key 不进入日志、普通配置、截图或提交；凭据使用平台安全存储。保存登录历史不等于同意保存密码。
4. TLS 保留证书与主机名校验；不得为解决自签证书、模拟器或 IPv6 问题关闭校验。HTTP 与证书信任策略须明确告知风险并按目标系统验证。
5. 删除、系统图库写入、缓存清理、共享权限是独立操作，必须准确表达范围并检查实际结果。权限未知和网络失败不能当成资产不存在。
6. 不因查看共享媒体的权限而授予删除他人原件的能力；危险操作不静默回退为影响更大的操作。

## 3. 架构与实现职责

采用 **平台无关 Rust 核心 + 薄桥接 + 平台原生 UI**：

- `crates/immich-core/`：HTTP、Immich 多版本 Schema / 参数 / 能力适配、数据库、媒体缓存及可复用业务规则。
- `crates/immich-ohos-napi/`：HarmonyOS 的薄 N-API 边界，仅传基本类型、扁平 DTO / JSON；不承载页面逻辑。
- `crates/immich-ios-ffi/`：iOS C ABI 与 JSON 响应封装；明确指针、字符串释放、错误、并发和生命周期契约。
- `harmony-app/`：ArkTS / ArkUI V2。`@ComponentV2` 内使用 `@Local`、`@Param`、`@Event` 等 V2 能力，不混用 V1 `@State` / `@Prop`；模块导入采用 `@kit.*`。
- `ios-app/`：Swift / SwiftUI / UIKit；PhotoKit、系统分享、安全存储、后台调度和原生手势留在平台层。
- `android-app/`：当前为规划入口，Kotlin / Compose 与独立桥接为建议，不把目录存在视为客户端已交付。

工程约束：

- `reqwest` 使用 `default-features = false` 与 `json`、`rustls-tls`、`stream`、`gzip`；`rusqlite` 使用 `bundled`。禁止引入 `openssl-sys` 或依赖系统动态 SQLite 等破坏交叉编译的依赖。
- N-API 保持极薄，遵守根目录对规模和类型的限制；避免复杂 OS / UI 类型跨 FFI。
- 网络、磁盘和数据库工作不阻塞 UI 主线程。C ABI 即使是同步调用，也必须从平台合适的后台执行环境调用。
- Immich 版本差异最终集中在 Rust；现有 Swift 直连 API 是迁移现状，不是继续复制三套版本分支的许可。
- 缩略图、预览和实况视频缓存写入沙箱后返回本地路径；原件保存至系统图库须走另一个经过授权的流程。
- 功能判断采用“支持 / 不支持 / 未知”，区分权限不足、配置关闭和接口不存在。

## 4. 多机协作

| 环境 | 主要职责 |
| --- | --- |
| Linux NAS | Rust 开发 / 测试、服务端脚本、HarmonyOS `.so` 交叉编译、长期后台任务 |
| Windows + DevEco Studio | HarmonyOS UI、Previewer、x86_64 模拟器和 Windows 原生验证 |
| macOS + Xcode / macOS CI | iOS SDK 编译、模拟器 XCTest、签名 / 打包及真机验证 |

- HarmonyOS 构建同步 x86_64 模拟器与 arm64 真机 `.so` 及类型声明；使用 `scripts/build_ohos_so.sh`。
- UI 布局和手势迭代先使用 `AppBridge.USE_MOCK_BRIDGE = true`；接入真实数据再单独验证，不以 Mock 登录成功证明认证成功。
- 鸿蒙将 `springResponse`、`springDamping`、`dismissThresholdVp` 等调参暴露到 `DebugOverlay`，不凭感觉写死跨平台参数。
- 跨设备任务按能力协作；Linux 静态检查不能替代 Xcode / DevEco 编译和真机交互验收。

## 5. 必须执行的验证

### 5.1 Rust 与桥接

修改 `crates/immich-core` 后执行：

```bash
export PATH="$HOME/.cargo/bin:$PATH"
cargo test --package immich-core -- --nocapture
bash scripts/build_ohos_so.sh
```

全工作区回归与 iOS 桥接构建：

```bash
cargo test
bash scripts/build_ios_lib.sh release
```

构建产物与平台由脚本和宿主工具链决定。Linux 上生成主机库并不等于生成可运行的 iOS 真机库；iOS 目标编译需要 Apple 工具链。

### 5.2 UI 与脚本

```bash
python3 scripts/check_native_ios.py
git diff --check
```

按变更范围选择相关检查，并明确报告没运行的检查。

macOS 上的 iOS 示例：

```bash
cd ios-app
xcodebuild -project Runner.xcodeproj -scheme Runner \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
# Simulator 名称用本机实际可用设备替换
xcodebuild -project Runner.xcodeproj -scheme Runner \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

CI 入口为 `.github/workflows/build-ios.yml`；设备推送入口为 `scripts/entry/push_ios.sh`（Mac 直连）与 `scripts/entry/ios.sh`（Linux 经安卓中继）。构建、上传和设备验收分别记录，不能把 Git push 成功当成 IPA 构建成功。

### 5.3 手势与数据回归

修改手势、布局或数据操作后，须按《Agent 详细设计规范》的相关验收用例回归，并说明实际验证的平台与未验证项。

### 5.4 拉取IPA到本地Livecontainer源

使用 `scripts/update_livecontainer_ipa.sh` 拉取最新 `action` 编译的IPA到对应目录并刷新 `source.json` 。

## 6. HarmonyOS 模拟器 IPv6 排障

已记录的开发环境问题：测试服务器只有 AAAA 记录，Windows 可正常通过 IPv6 登录，模拟器 DNS / IPv6 连通失败。此类故障不能显示为密码错误；保留 BusinessError 错误码和可读信息，不输出 `[object Object]`。

临时桥仅用于可信 Windows 主机和模拟器，不作为生产方案：

```powershell
node scripts/immich_emulator_proxy.cjs
# 保持上面的终端运行；在另一终端执行（路径按本机安装位置调整）
& 'F:\Programs\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe' rport tcp:15941 tcp:15941
```

模拟器登录地址手动填 `http://127.0.0.1:15941`。

- 脚本只监听 Windows `127.0.0.1:15941`，上游固定为脚本配置的测试服务器，只代理 `/api/`，不是开放代理。
- 主机到服务器走 HTTPS 并校验证书；模拟器到主机 HTTP 仅经过可信 HDC 本地通道。
- 不记录请求体、头或凭据；Ctrl+C 退出。主机 / 模拟器 / HDC 重启后重新启动并建立转发。
- 不修改 App 默认服务器，不重写任意用户地址。生产环境使用双栈 HTTPS 或具备 IPv6 的真机。
- HarmonyOS `mkdirSync(path, true)` 对已存在目录可能报错：先检查存在性，并发创建失败后再次确认目录，避免后续缩略图下载失败。

## 7. 文档维护与交付

- 业务行为改动更新详细规范；用户可见变化同步简案；开发流程变化更新本文，不再为相同主题新增分散规范。
- 删除过时结论与重复确认历史，保留仍有用的理由、官方来源和未决项；追溯交给 Git，而不是让新旧规则并列生效。
- 交付说明列出修改范围、验证证据、未验证的平台和已知差距，避免“100% 顺畅”“像素级原生”“全平台已支持”等未经验证的承诺。
- 只整理文档时不顺带改业务代码，不改变用户未要求改变的产品行为。
