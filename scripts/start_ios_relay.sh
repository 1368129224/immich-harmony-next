#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
# iPhone USB 中继常驻服务启动脚本 (Termux 一键)
# 功能: 配置 USB -> 启动 proot 内 usbmuxd -> 验证 iPhone 握手
# 用法: bash ~/start_ios_relay.sh
#
# 关键顺序（务必保持）:
#   1) Type-C 切 host
#   2) iPhone USB 配置切到 4，并等接口 4.0/4.1/4.2 出现
#   3) 配置稳定之后才启动 usbmuxd（否则 usbmuxd 内部设备表会失效）
# ============================================================================

set -u

LOG_DIR=/data/local/tmp
USBMUXD_LOG="$LOG_DIR/usbmuxd.log"
PROOT_BIN=/data/data/com.termux/files/usr/bin/proot-distro

echo "=============================================================="
echo " iPhone USB 中继服务启动器"
echo "=============================================================="

# --- 1. 保持 Termux 唤醒 ---
if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock 2>/dev/null || true
    echo "[+] 已获取 Termux 唤醒锁"
fi

# --- 2. 固定 HostID + SystemBUID（防止 iPhone 反复要求信任）---
# iPhone 的信任判断同时看 HostID 与 SystemBUID：两者任何一个变化都会被当成另一台电脑，
# 重新弹出「信任此电脑」。usbmuxd 读取的是 proot 容器内的 /var/lib/lockdown，
# 不是安卓系统的 /var（那里不存在），所以必须写到 rootfs 路径下。
ROOTFS=/data/data/com.termux/files/usr/var/lib/proot-distro/containers/ubuntu/rootfs
HOST_ID="DD8A91F6-CA32-30E0-983C-8F309D653045"
SYSTEM_BUID="8EECA5AB-B40A-0773-1513-1F13DF71B909"

ensure_hostid() {
    local lockdown="$ROOTFS/var/lib/lockdown"
    local conf="$lockdown/SystemConfiguration.plist"
    # 以 Termux 用户（run-as）运行时无法写 /data/local/tmp，临时文件放 Termux 自己的 home
    local tmp="${HOME:-/data/data/com.termux/files/home}/.SystemConfiguration.$$.plist"

    if su -c "grep -q '$HOST_ID' '$conf' 2>/dev/null && grep -q '$SYSTEM_BUID' '$conf' 2>/dev/null"; then
        echo "[*] HostID / SystemBUID 已固定"
        return 0
    fi

    cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>HostID</key>
	<string>${HOST_ID}</string>
	<key>SystemBUID</key>
	<string>${SYSTEM_BUID}</string>
</dict>
</plist>
PLIST
    su -c "mkdir -p '$lockdown' && cp '$tmp' '$conf' && chmod 644 '$conf'" \
        && echo "[+] 已固定 HostID / SystemBUID（避免反复要求信任）" \
        || echo "[!] 写入 $conf 失败"
    rm -f "$tmp"
}

ensure_hostid || true

# --- 3. 停止旧服务并配置 USB ---
echo "[*] 正在停止旧的 usbmuxd 与 tunneld..."
# tunneld 是 iOS 17+ 隧道方案的遗留常驻进程（占用 55553 端口与 usbmuxd 连接），本流程不需要
su -c "pkill -f 'pymobiledevice3 remote tunneld' 2>/dev/null; killall usbmuxd 2>/dev/null" || true
# usbmuxd 退出需要时间；仍存活则强杀，否则新实例会报 "Another instance is already running"
for i in 1 2 3 4 5; do
    su -c "pidof usbmuxd >/dev/null 2>&1" || break
    [ "$i" -ge 3 ] && su -c "killall -9 usbmuxd 2>/dev/null" || true
    sleep 1
done

echo "[*] 正在配置 Type-C 为 Host 模式..."
# 先切供电角色为 source（iPhone 默认抢到 source，安卓会停在 device/sink），再切数据角色为 host
su -c 'echo source > /sys/class/typec/port0/power_role 2>/dev/null; sleep 1; echo host > /sys/class/typec/port0/data_role 2>/dev/null'
sleep 2

echo "[*] 正在将 iPhone USB 配置切到 4..."
su -c '
for d in /sys/bus/usb/devices/*; do
  if [ -f "$d/idVendor" ] && [ "$(cat $d/idVendor 2>/dev/null)" = "05ac" ]; then
    echo 4 > "$d/bConfigurationValue" 2>/dev/null
  fi
done
chmod -R 777 /dev/bus/usb 2>/dev/null
'

# --- 4. 轮询等待配置 4 真正生效 ---
echo "[*] 正在等待 USB 枚举稳定 (接口 4.0/4.1/4.2)..."
CFG_OK=0
for i in 1 2 3 4 5 6; do
    sleep 1
    IFACES=$(su -c "ls /sys/bus/usb/devices/ 2>/dev/null")
    if echo "$IFACES" | grep -q "1-1:4.0"; then
        CFG_OK=1
        break
    fi
    su -c '
    for d in /sys/bus/usb/devices/*; do
      if [ -f "$d/idVendor" ] && [ "$(cat $d/idVendor 2>/dev/null)" = "05ac" ]; then
        echo 4 > "$d/bConfigurationValue" 2>/dev/null
      fi
    done
    '
done

if [ "$CFG_OK" = "1" ]; then
    echo "[+] USB 配置 4 已生效 (接口 4.0/4.1/4.2 就绪)"
else
    echo "[!] USB 配置 4 未生效，请检查 C-to-C 数据线是否插稳"
fi

# --- 5. 配置稳定后才启动 usbmuxd ---
echo "[*] 正在启动 usbmuxd..."
su -c "chmod -R 777 /dev/bus/usb; setsid env PATH=/data/data/com.termux/files/usr/bin:\$PATH $PROOT_BIN login ubuntu -- usbmuxd -f -v > $USBMUXD_LOG 2>&1 < /dev/null &"
sleep 3

echo "[*] 正在校验 usbmuxd 设备识别..."
if su -c "head -20 $USBMUXD_LOG 2>/dev/null" | grep -qE '[1-9][0-9]* device detected'; then
    DETECTED=$(su -c "head -20 $USBMUXD_LOG 2>/dev/null" | grep -oE '[1-9][0-9]* device detected' | head -1)
    echo "[+] usbmuxd 设备识别成功: $DETECTED"
else
    echo "[!] usbmuxd 未识别到设备，请检查:"
    echo "    - C-to-C 数据线是否插稳"
    echo "    - iPhone 是否已解锁并点击【信任此电脑】"
fi

# --- 6. 最终验证设备枚举 ---
echo "[*] 正在验证 iPhone 枚举..."
OUT=$(su -c "PATH=/data/data/com.termux/files/usr/bin:\$PATH $PROOT_BIN login ubuntu -- pymobiledevice3 lockdown info 2>/dev/null | head -c 300" 2>/dev/null)
if echo "$OUT" | grep -q "ActivationState"; then
    DEVNAME=$(echo "$OUT" | grep -o '"DeviceName"[^,]*' | head -1)
    DEVVER=$(echo "$OUT" | grep -o '"ProductVersion"[^,]*' | head -1)
    echo "[+] iPhone 握手成功: $DEVNAME $DEVVER"
else
    echo "[!] 未能握手到 iPhone"
fi

echo ""
echo "=============================================================="
echo " 服务已就绪！"
echo "   usbmuxd 日志: $USBMUXD_LOG"
echo "=============================================================="
