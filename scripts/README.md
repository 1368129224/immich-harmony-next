# Scripts 维护与构建脚本集

本目录包含了 Immich 原生多端工程（iOS / HarmonyOS）在 Linux NAS 核心开发机、Windows UI 工作站、安卓中继机与 Mac 编译机上的各类自动化工具脚本。

---

## 目录速览

| 脚本文件 | 适用平台 | 说明 |
| :--- | :--- | :--- |
| **[`push_tunnel.sh`](#1-push_tunnelsh-异网中继推送与唤醒)** | Linux / 任意 POSIX | **【核心】** 通过 Tailscale + Root 安卓中继向 iPhone 静默安装并唤醒应用 |
| **[`update_livecontainer_ipa.sh`](#2-update_livecontainer_ipash-更新本地-ipa-源)** | Linux NAS | 从 GitHub Actions 自动下载最新构建的未签名 IPA 并刷新本地 LiveContainer 源 |
| **[`build_ios_lib.sh`](#3-build_ios_libsh-ios-rust-ffi-编译)** | Linux / macOS | 交叉编译 Rust 核心 C-FFI 静态库 (`crates/immich-ios-ffi`) |
| **[`check_native_ios.py`](#4-check_native_iospy-ios-洁室净室合规检查)** | 跨平台 | 验证 iOS 工程源码与 Bundle 纯净性（严禁 Flutter/Dart 痕迹） |
| **[`push_ios.sh`](#5-push_iossh-macos-本地有线无线直连推送)** | macOS | 在 Mac 本机通过 Xcode 与 `devicectl` 进行直连编译和安装 |
| **`build_ohos_so.sh`** | Linux NAS | 交叉编译鸿蒙 ArkTS N-API 动态库 (`immich-ohos-napi`) |
| **`deploy_harmony.sh`** | Linux NAS | 将编译好的鸿蒙 `.so` 自动同步至 Windows 共享目录 |

---

## 1. `push_tunnel.sh` (异网中继推送与唤醒)

专为**免物理 Mac**、利用 **Tailscale 异网穿透 + Root 安卓手机（C-to-C 连接 iPhone）** 的环境设计。直接由本机 Linux 作为中枢大脑，隔空向异地 iPhone 静默安装 IPA 并自动唤醒应用。

### 1.1 工作原理拓扑

```text
[当前 Linux 开发机] (执行 push_tunnel.sh)
        │
        │ 1. 自动连接安卓中继节点 ADB (100.102.83.97:5555)
        │ 2. 自动巡检并修复 Type-C 为 Host 模式与 USB 调试模式 4
        │ 3. 极速将待安装 IPA 推送到安卓中继
        ▼
[Root 安卓中继机] (调用本地 usbmuxd / pymobiledevice3)
        │
        │ 4. 经由物理 C-to-C 数据线直接推入 iPhone
        ▼
[目标 iPhone] ───► 自动完成安装并在屏幕上自动拉起应用！
```

### 1.2 前置配置（仅需一次）

1. **配置中继地址**：
   复制目录下的配置模板为 `.tunnel.env`（已加入 `.gitignore`，不会提交到仓库）：
   ```bash
   cp scripts/.tunnel.env.example scripts/.tunnel.env
   ```
   编辑 `scripts/.tunnel.env`，填入安卓手机的 Tailscale IP：
   ```bash
   ANDROID_IP="100.102.83.97" # 你的安卓中继机 Tailscale IP
   ```

2. **安卓端确保环境就绪**：
   安卓 Termux（Ubuntu 容器内）确保已插好 iPhone 并开启网络 ADB（5555 端口）。

### 1.3 标准日常开发流程（推荐）

每次在 Linux 上完成编码并 `git push`、GitHub Actions 编译成功后：

```bash
# 第一步：下载最新构建产物（落盘至 /mnt/ssd/temp/ipa/Immich-unsigned.ipa 并更新本地源）
bash scripts/update_livecontainer_ipa.sh

# 第二步：手动执行中继推送，iPhone 自动安装并拉起应用
./scripts/push_tunnel.sh
```

### 1.4 命令参数与高级用法

```bash
# 1. 连通性测试模式（仅测试中继隧道和 iPhone 识别状态，不执行安装）
./scripts/push_tunnel.sh --info

# 2. 懒人一键流：自动执行 update_livecontainer_ipa.sh 抓取最新构建，紧接着推包
./scripts/push_tunnel.sh -u

# 3. 指定推送到其他自定义的 IPA 文件
./scripts/push_tunnel.sh /path/to/custom_app.ipa

# 4. 临时指定不同的中继 IP 与端口（覆盖配置文件）
./scripts/push_tunnel.sh -s 100.102.83.97:5555

# 5. 安装完成后不自动拉起应用
./scripts/push_tunnel.sh --no-launch

# 6. 查看完整帮助说明
./scripts/push_tunnel.sh -h
```

### 1.5 核心技术踩坑与自动修复原理（重要）

当你用 C-to-C 线连接安卓手机与 iPhone 时，通常会遇到以下三个底层坑点，`push_tunnel.sh` 脚本已将它们**全自动修复**：

1. **坑点一：安卓 Type-C 角色协商成了从机（Device/Sink）**
   - **现象**：执行 `ls -l /dev/bus/usb/*/` 为空，安卓以为自己连了充电宝或电脑，USB Host 控制器未启动。
   - **修复命令**：
     ```bash
     adb -s 100.102.83.97:5555 shell "su -c 'echo host > /sys/class/typec/port0/data_role'"
     ```
   - 切换为 `host` 后，iPhone 才会正式枚举挂载到安卓的 `/dev/bus/usb/001/` 总线上。

2. **坑点二：iPhone USB 接口配置未切到模式 4（MUX 调试通信）**
   - **现象**：`usbmuxd` 报错 `Could not set configuration 4: LIBUSB_ERROR_BUSY`。
   - **修复命令**：
     ```bash
     adb -s 100.102.83.97:5555 shell "su -c 'echo 4 > /sys/bus/usb/devices/1-*/bConfigurationValue'"
     ```

3. **坑点三：设备热插拔后的权限与服务状态**
   - 每次重新插拔或切换角色后，必须确保 USB 权限开放并重启 `usbmuxd`：
     ```bash
     adb -s 100.102.83.97:5555 shell "su -c 'chmod -R 777 /dev/bus/usb'"
     ```

---

### 1.6 远程 ADB 常用管理命令速查

中继安卓机已通过 Tailscale 开放远程 ADB（IP: `100.102.83.97:5555`），在 Linux 本机可直接执行以下管理命令：

```bash
# 1. 连接与状态检查
adb connect 100.102.83.97:5555
adb devices

# 2. 检查安卓上识别到的 USB 设备列表（查看 iPhone 是否在位）
adb -s 100.102.83.97:5555 shell "su -c 'ls -l /dev/bus/usb/*/'"

# 3. 查看安卓当前 Type-C 角色（期望输出包含 [host]）
adb -s 100.102.83.97:5555 shell "su -c 'cat /sys/class/typec/port0/data_role'"

# 4. 在安卓容器内直接执行 pymobiledevice3 查看 iPhone 信息
adb -s 100.102.83.97:5555 shell "su -c 'PATH=/data/data/com.termux/files/usr/bin:\$PATH proot-distro login ubuntu -- pymobiledevice3 lockdown info'"

# 5. 查看安卓手机电池与供电情况（防止安卓反向给 iPhone 充爆电）
adb -s 100.102.83.97:5555 shell dumpsys battery

# 6. 进入安卓 Root 交互终端
adb -s 100.102.83.97:5555 shell
```

---

### 1.7 关于 iOS 签名与安装途径

iOS 原生要求直接安装到系统桌面的应用必须具备有效签名。针对无付费开发者账号的环境，推荐以下三种成熟方案：

* **方案 A：LiveContainer 免签名即装即用（强烈推荐，日常开发首选）**
  - **特点**：**100% 免签名、永久有效、不占 3 个免费 App 名额**。
  - **用法**：执行 `bash scripts/update_livecontainer_ipa.sh` 后，手机打开 LiveContainer 即可无感更新使用最新的未签名 IPA。
* **方案 B：手机端 SideStore 自动本地签名**
  - **特点**：手机本地自闭环重签，直接安装到 iOS 桌面。
  - **用法**：在 iPhone 打开 SideStore，添加 NAS 托管的 `Immich-unsigned.ipa` 下载链接即可自动签名并安装到桌面。
* **方案 C：使用已有证书配合 `zsign` 本地秒级自签**
  - **特点**：完全在 Linux NAS 端完成签名，随后由 `push_tunnel.sh` 秒推真机并唤醒。
  - **命令**：
    ```bash
    zsign -k cert.p12 -p '证书密码' -m profile.mobileprovision \
          -o /mnt/ssd/temp/ipa/Immich-signed.ipa \
          /mnt/ssd/temp/ipa/Immich-unsigned.ipa
    ./scripts/push_tunnel.sh /mnt/ssd/temp/ipa/Immich-signed.ipa
    ```

---

## 2. `update_livecontainer_ipa.sh` (更新本地 IPA 源)

用于从 GitHub Actions CI 或 Release 抓取最新成功的未签名 iOS 构建，并无缝集成到本地 LiveContainer IPA 软件源。

```bash
# 抓取当前分支（默认 main）的最新成功构件并刷新 LiveContainer 源
bash scripts/update_livecontainer_ipa.sh

# 抓取指定分支
bash scripts/update_livecontainer_ipa.sh feat/new-timeline
```
* **产物路径**：
  - `/mnt/ssd/temp/ipa/Immich-unsigned.ipa`
  - `/mnt/ssd/temp/ipa/ImmichZ-unsigned.ipa`（旧名兼容软链/拷贝）
* **关联更新**：自动调用 `/home/zooter/docker-config/livecontainer-ipa-source/update-source.py` 生成 `source.json`。

---

## 3. `build_ios_lib.sh` (iOS Rust FFI 编译)

为 iOS 编译底层 Rust 核心静态库 (`crates/immich-ios-ffi`)，并自动生成/同步 C-FFI 头文件 `immich_core_ffi.h` 到 Xcode 原生工程目录。

```bash
# 编译 Debug 库
bash scripts/build_ios_lib.sh debug

# 编译 Release 优化库
bash scripts/build_ios_lib.sh release
```
* **输出目标**：`ios-app/Runner/libs/` 下对应的平台静态归档文件。

---

## 4. `check_native_ios.py` (iOS 洁室净室合规检查)

严格执行开源许可与独立洁室实现规范，全自动化扫描源码树与产物包，严防任何 Flutter / Dart 或非原生组件残留。

```bash
# 执行静态合规检查与回归单元测试
python3 scripts/check_native_ios.py
python3 -m unittest discover -s scripts -p 'test_*.py'
```

---

## 5. `push_ios.sh` (macOS 本地直连推送)

在带有物理 Xcode 的 MacBook 上使用，支持有线或官方 Wi-Fi 局域网配对模式下直接编译、部署和断点启动：

```bash
# 指定设备名称或 UDID（支持环境变量自定义）
DEVICE_NAME="Z iPhone" bash scripts/push_ios.sh
```
