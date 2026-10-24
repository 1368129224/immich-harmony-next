#!/usr/bin/env bash
# Build, install, and launch the native iOS app on a connected device (macOS).
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

DEVICE_NAME="${DEVICE_NAME:-Z iPhone}"
DEVICE_ID="${DEVICE_ID:-C7BF9256-B5F7-5C5F-AD9B-84A635AC2034}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-PSTQ6HRBKY}"
TARGET_DEVICE="${TARGET_DEVICE:-${DEVICE_ID:-$DEVICE_NAME}}"
PROJECT="$ROOT/ios-app/Runner.xcodeproj"
SCHEME="Runner"
CONFIG="${CONFIG:-Release}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build/ios/device}"

[[ "$(uname -s)" == Darwin ]] || {
  echo "This script requires macOS, Xcode, and a connected iOS device." >&2
  exit 1
}

# 1. Compile Rust iOS FFI Core library
echo "🦀 [0/3] 正在编译 Rust 核心库 (immich-ios-ffi)..."
bash "$ROOT/scripts/build_ios_lib.sh" "$CONFIG"

# 2. Build native Xcode project
echo "🔨 [1/3] 正在编译原生项目 ($CONFIG)..."
XCODEBUILD_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIG"
  -destination "platform=iOS,name=$DEVICE_NAME"
  -derivedDataPath "$BUILD_DIR"
  -allowProvisioningUpdates
)

if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  XCODEBUILD_ARGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi

xcodebuild "${XCODEBUILD_ARGS[@]}" build

APP_PATH="$BUILD_DIR/Build/Products/${CONFIG}-iphoneos/${SCHEME}.app"
[[ -d "$APP_PATH" ]] || { echo "Missing app bundle: $APP_PATH" >&2; exit 1; }
python3 "$ROOT/scripts/check_native_ios.py" --app "$APP_PATH"

echo "📲 [2/3] 正在安装 ${SCHEME}.app 到 $DEVICE_NAME ($TARGET_DEVICE)..."
xcrun devicectl device install app --device "$TARGET_DEVICE" "$APP_PATH"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Info.plist")"
echo "🚀 [3/3] 正在手机上启动应用 ($BUNDLE_ID)..."
xcrun devicectl device process launch --device "$TARGET_DEVICE" "$BUNDLE_ID"

echo "✅ 全部搞定！"
