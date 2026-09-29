#!/bin/bash
# Build the shared Rust core (oura-core) for iOS device + simulator and package the
# OuraCore.xcframework the app links. Re-run after changing any Rust core code.
#
# The simulator-only dev harness (OuraApp/build_run.sh) refreshes just the sim slice;
# this produces BOTH slices, which a device build / TestFlight archive needs.
set -euo pipefail
cd "$(dirname "$0")/../.."

# Linking an iOS dylib needs the real iPhoneOS SDK, which ships only with a full
# Xcode. If xcode-select still points at bare CommandLineTools, point the tools
# at an installed Xcode for this script only (no sudo needed).
if ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  DEV_DIR="$(ls -d /Applications/Xcode*.app/Contents/Developer 2>/dev/null | head -1)"
  if [ -z "$DEV_DIR" ]; then
    echo "✗ iPhoneOS SDK not found. Install Xcode, or run:" >&2
    echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
  fi
  export DEVELOPER_DIR="$DEV_DIR"
  echo "==> DEVELOPER_DIR=$DEV_DIR (xcode-select points at $(xcode-select -p))"
fi
REPO="$PWD"
HEADERS="$REPO/apps/ios/generated/headers"   # UniFFI header + module.modulemap
OUT="$REPO/apps/ios/OuraCore.xcframework"
LIB="liboura_core.a"

for t in aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup target list --installed | grep -qx "$t" || rustup target add "$t"
done

echo "==> regenerate matching Swift bindings and headers"
cargo build -p oura-core
cargo run -p oura-core --bin uniffi-bindgen -- generate \
  --library "$REPO/target/debug/liboura_core.dylib" --language swift \
  --out-dir "$REPO/apps/ios/generated"
cp "$REPO/apps/ios/generated/oura_coreFFI.h" "$HEADERS/oura_coreFFI.h"

echo "==> build oura-core (release) for device + simulator"
cargo build -p oura-core --release --target aarch64-apple-ios
cargo build -p oura-core --release --target aarch64-apple-ios-sim

rm -rf "$OUT"
echo "==> create xcframework"
xcodebuild -create-xcframework \
  -library "$REPO/target/aarch64-apple-ios/release/$LIB"     -headers "$HEADERS" \
  -library "$REPO/target/aarch64-apple-ios-sim/release/$LIB" -headers "$HEADERS" \
  -output "$OUT"
echo "✓ $OUT"
