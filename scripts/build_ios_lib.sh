#!/usr/bin/env bash
# ==============================================================================
# iOS Static Library & XCFramework Build Script for Immich Native iOS App
# Crate: crates/immich-ios-ffi
# Output: ios-app/Runner/libs/ or Frameworks
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "$HOME/.cargo/env" ]; then
    # shellcheck source=/dev/null
    source "$HOME/.cargo/env"
fi

CRATE_DIR="${REPO_ROOT}/crates/immich-ios-ffi"
OUTPUT_DIR="${REPO_ROOT}/ios-app/Runner/libs"
HEADER_SRC="${CRATE_DIR}/include/immich_core_ffi.h"
HEADER_DEST="${REPO_ROOT}/ios-app/Runner/immich_core_ffi.h"

mkdir -p "${OUTPUT_DIR}"

echo "===================================================================="
echo " Building Rust iOS FFI Core (immich-ios-ffi)"
echo " Crate: crates/immich-ios-ffi"
echo "===================================================================="

cd "${CRATE_DIR}"

# Copy C header
cp -f "${HEADER_SRC}" "${HEADER_DEST}"
echo "[OK] Synchronized C header to: ${HEADER_DEST}"

BUILD_MODE="${1:-release}"
CARGO_FLAGS=()
if [ "$BUILD_MODE" = "release" ]; then
    CARGO_FLAGS+=(--release)
fi

# Detect platform
OS_NAME="$(uname -s)"

if [ "$OS_NAME" = "Darwin" ]; then
    echo "==> Running on macOS. Compiling for iOS and iOS Simulator targets..."
    
    TARGETS=("aarch64-apple-ios" "aarch64-apple-ios-sim" "x86_64-apple-ios")
    for TARGET in "${TARGETS[@]}"; do
        if rustup target list | grep -q "${TARGET} (installed)"; then
            echo "--> Building target: ${TARGET}..."
            cargo build --target "${TARGET}" "${CARGO_FLAGS[@]}"
        else
            echo "--> Target ${TARGET} not installed. Installing via rustup..."
            rustup target add "${TARGET}" || true
            cargo build --target "${TARGET}" "${CARGO_FLAGS[@]}" || echo "Skipping ${TARGET}"
        fi
    done

    # Create universal simulator lib if both exist
    SIM_ARM="${REPO_ROOT}/target/aarch64-apple-ios-sim/${BUILD_MODE}/libimmich_ios_ffi.a"
    SIM_X64="${REPO_ROOT}/target/x86_64-apple-ios/${BUILD_MODE}/libimmich_ios_ffi.a"
    DEVICE_ARM="${REPO_ROOT}/target/aarch64-apple-ios/${BUILD_MODE}/libimmich_ios_ffi.a"

    if [ -f "${DEVICE_ARM}" ]; then
        cp -f "${DEVICE_ARM}" "${OUTPUT_DIR}/libimmich_ios_ffi_device.a"
        echo "[OK] Installed iOS device static library."
    fi

    if [ -f "${SIM_ARM}" ] && [ -f "${SIM_X64}" ]; then
        lipo -create "${SIM_ARM}" "${SIM_X64}" -output "${OUTPUT_DIR}/libimmich_ios_ffi_sim.a"
        echo "[OK] Created universal iOS Simulator library via lipo."
    elif [ -f "${SIM_ARM}" ]; then
        cp -f "${SIM_ARM}" "${OUTPUT_DIR}/libimmich_ios_ffi_sim.a"
        echo "[OK] Installed arm64 iOS Simulator library."
    fi
else
    echo "==> Running on Linux/Non-Darwin host."
    echo "--> Building host library for validation and tests..."
    cargo build "${CARGO_FLAGS[@]}"
    HOST_LIB="${REPO_ROOT}/target/${BUILD_MODE}/libimmich_ios_ffi.a"
    if [ -f "${HOST_LIB}" ]; then
        cp -f "${HOST_LIB}" "${OUTPUT_DIR}/libimmich_ios_ffi_host.a"
        echo "[OK] Installed host static library to ${OUTPUT_DIR}/libimmich_ios_ffi_host.a"
    fi
fi

echo "===================================================================="
echo " Rust iOS FFI build step completed."
echo "===================================================================="
