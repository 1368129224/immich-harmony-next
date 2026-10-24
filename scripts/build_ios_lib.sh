#!/usr/bin/env bash
# ==============================================================================
# iOS Static Library & XCFramework Build Script for Immich Native iOS App
# Crate: crates/immich-ios-ffi
# Output: ios-app/Runner/libs/
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Ensure cargo/rustup are in PATH
for p in "$HOME/.cargo/bin" "/opt/homebrew/bin" "/usr/local/bin"; do
    if [ -d "$p" ] && [[ ":$PATH:" != *":$p:"* ]]; then
        export PATH="$p:$PATH"
    fi
done

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

BUILD_MODE_RAW="${1:-release}"
BUILD_MODE="$(echo "$BUILD_MODE_RAW" | tr '[:upper:]' '[:lower:]')"

CARGO_FLAGS=()
if [ "$BUILD_MODE" = "release" ]; then
    CARGO_FLAGS+=(--release)
fi

# Detect platform
OS_NAME="$(uname -s)"

if [ "$OS_NAME" = "Darwin" ]; then
    echo "==> Running on macOS. Compiling for iOS and iOS Simulator targets..."

    if ! command -v cargo &> /dev/null; then
        echo "[ERROR] 'cargo' command not found in PATH." >&2
        echo "Please install Rust (https://rustup.rs) or add cargo to PATH." >&2
        exit 1
    fi

    # Device target is primary; simulator target is optional
    TARGETS=("aarch64-apple-ios")

    for TARGET in "${TARGETS[@]}"; do
        if command -v rustup &> /dev/null; then
            if ! rustup target list 2>/dev/null | grep -q "${TARGET} (installed)"; then
                echo "--> Target ${TARGET} not installed. Installing via rustup..."
                rustup target add "${TARGET}" || true
            fi
        fi

        echo "--> Building target: ${TARGET}..."
        if [ ${#CARGO_FLAGS[@]} -gt 0 ]; then
            cargo build --target "${TARGET}" "${CARGO_FLAGS[@]}"
        else
            cargo build --target "${TARGET}"
        fi
    done

    DEVICE_ARM="${REPO_ROOT}/target/aarch64-apple-ios/${BUILD_MODE}/libimmich_ios_ffi.a"

    if [ -f "${DEVICE_ARM}" ]; then
        cp -f "${DEVICE_ARM}" "${OUTPUT_DIR}/libimmich_ios_ffi.a"
        echo "[OK] Installed iOS device static library to ${OUTPUT_DIR}/libimmich_ios_ffi.a"
    else
        echo "[ERROR] Expected built library not found at: ${DEVICE_ARM}" >&2
        exit 1
    fi

    # Also build simulator if rustup has simulator targets or user requests
    if command -v rustup &> /dev/null; then
        SIM_TARGETS=("aarch64-apple-ios-sim" "x86_64-apple-ios")
        for SIM_TARGET in "${SIM_TARGETS[@]}"; do
            if rustup target list 2>/dev/null | grep -q "${SIM_TARGET} (installed)"; then
                echo "--> Building optional simulator target: ${SIM_TARGET}..."
                if [ ${#CARGO_FLAGS[@]} -gt 0 ]; then
                    cargo build --target "${SIM_TARGET}" "${CARGO_FLAGS[@]}" || true
                else
                    cargo build --target "${SIM_TARGET}" || true
                fi
            fi
        done

        SIM_ARM="${REPO_ROOT}/target/aarch64-apple-ios-sim/${BUILD_MODE}/libimmich_ios_ffi.a"
        SIM_X64="${REPO_ROOT}/target/x86_64-apple-ios/${BUILD_MODE}/libimmich_ios_ffi.a"
        if [ -f "${SIM_ARM}" ] && [ -f "${SIM_X64}" ]; then
            lipo -create "${SIM_ARM}" "${SIM_X64}" -output "${OUTPUT_DIR}/libimmich_ios_ffi_sim.a" || true
        elif [ -f "${SIM_ARM}" ]; then
            cp -f "${SIM_ARM}" "${OUTPUT_DIR}/libimmich_ios_ffi_sim.a" 2>/dev/null || true
        fi
    fi
else
    echo "==> Running on Linux/Non-Darwin host."
    echo "--> Building host library for validation and tests..."
    if [ ${#CARGO_FLAGS[@]} -gt 0 ]; then
        cargo build "${CARGO_FLAGS[@]}"
    else
        cargo build
    fi
    HOST_LIB="${REPO_ROOT}/target/${BUILD_MODE}/libimmich_ios_ffi.a"
    if [ -f "${HOST_LIB}" ]; then
        cp -f "${HOST_LIB}" "${OUTPUT_DIR}/libimmich_ios_ffi_host.a"
        echo "[OK] Installed host static library to ${OUTPUT_DIR}/libimmich_ios_ffi_host.a"
    fi
fi

echo "===================================================================="
echo " Rust iOS FFI build step completed."
echo "===================================================================="
