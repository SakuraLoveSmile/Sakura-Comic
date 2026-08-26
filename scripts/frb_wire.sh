#!/usr/bin/env bash
# Wire flutter_rust_bridge between the Flutter shell and komga_core.
#
# FRB 2.x uses `flutter_rust_bridge_codegen generate` (the v1-style
# `integrate` command does not exist anymore). Regenerating this repo's
# bindings also requires the crate layout constraints below:
#   * rust-output must live inside android/komga_core/src so the codegen can
#     derive the module path (it is wired as `ffi::generated`, frb feature)
#   * the mirrored input module is `crate::ffi::bridge` (plain Rust types)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/android/komga_core"
APP="$ROOT/android/app"

command -v flutter_rust_bridge_codegen >/dev/null || {
  echo "missing flutter_rust_bridge_codegen — install: cargo install flutter_rust_bridge_codegen" >&2
  exit 1
}
command -v cargo-ndk >/dev/null || {
  echo "missing cargo-ndk — install: cargo install cargo-ndk" >&2
  exit 1
}
command -v flutter >/dev/null || {
  echo "missing flutter — add it to PATH (e.g. export PATH=\"\$HOME/flutter/bin:\$PATH\")" >&2
  exit 1
}

echo "==> rustup targets (Android)"
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android

echo "==> flutter_rust_bridge_codegen generate"
(cd "$APP" && flutter_rust_bridge_codegen generate \
  --rust-root "$CORE" \
  --rust-input crate::ffi::bridge \
  --rust-output "$CORE/src/ffi/generated/frb_generated.rs" \
  --dart-output "$APP/lib/src/rust" \
  --no-add-mod-to-lib)

echo "==> cargo-ndk build (arm64-v8a / armeabi-v7a / x86_64, features frb)"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
mkdir -p "$APP/android/app/src/main/jniLibs"
(cd "$CORE" && cargo ndk \
  -t arm64-v8a -t armeabi-v7a -t x86_64 \
  -o "$APP/android/app/src/main/jniLibs" \
  build --release --features frb)

echo "==> flutter analyze && flutter test"
(cd "$APP" && flutter analyze && flutter test)

echo "FRB WIRED — RustLibraryRepository now talks to komga_core"