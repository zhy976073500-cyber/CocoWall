#!/usr/bin/env bash
# Build cocowall-core (Rust) for the iOS device target. The resulting
# static library is linked into the app via OTHER_LDFLAGS and its C
# module is exposed to Swift via SWIFT_INCLUDE_PATHS (see project.yml),
# so nothing in the generated project references a file that only comes
# into existence here. Runs on the CI macOS runner as an XcodeGen
# preBuildScript. Any failure must fail the build — the app deliberately
# does not ship without the core linked.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export PATH="$HOME/.cargo/bin:$PATH"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found; bootstrapping a minimal rustup toolchain…"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain stable
  export PATH="$HOME/.cargo/bin:$PATH"
fi

command -v cargo
cargo --version
rustc --version

# The device target is not part of every default toolchain install.
if command -v rustup >/dev/null 2>&1; then
  rustup target add aarch64-apple-ios
fi

export IPHONEOS_DEPLOYMENT_TARGET=17.0
cargo build --release --locked \
  --manifest-path rust-core/Cargo.toml \
  --target aarch64-apple-ios

ls -la rust-core/target/aarch64-apple-ios/release/libcocowall_core.a
echo "cocowall-core static library ready."
