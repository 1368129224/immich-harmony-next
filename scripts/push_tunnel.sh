#!/usr/bin/env bash
# ==============================================================================
# Push and launch native iOS IPA via Tailscale / Android Relay (ADB + pymobiledevice3)
#
# Workflow:
#   1. Runs after update_livecontainer_ipa.sh has fetched the latest build.
#   2. Automatically verifies / fixes Android Type-C host role & USB configuration.
#   3. Installs IPA to the connected iPhone and launches the app.
# ==============================================================================
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Load optional local tunnel configuration if present
if [[ -f "$ROOT/scripts/.tunnel.env" ]]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/.tunnel.env"
elif [[ -f "$HOME/.config/ios-tunnel.env" ]]; then
  # shellcheck source=/dev/null
  source "$HOME/.config/ios-tunnel.env"
fi

# Configurable parameters
ANDROID_IP="${ANDROID_IP:-100.102.83.97}"
ADB_PORT="${ADB_PORT:-5555}"
ADB_TARGET="${ANDROID_IP}:${ADB_PORT}"
BUNDLE_ID="${BUNDLE_ID:-com.immichz.immichz}"

IPA_DIR="${IPA_DIR:-/mnt/ssd/temp/ipa}"
IPA_NAME="${IPA_NAME:-Immich-unsigned.ipa}"
IPA_PATH="${IPA_PATH:-${IPA_DIR}/${IPA_NAME}}"

DO_UPDATE=false
DO_LAUNCH=true
ONLY_INFO=false
FIX_USB=true

show_help() {
  cat <<EOF
用法: $(basename "$0") [选项] [IPA文件路径]

通过 Tailscale 远程连接 Root 安卓中继机，向插在其上的 iPhone 推送并启动 IPA。
默认推送由 update_livecontainer_ipa.sh 拉取的最新的 IPA:
  ${IPA_PATH}

参数/选项:
  [IPA文件路径]         可选，指定待安装的 .ipa 文件（默认: ${IPA_PATH}）
  -u, --update          先自动调用 update_livecontainer_ipa.sh 下载最新构件再推送
  -s, --target <ip:port> 指定安卓 ADB 目标（当前默认: ${ADB_TARGET}）
  --no-launch           安装完成后不自动启动应用
  --info                仅测试连接并输出安卓 USB 状态与已连接 iPhone 信息
  -h, --help            显示帮助信息

环境变量 / 配置文件:
  ANDROID_IP            安卓中继机 Tailscale IP (默认: 100.102.83.97)
  ADB_PORT              安卓 ADB 远程端口 (默认: 5555)
  IPA_PATH              待安装 IPA 文件绝对路径
  BUNDLE_ID             应用 Bundle Identifier (默认: com.immichz.immichz)
  可创建配置文件:       $ROOT/scripts/.tunnel.env 或 ~/.config/ios-tunnel.env
EOF
}

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      show_help
      exit 0
      ;;
    -u|--update)
      DO_UPDATE=true
      shift
      ;;
    -s|--target)
      ADB_TARGET="$2"
      shift 2
      ;;
    --no-launch)
      DO_LAUNCH=false
      shift
      ;;
    --info)
      ONLY_INFO=true
      shift
      ;;
    -*)
      echo "❌ 未知参数: $1" >&2
      show_help >&2
      exit 1
      ;;
    *)
      IPA_PATH="$1"
      shift
      ;;
  esac
done

# Step 1: Optional auto-update
if [[ "$DO_UPDATE" == true ]]; then
  echo "🔄 [0/4] 正在拉取最新的 iOS 构建产物 (update_livecontainer_ipa.sh)..."
  bash "$ROOT/scripts/update_livecontainer_ipa.sh"
  echo ""
fi

# Step 2: Check target IPA existence (if not only checking info)
if [[ "$ONLY_INFO" == false ]]; then
  if [[ ! -f "$IPA_PATH" ]]; then
    echo "❌ 找不到待安装的 IPA 文件: $IPA_PATH" >&2
    echo "   建议先执行: bash $ROOT/scripts/update_livecontainer_ipa.sh" >&2
    echo "   或者携带 -u 参数: $(basename "$0") -u" >&2
    exit 1
  fi
  IPA_SIZE="$(du -h "$IPA_PATH" | cut -f1)"
  IPA_MTIME="$(date -r "$IPA_PATH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || stat -c '%y' "$IPA_PATH" 2>/dev/null || echo '未知')"
fi

# Step 3: Check ADB connectivity to Android Relay
echo "🌐 正在连接安卓中继节点 (${ADB_TARGET})..."
adb connect "$ADB_TARGET" >/dev/null 2>&1 || true

ADB_STATE="$(adb -s "$ADB_TARGET" get-state 2>/dev/null || echo 'offline')"
if [[ "$ADB_STATE" != "device" ]]; then
  echo "❌ 无法通过 ADB 连接安卓设备: ${ADB_TARGET} (状态: ${ADB_STATE})" >&2
  echo "" >&2
  echo "🔍 请排查以下项：" >&2
  echo "   1. 安卓端是否已开启并连接 Tailscale？" >&2
  echo "   2. 安卓端是否开启了【开发者选项 -> 无线调试】或【网络 ADB (端口 5555)】？" >&2
  echo "   3. 检查安卓手机屏幕是否有【允许 USB 调试】授权弹窗。" >&2
  exit 1
fi
echo "✅ 安卓中继节点 ADB 已就绪。"

# Step 4: Inspect & Fix Type-C Role (Host vs Device) and Configuration
echo "🔍 正在巡检安卓端的 USB 物理连接与 Type-C 角色..."
ROLES="$(adb -s "$ADB_TARGET" shell "su -c 'cat /sys/class/typec/port0/data_role 2>/dev/null || true'")"

if echo "$ROLES" | grep -q "\[device\]"; then
  echo "⚠️  检测到安卓处于 [device] (从机) 模式，正在自动切换为 [host] (主机) 模式..."
  adb -s "$ADB_TARGET" shell "su -c 'echo source > /sys/class/typec/port0/power_role 2>/dev/null; sleep 1; echo host > /sys/class/typec/port0/data_role 2>/dev/null || true'"
  sleep 1
fi

# 精准查找 Apple 设备 (idVendor=05ac) 并切换为配置 4 (MUX 调试通信模式)
NEED_RESTART_USBMUXD="$(adb -s "$ADB_TARGET" shell "su -c '
CHANGED=0
for dev in /sys/bus/usb/devices/*; do
  if [ -f \"\$dev/idVendor\" ] && [ \"\$(cat \"\$dev/idVendor\" 2>/dev/null)\" = \"05ac\" ]; then
    CURR=\$(cat \"\$dev/bConfigurationValue\" 2>/dev/null || echo 0)
    if [ \"\$CURR\" != \"4\" ]; then
      echo 4 > \"\$dev/bConfigurationValue\" 2>/dev/null || true
      CHANGED=1
    fi
  fi
done
chmod -R 777 /dev/bus/usb 2>/dev/null || true
echo \$CHANGED
'" | tr -d '\r\n ')"

# 检查 usbmuxd 是否存活，若配置刚切换或进程缺失则重启
USBMUXD_RUNNING="$(adb -s "$ADB_TARGET" shell "ps -ef | grep 'usbmuxd' | grep -v grep | wc -l" | tr -d '\r\n ')"
if [[ "$NEED_RESTART_USBMUXD" == "1" ]] || [[ "$USBMUXD_RUNNING" == "0" ]]; then
  echo "⚙️  正在安卓端初始化/重启 usbmuxd 守护进程..."
  adb -s "$ADB_TARGET" shell "su -c 'killall usbmuxd 2>/dev/null; chmod -R 777 /dev/bus/usb; PATH=/data/data/com.termux/files/usr/bin:\$PATH proot-distro login ubuntu -- usbmuxd -f -v >/data/local/tmp/usbmuxd.log 2>&1 &'"
  sleep 2
fi

# Step 5: Query iPhone info via Android proot pymobiledevice3 (带一次自愈重试)
echo "📱 正在握手查询已连接的 iPhone..."
DEVICE_INFO="$(adb -s "$ADB_TARGET" shell "su -c 'PATH=/data/data/com.termux/files/usr/bin:\$PATH proot-distro login ubuntu -- pymobiledevice3 lockdown info 2>/dev/null || true'" | tr -d '\r')"

if [[ -z "$DEVICE_INFO" ]] || echo "$DEVICE_INFO" | grep -qi "No device connected" || echo "$DEVICE_INFO" | grep -qi "Device is not connected"; then
  echo "🔄 正在尝试重新激活 USB 通信管道..."
  adb -s "$ADB_TARGET" shell "su -c 'killall usbmuxd 2>/dev/null; chmod -R 777 /dev/bus/usb; PATH=/data/data/com.termux/files/usr/bin:\$PATH proot-distro login ubuntu -- usbmuxd -f -v >/data/local/tmp/usbmuxd.log 2>&1 &'"
  sleep 2
  DEVICE_INFO="$(adb -s "$ADB_TARGET" shell "su -c 'PATH=/data/data/com.termux/files/usr/bin:\$PATH proot-distro login ubuntu -- pymobiledevice3 lockdown info 2>/dev/null || true'" | tr -d '\r')"
fi

if [[ -z "$DEVICE_INFO" ]] || echo "$DEVICE_INFO" | grep -qi "No device connected" || echo "$DEVICE_INFO" | grep -qi "Device is not connected"; then
  echo "❌ 安卓已设为主机，但未能握手到 iOS 设备！" >&2
  echo "" >&2
  echo "🔍 请排查以下项：" >&2
  echo "   1. iPhone 与安卓手机的 C-to-C 线是否连接稳固？" >&2
  echo "   2. iPhone 是否已解锁，并点击了【信任此电脑】并输入锁屏密码？" >&2
  echo "   3. 在安卓终端执行检查: adb -s $ADB_TARGET shell \"su -c 'ls -l /dev/bus/usb/*/'\"" >&2
  exit 1
fi

DEVICE_NAME=""
PRODUCT_VERSION=""
PRODUCT_TYPE=""
DEVICE_UDID=""

eval "$(python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    print('DEVICE_NAME=\"' + str(d.get('DeviceName', '')) + '\"')
    print('PRODUCT_VERSION=\"' + str(d.get('ProductVersion', '')) + '\"')
    print('PRODUCT_TYPE=\"' + str(d.get('ProductType', '')) + '\"')
    print('DEVICE_UDID=\"' + str(d.get('UniqueDeviceID', '')) + '\"')
except Exception:
    pass
" "$DEVICE_INFO" 2>/dev/null || true)"

echo "🎉 成功识别 iOS 设备: ${DEVICE_NAME:-未知设备} [${PRODUCT_TYPE:-未知型号}, iOS ${PRODUCT_VERSION:-未知版本}]"
echo "   UDID: ${DEVICE_UDID:-未知}"

if [[ "$ONLY_INFO" == true ]]; then
  echo "ℹ️  已指定 --info 模式，探测完毕退出。"
  exit 0
fi

# Step 6: Push IPA via ADB to Android Relay
echo ""
echo "📦 [1/3] 正在通过 Tailscale ADB 极速传输 IPA 到安卓中继机..."
DEST_TMP="/data/local/tmp/app_push.ipa"
PROOT_TMP="/data/data/com.termux/files/usr/var/lib/proot-distro/containers/ubuntu/rootfs/tmp/app_push.ipa"

adb -s "$ADB_TARGET" push "$IPA_PATH" "$DEST_TMP" >/dev/null
adb -s "$ADB_TARGET" shell "su -c 'cp \"$DEST_TMP\" \"$PROOT_TMP\" && chmod 777 \"$PROOT_TMP\"'"
echo "✅ 传输完成 ($IPA_SIZE)"

# Step 7: Install IPA on iPhone
echo ""
echo "📲 [2/3] 正在指挥安卓中继向 iPhone 安装应用..."
echo "   安装包: $IPA_PATH ($IPA_SIZE, 更新时间: $IPA_MTIME)"
adb -s "$ADB_TARGET" shell "su -c 'PATH=/data/data/com.termux/files/usr/bin:\$PATH proot-distro login ubuntu -- pymobiledevice3 apps install /tmp/app_push.ipa'"
echo "✅ 应用安装成功！"

# Step 8: Launch App
if [[ "$DO_LAUNCH" == true ]]; then
  echo ""
  echo "🚀 [3/3] 正在远程启动应用 ($BUNDLE_ID)..."
  if adb -s "$ADB_TARGET" shell "su -c 'PATH=/data/data/com.termux/files/usr/bin:\$PATH proot-distro login ubuntu -- pymobiledevice3 apps launch $BUNDLE_ID 2>/dev/null'"; then
    echo "✅ 应用启动成功！"
  else
    echo "⚠️  应用启动指令返回非零，可能应用已在运行或需要手动在手机屏幕点击。" >&2
  fi
fi

# Clean up temporary IPA on relay
adb -s "$ADB_TARGET" shell "su -c 'rm -f \"$DEST_TMP\" \"$PROOT_TMP\" 2>/dev/null || true'"

echo ""
echo "🏁 全部搞定！手机已更新并处于可用状态。"
