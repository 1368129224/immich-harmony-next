#!/usr/bin/env bash
# ==============================================================================
# iOS 全流程工具箱 (Linux NAS 端)
# 位置: scripts/entry/ios.sh
#
# 子命令:
#   info      查看证书 / 描述文件 / 已连接 iPhone 状态
#   sign      用 cert/ 下的证书签名 unsigned IPA
#   push      推送已签名 IPA 到 iPhone 并启动
#   deploy    sign + push 一键完成
#   relay     管理安卓中继服务 (start/stop/status)
#   clean     清理临时文件
#
# 示例:
#   ./scripts/entry/ios.sh info
#   ./scripts/entry/ios.sh sign
#   ./scripts/entry/ios.sh deploy
#   ./scripts/entry/ios.sh relay start
# ==============================================================================
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$ROOT/scripts"
CERT_DIR="$SCRIPTS/cert"

# 先读取 .tunnel.env，再计算派生变量（否则 ADB_TARGET 不会跟随配置变化）
if [[ -f "$SCRIPTS/.tunnel.env" ]]; then
  # shellcheck source=/dev/null
  source "$SCRIPTS/.tunnel.env"
fi

IPA_DIR="${IPA_DIR:-/mnt/ssd/temp/ipa}"
IPA_UNSIGNED="${IPA_UNSIGNED:-$IPA_DIR/Immich-unsigned.ipa}"
IPA_SIGNED="${IPA_SIGNED:-$IPA_DIR/Immich-signed.ipa}"
ANDROID_IP="${ANDROID_IP:-100.102.83.97}"
ADB_PORT="${ADB_PORT:-5555}"
ADB_TARGET="${ANDROID_IP}:${ADB_PORT}"
BUNDLE_ID="${BUNDLE_ID:-com.immichz.immichz}"
P12_PASSWORD="${P12_PASSWORD:-}"
export P12_PASSWORD   # openssl 通过 env:P12_PASSWORD 读取，避免密码出现在进程参数中
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; CYN=$'\033[0;36m'; BLD=$'\033[1m'; NC=$'\033[0m'
info() { echo "${CYN}[*]${NC} $*"; }
ok()   { echo "${GRN}[+]${NC} $*"; }
warn() { echo "${YEL}[!]${NC} $*"; }
err()  { echo "${RED}[x]${NC} $*"; }
title(){ echo ""; echo "${BLD}$*${NC}"; }

usage() {
  sed -n '3,/^# =\{10,\}$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
  exit 0
}

# ------------------------------------------------------------------------------
# 子命令: info
# ------------------------------------------------------------------------------
cmd_info() {
  title "===== 证书文件 ====="
  local p12 profile
  p12=$(ls "$CERT_DIR"/*.p12 2>/dev/null | head -1)
  profile=$(ls "$CERT_DIR"/*.mobileprovision 2>/dev/null | head -1)

  if [[ -n "$p12" ]]; then
    ok "p12: $(basename "$p12") ($(du -h "$p12" | cut -f1))"
    if [[ -z "$P12_PASSWORD" ]]; then
      warn "    未设置 P12_PASSWORD（在 scripts/.tunnel.env 中配置）"
    elif openssl pkcs12 -legacy -in "$p12" -passin env:P12_PASSWORD -noout 2>/dev/null; then
      openssl pkcs12 -legacy -in "$p12" -passin env:P12_PASSWORD -nokeys 2>/dev/null \
        | openssl x509 -noout -subject -dates 2>/dev/null | sed 's/^/    /'
      ok "    密码验证通过"
    else
      warn "    P12_PASSWORD 无法解开 p12"
    fi
  else
    err "未找到 p12 证书（$CERT_DIR）"
  fi

  echo ""
  if [[ -n "$profile" ]]; then
    ok "profile: $(basename "$profile")"
    python3 - "$profile" <<'PY' 2>/dev/null | sed 's/^/    /'
import subprocess, plistlib, sys
p = sys.argv[1]
try:
    out = subprocess.check_output(["openssl","smime","-inform","der","-verify","-noverify","-in",p], stderr=subprocess.DEVNULL)
except Exception:
    out = subprocess.check_output(["openssl","cms","-verify","-noverify","-inform","der","-in",p], stderr=subprocess.DEVNULL)
d = plistlib.loads(out)
print("AppID:  ", d.get("Entitlements",{}).get("application-identifier"))
print("TeamID: ", (d.get("TeamIdentifier") or ["?"])[0])
print("过期:   ", d.get("ExpirationDate"))
print("设备:   ", ", ".join(d.get("ProvisionedDevices") or []))
PY
  else
    err "未找到描述文件（$CERT_DIR）"
  fi

  title "===== IPA 文件 ====="
  [[ -f "$IPA_UNSIGNED" ]] && ok "未签名: $IPA_UNSIGNED ($(du -h "$IPA_UNSIGNED" | cut -f1))" || warn "无未签名 IPA"
  [[ -f "$IPA_SIGNED" ]]   && ok "已签名: $IPA_SIGNED ($(du -h "$IPA_SIGNED" | cut -f1))"     || warn "无已签名 IPA"

  title "===== 中继状态 ====="
  cmd_relay_status
}

# ------------------------------------------------------------------------------
# 子命令: sign
# ------------------------------------------------------------------------------
cmd_sign() {
  title "===== 签名 IPA ====="

  command -v zsign >/dev/null 2>&1 || {
    if [[ -x "$HOME/.local/bin/zsign" ]]; then
      export PATH="$HOME/.local/bin:$PATH"
    else
      err "未找到 zsign。安装方式:"
      err "  git clone --depth 1 https://github.com/zhlynn/zsign.git /tmp/zsign"
      err "  cd /tmp/zsign/build/linux && make && cp ../../bin/zsign ~/.local/bin/"
      exit 1
    fi
  }

  local p12 profile
  p12=$(ls "$CERT_DIR"/*.p12 2>/dev/null | head -1)
  profile=$(ls "$CERT_DIR"/*.mobileprovision 2>/dev/null | head -1)
  [[ -n "$p12" ]]     || { err "缺少 p12 证书"; exit 1; }
  [[ -n "$profile" ]] || { err "缺少 mobileprovision"; exit 1; }
  [[ -f "$IPA_UNSIGNED" ]] || { err "缺少未签名 IPA: $IPA_UNSIGNED"; exit 1; }
  [[ -n "$P12_PASSWORD" ]] || { err "未设置 P12_PASSWORD（在 scripts/.tunnel.env 中配置）"; exit 1; }
  info "证书:   $(basename "$p12")"
  info "描述文件: $(basename "$profile")"
  info "输入:   $IPA_UNSIGNED"
  info "输出:   $IPA_SIGNED"
  echo ""

  # 先签到本地临时目录再拷贝：zsign 直接写 IPA 目录时需要在该目录新建/替换文件，
  # 目录不可写（如沙箱、NAS 共享权限）时会失败；拷贝只需要对目标文件本身有写权限。
  local signed_tmp
  signed_tmp="$(mktemp -d)/Immich-signed.ipa"
  zsign -k "$p12" -p "$P12_PASSWORD" -m "$profile" -o "$signed_tmp" "$IPA_UNSIGNED" || {
    rm -rf "$(dirname "$signed_tmp")"
    err "签名失败"
    exit 1
  }
  mkdir -p "$(dirname "$IPA_SIGNED")"
  cp -f -- "$signed_tmp" "$IPA_SIGNED" || {
    rm -rf "$(dirname "$signed_tmp")"
    err "无法写入 $IPA_SIGNED（检查目录/文件权限）"
    exit 1
  }
  rm -rf "$(dirname "$signed_tmp")"

  echo ""
  # 验证签名结果
  local tmpd
  tmpd=$(mktemp -d)
  if unzip -q "$IPA_SIGNED" -d "$tmpd" 2>/dev/null; then
    if [[ -f "$tmpd/Payload/Runner.app/embedded.mobileprovision" && -d "$tmpd/Payload/Runner.app/_CodeSignature" ]]; then
      ok "签名验证通过（embedded.mobileprovision + _CodeSignature 齐备）"
      python3 - "$tmpd/Payload/Runner.app/embedded.mobileprovision" <<'PY' 2>/dev/null | sed 's/^/    /'
import subprocess, plistlib, sys
p = sys.argv[1]
try:
    out = subprocess.check_output(["openssl","smime","-inform","der","-verify","-noverify","-in",p], stderr=subprocess.DEVNULL)
except Exception:
    out = subprocess.check_output(["openssl","cms","-verify","-noverify","-inform","der","-in",p], stderr=subprocess.DEVNULL)
d = plistlib.loads(out)
print("UUID:  ", d.get("UUID"))
print("过期:  ", d.get("ExpirationDate"))
print("设备:  ", ", ".join(d.get("ProvisionedDevices") or []))
PY
    else
      err "签名验证失败：缺少 embedded.mobileprovision 或 _CodeSignature"
    fi
    rm -rf "$tmpd"
  fi

  echo ""
  ok "完成: $IPA_SIGNED ($(du -h "$IPA_SIGNED" | cut -f1))"
  echo ""
  info "下一步: ./scripts/entry/ios.sh push"
}

# ------------------------------------------------------------------------------
# 子命令: push
# ------------------------------------------------------------------------------
cmd_push() {
  local target="${1:-$IPA_SIGNED}"
  title "===== 推送到 iPhone ====="
  [[ -f "$target" ]] || { err "IPA 不存在: $target"; exit 1; }
  info "推送: $target ($(du -h "$target" | cut -f1))"
  echo ""
  bash "$SCRIPTS/push_tunnel.sh" "$target"
}

# ------------------------------------------------------------------------------
# 子命令: deploy
# ------------------------------------------------------------------------------
cmd_deploy() {
  cmd_sign || exit 1
  echo ""
  cmd_push "$IPA_SIGNED"
}

# ------------------------------------------------------------------------------
# 中继管理
# ------------------------------------------------------------------------------
relay_adb() { adb -s "$ADB_TARGET" "$@" 2>/dev/null; }

cmd_relay_start() {
  info "启动安卓中继服务..."
  relay_adb shell "su -c 'bash /data/data/com.termux/files/home/start_ios_relay.sh'" 2>/dev/null \
    || su_direct_start
  echo ""
  cmd_relay_status
}

su_direct_start() {
  # 回退：直接用 run-as 执行
  adb -s "$ADB_TARGET" shell "run-as com.termux /data/data/com.termux/files/usr/bin/bash /data/data/com.termux/files/home/start_ios_relay.sh" 2>/dev/null
}

cmd_relay_stop() {
  info "停止安卓中继服务..."
  relay_adb shell "su -c 'killall usbmuxd 2>/dev/null; echo stopped'" 2>/dev/null
  ok "已停止"
}

cmd_relay_status() {
  adb connect "$ADB_TARGET" >/dev/null 2>&1 || true
  local state
  state=$(adb -s "$ADB_TARGET" get-state 2>/dev/null || echo "offline")

  if [[ "$state" != "device" ]]; then
    err "安卓中继不可达 ($ADB_TARGET, 状态: $state)"
    return 1
  fi
  ok "ADB 已连接 ($ADB_TARGET)"

  # usbmuxd
  local muxd
  muxd=$(relay_adb shell "ps -ef | grep 'usbmuxd -f' | grep -v grep" 2>/dev/null | head -1)
  [[ -n "$muxd" ]] && ok "usbmuxd 运行中" || err "usbmuxd 未运行"

  # USB 配置
  local cfg
  cfg=$(relay_adb shell "su -c 'for d in /sys/bus/usb/devices/*; do if [ -f \$d/idVendor ] && [ \$(cat \$d/idVendor 2>/dev/null) = 05ac ]; then cat \$d/bConfigurationValue; fi; done'" 2>/dev/null | tr -d '\r\n ')
  if [[ "$cfg" == "4" ]]; then
    ok "iPhone USB 配置 4 已生效"
  elif [[ -z "$cfg" ]]; then
    warn "未检测到 iPhone（检查 C-to-C 线与信任状态）"
  else
    warn "iPhone USB 配置为 $cfg（应为 4；iPhone 重新枚举后会被重置）→ 运行: ./scripts/entry/ios.sh relay start"
  fi

  # 设备枚举
  local devs
  devs=$(adb -s "$ADB_TARGET" shell "su -c 'PATH=/data/data/com.termux/files/usr/bin:\$PATH proot-distro login ubuntu -- pymobiledevice3 usbmux list 2>/dev/null'" 2>/dev/null)
  if echo "$devs" | grep -q "DeviceName"; then
    local dn
    dn=$(echo "$devs" | grep -o '"DeviceName": *"[^"]*"' | head -1 | sed 's/.*: *"//;s/"//')
    ok "iPhone 已识别: $dn"
    return 0
  else
    err "iPhone 未识别（pymobiledevice3 usbmux list 为空）→ 运行: ./scripts/entry/ios.sh relay start"
    return 1
  fi
}

cmd_relay() {
  local sub="${1:-status}"
  case "$sub" in
    start)  cmd_relay_start ;;
    stop)   cmd_relay_stop ;;
    status) title "===== 中继状态 ====="; cmd_relay_status ;;
    *) err "未知 relay 子命令: $sub (start|stop|status)"; exit 1 ;;
  esac
}

# ------------------------------------------------------------------------------
# 子命令: clean
# ------------------------------------------------------------------------------
cmd_clean() {
  title "===== 清理临时文件 ====="
  local n=0
  for f in "$IPA_DIR"/.download.* ; do
    [[ -e "$f" ]] || continue
    rm -rf "$f"; n=$((n+1))
  done
  ok "清理 $n 个下载临时目录"
  [[ -f "$IPA_SIGNED" ]] && info "保留已签名 IPA: $IPA_SIGNED"
}

# ------------------------------------------------------------------------------
# 主入口
# ------------------------------------------------------------------------------
CMD="${1:-}"
shift || true
case "$CMD" in
  info)    cmd_info ;;
  sign)    cmd_sign ;;
  push)    cmd_push "${1:-}" ;;
  deploy)  cmd_deploy ;;
  relay)   cmd_relay "${1:-status}" ;;
  clean)   cmd_clean ;;
  -h|--help|help|"") usage ;;
  *) err "未知子命令: $CMD"; echo ""; usage ;;
esac
