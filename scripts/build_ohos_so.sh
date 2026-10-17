#!/usr/bin/env bash
# ==============================================================================
# Linux NAS One-Click N-API Build & Copy Script for Immich HarmonyOS NEXT
# Cross-compiles .so binaries:
#   - x86_64 for Windows DevEco Studio Emulator
#   - arm64-v8a for Real HarmonyOS NEXT Devices
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Ensure cargo/ohrs environment
if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
fi

if ! command -v ohrs &> /dev/null; then
    echo "==> [WARN] 'ohrs' CLI tool not found in PATH. Checking ~/.cargo/bin/ohrs..."
    if [ -x "$HOME/.cargo/bin/ohrs" ]; then
        export PATH="$HOME/.cargo/bin:$PATH"
    else
        echo "==> [INFO] Installing ohrs CLI..."
        cargo install ohrs
    fi
fi

CRATE_DIR="${REPO_ROOT}/crates/immich-ohos-napi"
LIBS_ROOT="${REPO_ROOT}/harmony-app/entry/libs"
TARGET_X64_DIR="${LIBS_ROOT}/x86_64"
TARGET_ARM64_DIR="${LIBS_ROOT}/arm64-v8a"

mkdir -p "${TARGET_X64_DIR}" "${TARGET_ARM64_DIR}"

echo "===================================================================="
echo " Starting HarmonyOS NEXT N-API Build (ohos-rs)"
echo " Crate: crates/immich-ohos-napi"
echo " Targets: x86_64 (Emulator), arm64-v8a (Device)"
echo "===================================================================="

cd "${CRATE_DIR}"

# Run ohrs build for x86_64 and arm64
echo "==> Invoking ohrs build..."
if ohrs build -a x86_64 -a arm64 --release --dist dist; then
    echo "==> ohrs build completed successfully!"

    # Copy x86_64 binary
    if [ -f "dist/x86_64/libimmich_ohos_napi.so" ]; then
        cp -f "dist/x86_64/libimmich_ohos_napi.so" "${TARGET_X64_DIR}/"
        echo "  [OK] Copied x86_64 .so to ${TARGET_X64_DIR}/libimmich_ohos_napi.so"
    elif [ -f "dist/x64/libimmich_ohos_napi.so" ]; then
        cp -f "dist/x64/libimmich_ohos_napi.so" "${TARGET_X64_DIR}/"
        echo "  [OK] Copied x64 .so to ${TARGET_X64_DIR}/libimmich_ohos_napi.so"
    fi

    # Copy arm64-v8a binary
    if [ -f "dist/arm64-v8a/libimmich_ohos_napi.so" ]; then
        cp -f "dist/arm64-v8a/libimmich_ohos_napi.so" "${TARGET_ARM64_DIR}/"
        echo "  [OK] Copied arm64-v8a .so to ${TARGET_ARM64_DIR}/libimmich_ohos_napi.so"
    elif [ -f "dist/arm64/libimmich_ohos_napi.so" ]; then
        cp -f "dist/arm64/libimmich_ohos_napi.so" "${TARGET_ARM64_DIR}/"
        echo "  [OK] Copied arm64 .so to ${TARGET_ARM64_DIR}/libimmich_ohos_napi.so"
    fi

    # Copy index.d.ts if generated
    if [ -f "dist/index.d.ts" ]; then
        cp -f "dist/index.d.ts" "${REPO_ROOT}/harmony-app/entry/src/main/ets/bridge/"
        echo "  [OK] Copied index.d.ts to harmony-app bridge directory"
    fi
else
    echo "==> [NOTICE] ohrs build reported notice/status. If OpenHarmony Native SDK is not"
    echo "    configured in this environment, please set OHOS_NDK_HOME or build on a system"
    echo "    with HarmonyOS Command Line Tools installed."
fi

echo "===================================================================="
echo " Build script finished."
echo "===================================================================="
