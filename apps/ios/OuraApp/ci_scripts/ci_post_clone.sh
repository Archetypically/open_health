#!/bin/sh
# Xcode Cloud post-clone script.
#
# Apple requires this to live in a `ci_scripts` directory NEXT TO the Xcode
# project, not at the repository root: Xcode Cloud looks for
# `<project dir>/ci_scripts/ci_post_clone.sh`, and a build whose script sits
# elsewhere logs "Post-Clone script not found" and then fails on the missing
# generated project. It also runs this script with that directory as its cwd, so
# every path here is derived from $0 rather than $PWD.
#
# What it does: a clean cloud checkout has no OuraCore.xcframework and no
# OuraApp.xcodeproj (both gitignored), so build the Rust UniFFI xcframework and
# generate the Xcode project the workflow archives.
#
# Two targets, chosen by OURA_CI_TORCH:
#   unset (default)  project-ci.yml        repo + Rust core only; syncs a real ring
#   1               project-torch-ci.yml   + vendored libtorch + the .ptl models
set -e
die() { echo "✗ ci_post_clone: $*" >&2; exit 1; }
APPDIR="$(cd "$(dirname "$0")/.." && pwd)"   # apps/ios/OuraApp — holds the .xcodeproj
REPO="$(cd "$APPDIR/../../.." && pwd)"     # repository root
echo "=== ci_post_clone: Rust xcframework + xcodegen ==="
echo "    project dir: $APPDIR"
echo "    repo root:   $REPO"
[ -f "$APPDIR/project-ci.yml" ] || die "no project spec at $APPDIR/project-ci.yml — wrong location?"

# Xcode Cloud clones shallow, so the commit count is not a usable version source
# (a depth-1 clone counts 1). TestFlight only requires a build number it has never
# seen, and runs of one workflow never share a minute, so stamp it from the clock.
# xcodegen expands ${CI_BUILD_NUMBER} in the specs.
CI_BUILD_NUMBER="${CI_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
export CI_BUILD_NUMBER

# xcodegen, to generate the project from the CI spec. Idempotent: newer Xcode
# Cloud images may already provide it, and `brew install` on an existing formula
# is fine, but skip it when present to avoid brew hiccups failing the clone.
command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
command -v xcodegen >/dev/null 2>&1 || die "xcodegen missing after brew install"

# Rust toolchain + the iOS targets build-xcframework.sh links. Idempotent: recent
# Xcode Cloud base images ship Rust, and `rustup-init -y` EXITS NON-ZERO when rustup
# is already installed (this was the ci_post_clone failure). Only install if missing.
if ! command -v rustup >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable
fi
# put cargo/rustup on PATH whether freshly installed or image-provided
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
rustup default stable 2>/dev/null || true
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

# OuraCore.xcframework (device + sim) from the committed UniFFI bindings
bash "$REPO/apps/ios/build-xcframework.sh"

SPEC=project-ci.yml

if [ "${OURA_CI_TORCH:-0}" = "1" ]; then
  SPEC=project-torch-ci.yml
  echo "==> torch build: vendored libtorch + the on-device .ptl models"

  # libtorch is BSD-licensed, so a public release-asset tarball needs no secret.
  # Build it ONCE locally (spike/build_libtorch_ios.sh, then with `device`, then
  # package-libtorch-xcframeworks.sh) and publish — CI must never run that CMake
  # build, it takes hours. The tarball holds the four .xcframework dirs plus the
  # include/ header tree that TorchBridge.mm compiles against; the packaging
  # script prints the exact tar command.
  : "${LIBTORCH_XCFRAMEWORKS_URL:?set LIBTORCH_XCFRAMEWORKS_URL to the release asset URL for libtorch-xcframeworks.tar.gz}"
  rm -rf "$REPO/apps/ios/libtorch-xcframeworks"
  mkdir -p "$REPO/apps/ios/libtorch-xcframeworks"
  curl -fsSL "$LIBTORCH_XCFRAMEWORKS_URL" | tar -xz -C "$REPO/apps/ios/libtorch-xcframeworks"

  # The .ptl models are decrypted Oura weights. They must never enter git — not even
  # LFS, not even a release on the public repo — so fetch each one from a private
  # store using a token kept in an Xcode Cloud environment variable. The spec
  # hardcodes these names under notes/models/mobile/, so they land there verbatim.
  : "${MODELS_BASE_URL:?set MODELS_BASE_URL to the private prefix holding the .ptl files}"
  : "${MODELS_TOKEN:?set MODELS_TOKEN to the bearer token for that store}"
  mkdir -p "$REPO/notes/models/mobile"
  for m in sleepnet_moonstone_1_2_0 cva_2_1_0 automatic_activity_detection_3_1_11 \
           steps_motion_decoder_2_0_0 illness_detection_0_5_1; do
    echo "    $m.ptl"
    curl -fsSL -H "Authorization: Bearer $MODELS_TOKEN" \
      "$MODELS_BASE_URL/$m.ptl" -o "$REPO/notes/models/mobile/$m.ptl"
  done
fi

# the model-free or torch Xcode project the Xcode Cloud workflow builds + archives
cd "$APPDIR"
xcodegen generate --spec "$SPEC"

# The archive action fails with a bare "Project OuraApp.xcodeproj does not exist"
# if this step silently produced nothing, so prove the project is there and say
# where — that turns an unactionable action error into a readable post-clone one.
PROJ="$APPDIR/OuraApp.xcodeproj"
[ -f "$PROJ/project.pbxproj" ] || die "xcodegen wrote no project at $PROJ"
echo "    project: $PROJ"
[ -f "$REPO/apps/ios/OuraCore.xcframework/Info.plist" ] \
  || die "no OuraCore.xcframework — build-xcframework.sh did not finish"

echo "=== ci_post_clone done ($SPEC, build $CI_BUILD_NUMBER) ==="
