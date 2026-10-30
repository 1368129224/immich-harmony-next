# scripts/

Immich 原生多端客户端（iOS / HarmonyOS）的构建、检查与真机推送脚本。

**手动调用的最终入口放在 [`entry/`](entry/) 下**；`scripts/` 根目录是被入口、CI 或其他机器调用的底层脚本。

| 机器 | 角色 |
| :--- | :--- |
| **Linux NAS** | Rust 核心开发、鸿蒙 `.so` 交叉编译、合规检查、IPA 拉取 / 签名 / 推送 |
| **Windows PC** | DevEco Studio 鸿蒙开发与模拟器 |
| **MacBook** | Xcode 构建与真机直装；导出签名证书与描述文件 |
| **Root 安卓中继** | Termux + proot Ubuntu，运行 `usbmuxd` / `pymobiledevice3`，经 USB 连接 iPhone |

---

## 目录速览

### 入口（`entry/`）

| 文件 | 平台 | 说明 |
| :--- | :--- | :--- |
| [`entry/ios.sh`](entry/ios.sh) | Linux NAS | **iOS 远程装机总入口**：`info` / `sign` / `push` / `deploy` / `relay` / `clean`（经安卓中继） |
| [`entry/push_ios.sh`](entry/push_ios.sh) | macOS | Mac 直连装机：依次执行 Rust 库编译、`xcodebuild`、`check_native_ios.py --app`，再用 `devicectl` 安装并启动 |

### 构建

| 文件 | 平台 | 说明 |
| :--- | :--- | :--- |
| [`build_ohos_so.sh`](build_ohos_so.sh) | Linux NAS | 用 `ohrs` 编译 `immich-ohos-napi`（x86_64 模拟器 + arm64 真机），复制到 `harmony-app/entry/libs/`，同步 `index.d.ts` |
| [`build_ios_lib.sh`](build_ios_lib.sh) | macOS / Linux | 编译 `immich-ios-ffi` 静态库到 `ios-app/Runner/libs/`，同步 C 头文件；Linux 上只编译 host 库用于校验；源码未变时跳过（`FORCE_RUST_BUILD=1` 强制编译） |

### 检查

| 文件 | 说明 |
| :--- | :--- |
| [`check_native_ios.py`](check_native_ios.py) | 净室合规检查：git 跟踪文件和 iOS 源码中不得出现 Flutter/Dart 残留；加 `--app <Runner.app>` 时同时检查产物（仅限 macOS）。CI 也会运行 |

### 部署与调试

| 文件 | 平台 | 说明 |
| :--- | :--- | :--- |
| [`deploy_harmony.bat`](deploy_harmony.bat) / [`.sh`](deploy_harmony.sh) | Windows（cmd / Git Bash） | 用 Hvigor 打包 HAP，通过 `hdc` 安装并启动；DevEco 路径写死为 `F:\Programs\DevEco Studio` |
| [`immich_emulator_proxy.cjs`](immich_emulator_proxy.cjs) | Windows | 仅用于调试：为只支持 IPv4 的鸿蒙模拟器转发 `/api/*` 到 IPv6 Immich 服务器（`127.0.0.1:15941`） |

### iOS 发布与远程装机支撑（Linux NAS → 安卓中继 → iPhone）

| 文件 | 运行位置 | 说明 |
| :--- | :--- | :--- |
| [`update_livecontainer_ipa.sh`](update_livecontainer_ipa.sh) | Linux NAS | 拉取 GitHub Actions 最新成功构建的未签名 IPA，刷新 LiveContainer 源 |
| [`push_tunnel.sh`](push_tunnel.sh) | Linux NAS | 底层推送实现，由 `entry/ios.sh push` 调用 |
| [`start_ios_relay.sh`](start_ios_relay.sh) | 安卓 Termux（`~/start_ios_relay.sh`） | 启动中继：按正确顺序配置 USB 并启动 usbmuxd，由 `entry/ios.sh relay start` 远程触发 |
| [`.tunnel.env.example`](.tunnel.env.example) | — | 本地配置模板，复制为 `.tunnel.env` 后使用（已 gitignore） |
| `cert/` | Linux NAS | 存放 `*.p12` 与 `*.mobileprovision`（已 gitignore，**切勿提交**） |

---

## 1. 必跑验证（参见 [AGENTS.md](../AGENTS.md)）

```bash
# 修改 crates/ 后
~/.cargo/bin/cargo test --workspace
bash scripts/build_ohos_so.sh

# 修改 iOS 源码后
python3 scripts/check_native_ios.py

# git push 且 CI 成功后
bash scripts/update_livecontainer_ipa.sh
```

---

## 2. `update_livecontainer_ipa.sh`

```bash
bash scripts/update_livecontainer_ipa.sh             # 当前 git 分支（取不到时用 main）
bash scripts/update_livecontainer_ipa.sh feat/xxx    # 指定分支
```

- 依赖 `gh`（已登录）和 `python3`。
- 选取 `build-ios.yml` 在该分支上最新一次成功的运行，下载 artifact `immich-ios-ipa-unsigned`；下载失败时（例如 artifact 配额用尽）改从 Release `latest-build` 断点续传。
- 校验 IPA 结构后原子替换：
  - `/mnt/ssd/temp/ipa/Immich-unsigned.ipa`
  - `/mnt/ssd/temp/ipa/ImmichZ-unsigned.ipa`（旧文件名，App 内自更新仍在使用，**不要删除**）
- 最后调用 `update-source.py` 重新生成 `source.json`。
- 可用环境变量覆盖：`REPO`、`WORKFLOW`、`ARTIFACT`、`IPA_NAME`、`IPA_DIR`、`UPDATER`。

---

## 3. `entry/ios.sh`（Linux NAS 全流程入口）

```bash
./scripts/entry/ios.sh info              # 证书 / 描述文件 / IPA / 中继 / iPhone 状态
./scripts/entry/ios.sh sign              # Immich-unsigned.ipa → Immich-signed.ipa（zsign）
./scripts/entry/ios.sh push [ipa]        # 推送到 iPhone 并启动（默认 Immich-signed.ipa）
./scripts/entry/ios.sh deploy            # sign + push ⭐
./scripts/entry/ios.sh relay status|start|stop|ensure   # push/deploy 已自动 ensure，无需手动 start
./scripts/entry/ios.sh clean             # 清理 IPA 目录下的 .download.* 临时目录
```

**典型流程**：CI 成功 → `update_livecontainer_ipa.sh` → `entry/ios.sh deploy`。

### 3.1 配置

```bash
cp scripts/.tunnel.env.example scripts/.tunnel.env   # 然后编辑
```

| 变量 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `ANDROID_IP` / `ADB_PORT` | `100.102.83.97` / `5555` | 安卓中继的 Tailscale 地址与网络 ADB 端口 |
| `BUNDLE_ID` | `com.immichz.immichz` | 安装后要启动的 App |
| `IPA_DIR` | `/mnt/ssd/temp/ipa` | IPA 目录 |
| `IPA_UNSIGNED` / `IPA_SIGNED` | `$IPA_DIR/Immich-{unsigned,signed}.ipa` | 签名的输入 / 输出路径 |
| `P12_PASSWORD` | **无，必填** | `cert/*.p12` 的导出密码 |

### 3.2 依赖

- `adb`、`openssl`（3.x 版本下脚本会自动加 `-legacy`，用于读取 macOS 导出的 RC2 加密 p12）、`python3`、`unzip`
- `zsign`：

  ```bash
  git clone --depth 1 https://github.com/zhlynn/zsign.git /tmp/zsign
  cd /tmp/zsign/build/linux && make -j"$(nproc)"
  mkdir -p ~/.local/bin && cp ../../bin/zsign ~/.local/bin/
  ```

### 3.3 证书与描述文件

`cert/` 下需要放置一个 `*.p12` 和一个 `*.mobileprovision`，两者都从 Mac 导出（见第 6 节）。

| 概念 | 有效期 | 说明 |
| :--- | :--- | :--- |
| 签名证书（p12） | 1 年 | 到期前在 Xcode 中重新生成 |
| 描述文件（免费账号） | **7 天** | 过期后 App 无法启动，需要在 Mac 上续期、重新签名并推送 |

---

## 4. `push_tunnel.sh`（底层推送）

一般通过 `entry/ios.sh push` / `deploy` 调用即可。直接调用：

```bash
./scripts/push_tunnel.sh --info                   # 只诊断中继与 iPhone
./scripts/push_tunnel.sh /path/to/signed.ipa      # 推送指定 IPA
./scripts/push_tunnel.sh --no-launch <ipa>        # 安装后不启动
./scripts/push_tunnel.sh -s 100.x.y.z:5555 <ipa>  # 指定中继地址
```

> ⚠️ 不传路径时默认推送 `IPA_PATH`（未配置时是 `Immich-unsigned.ipa`），`-u` 也只会拉取**未签名**包。真机只能安装已签名的 IPA，所以请传入签名后的路径，或直接用 `entry/ios.sh deploy`。

**流程**：`adb connect` → Type-C 切 host → Apple 设备（`idVendor=05ac`）切到 USB 配置 4 → 必要时重启 usbmuxd → `pymobiledevice3 lockdown info` 握手（失败自动重试一次）→ `adb push` 到中继并拷入 proot → `pymobiledevice3 apps install` → `apps launch`。

---

## 5. 安卓中继：`start_ios_relay.sh`

### 5.1 部署（一次性）

```bash
adb -s <relay> push scripts/start_ios_relay.sh /data/local/tmp/
adb -s <relay> shell "su -c 'cp /data/local/tmp/start_ios_relay.sh /data/data/com.termux/files/home/'"
```

### 5.2 启动

```bash
bash ~/start_ios_relay.sh            # 在 Termux 中运行
./scripts/entry/ios.sh relay start   # 或在 NAS 上远程触发
```

执行步骤：获取唤醒锁 → 固定 HostID 与 SystemBUID（避免 iPhone 反复要求信任）→ 停止旧的 usbmuxd → Type-C 切 host → USB 切到配置 4，并**轮询直到接口 `4.0` 出现** → **之后才启动 usbmuxd** → 确认 usbmuxd 识别到设备 → 用 `lockdown info` 做最终验证。

> ⚠️ **启动顺序很重要**：如果在 USB 配置稳定之前启动 usbmuxd，它的内部设备表会失效，`ListDevices` 将返回空列表。

日志：`/data/local/tmp/usbmuxd.log`。

---

## 6. Mac 端证书工具（不在本仓库）

Mac 上的 `~/zzc-data/ios_cert_tool.sh` 负责检查和导出证书，并上传到 NAS 的 `scripts/cert/`：

```bash
bash ios_cert_tool.sh check    # 证书 / 描述文件有效期、绑定设备
bash ios_cert_tool.sh export   # 引导导出 p12（必须在 Mac 桌面的「终端」中运行）
bash ios_cert_tool.sh sync     # check + upload ⭐
bash ios_cert_tool.sh backup
```

- 导出带私钥的 p12 需要在图形界面中授权，通过 SSH 运行会报 `User interaction is not allowed`。
- **续期描述文件**：Xcode → Signing & Capabilities → 取消勾选并重新勾选 *Automatically manage signing*。如果没有生效，删除 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/*.mobileprovision` 后重试。
- 续期后的完整流程：Mac 上运行 `ios_cert_tool.sh sync` → NAS 上运行 `./scripts/entry/ios.sh deploy`。

---

## 7. 故障排查

| 现象 | 处理 |
| :--- | :--- |
| `zsign: command not found` | 按 3.2 节安装到 `~/.local/bin` |
| `未设置 P12_PASSWORD` / p12 无法解开 | 在 `.tunnel.env` 中设置正确的 `P12_PASSWORD` |
| 安卓中继不可达 | 检查安卓端的 Tailscale 连接和网络 ADB（5555）授权 |
| iPhone 未识别 / `DeviceList` 为空 | `push` / `deploy` 会自动探测并恢复中继（同步脚本 → 重启 → 等待枚举，最多 3 次）；仍失败时检查 C-to-C 线和「信任此电脑」，可手动 `entry/ios.sh relay ensure --force` |
| iPhone 反复弹出「信任此电脑」 | 信任判断同时看 HostID 与 SystemBUID，两者由 `start_ios_relay.sh` 固定在 proot 内的 `/var/lib/lockdown/SystemConfiguration.plist`；确认安卓上部署的是最新版脚本，再运行 `entry/ios.sh relay start` |
| 安装成功但 App 闪退 | 描述文件已过期（7 天），续期后重新 `deploy` |
