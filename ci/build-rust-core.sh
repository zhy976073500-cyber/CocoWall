#!/usr/bin/env bash
# Build cocowall-core (Rust) for the iOS device target and assemble
# Frameworks/CocoWallCore.xcframework, which project.yml links into the
# app. Runs on the CI macOS runner as an XcodeGen preBuildScript, before
# the app target compiles/links. Any failure here must fail the build —
# the app deliberately does not ship without the core linked.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found on this runner; cannot build cocowall-core" >&2
  exit 1
fi

# The device target is not part of every default toolchain install.
if command -v rustup >/dev/null 2>&1; then
  rustup target add aarch64-apple-ios
fi

export IPHONEOS_DEPLOYMENT_TARGET=17.0
cargo build --release --locked \
  --manifest-path rust-core/Cargo.toml \
  --target aarch64-apple-ios

rm -rf Frameworks/CocoWallCore.xcframework
xcodebuild -create-xcframework \
  -library rust-core/target/aarch64-apple-ios/release/libcocowall_core.a \
  -headers rust-core/include \
  -output Frameworks/CocoWallCore.xcframework

echo "CocoWallCore.xcframework assembled:"
ls -la Frameworks/CocoWallCore.xcframework
