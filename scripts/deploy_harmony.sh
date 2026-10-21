#!/usr/bin/env bash
set -e

DEVECO_HOME="/f/Programs/DevEco Studio"
export JAVA_HOME="$DEVECO_HOME/jbr"
export PATH="$JAVA_HOME/bin:$PATH"
HVIGORW="$DEVECO_HOME/tools/hvigor/bin/hvigorw.bat"
HDC="$DEVECO_HOME/sdk/default/openharmony/toolchains/hdc.exe"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/../harmony-app"
HAP_REL_PATH="entry/build/default/outputs/default/entry-default-unsigned.hap"
BUNDLE_NAME="com.cleanroom.immich"
ABILITY_NAME="EntryAbility"

echo "=== [1/3] Building HAP package via Hvigor ==="
cd "$PROJECT_DIR"
"$HVIGORW" assembleHap

echo ""
echo "=== [2/3] Installing HAP to HarmonyOS device/emulator ==="
"$HDC" install -r "$HAP_REL_PATH"

echo ""
echo "=== [3/3] Starting App ($BUNDLE_NAME) ==="
"$HDC" shell aa start -a "$ABILITY_NAME" -b "$BUNDLE_NAME"

echo ""
echo "=== [SUCCESS] App deployed and running successfully! ==="
