#!/usr/bin/env bash
# Runs the verification suites: Rust (host), Rust (the Android target the app
# actually ships), the generated FFI glue, Swift, Flutter.
# Usage: scripts/verify.sh [--skip-flutter] [--skip-swift] [--skip-android] [--skip-frb]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKIP_FLUTTER=0
SKIP_SWIFT=0
SKIP_ANDROID=0
SKIP_FRB=0
WITH_APPLE_APPS=0

if ! command -v flutter >/dev/null 2>&1 && [ -d "$HOME/flutter/bin" ]; then
  export PATH="$HOME/flutter/bin:$PATH"
fi

for arg in "$@"; do
  case "$arg" in
    --skip-flutter) SKIP_FLUTTER=1 ;;
    --skip-swift) SKIP_SWIFT=1 ;;
    --skip-android) SKIP_ANDROID=1 ;;
    --skip-frb) SKIP_FRB=1 ;;
    --with-apple-apps) WITH_APPLE_APPS=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "==> cargo fmt --check"
(cd "$ROOT/android/komga_core" && cargo fmt --check)

echo "==> cargo clippy (all targets, warnings as errors)"
(cd "$ROOT/android/komga_core" && cargo clippy --all-targets -- -D warnings)

echo "==> cargo test"
(cd "$ROOT/android/komga_core" && cargo test)

# The Android target with the `frb` feature, cross-checked. This is a separate
# gate because the host build cannot see what it catches: under `frb` the facade
# runs inside an async runtime that moves futures between threads, so holding a
# rusqlite `Connection` across an `await` — which the host build compiles
# perfectly — is a hard error on the device target. It slipped through exactly
# once, and this step is why it cannot slip again.
if [ "$SKIP_ANDROID" -eq 0 ]; then
  export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
  if command -v cargo-ndk >/dev/null 2>&1 && [ -d "$ANDROID_HOME/ndk" ]; then
    echo "==> cargo ndk check --features frb (aarch64-linux-android)"
    (cd "$ROOT/android/komga_core" && cargo ndk -t arm64-v8a check --features frb)
  else
    echo "==> android cross-check skipped (no cargo-ndk or no NDK at $ANDROID_HOME/ndk)"
  fi
fi

# The generated flutter_rust_bridge glue, checked for drift against the Rust
# surface in an isolated temporary clone so it never touches working files.
if [ "$SKIP_FRB" -eq 0 ]; then
  if command -v flutter_rust_bridge_codegen >/dev/null 2>&1 && [ -d "$ROOT/android/app/lib/src/rust" ]; then
    bash "$ROOT/scripts/check_frb_drift.sh"
  else
    echo "==> frb sync check skipped (no flutter_rust_bridge_codegen)"
  fi
fi

if [ "$SKIP_SWIFT" -eq 0 ]; then
  echo "==> swift build && swift test (KomgaKit)"
  (cd "$ROOT/apple/KomgaKit" && swift build && swift test)
fi

if [ "$SKIP_FLUTTER" -eq 0 ]; then
  echo "==> flutter analyze && flutter test"
  (cd "$ROOT/android/app" && flutter analyze && flutter test)
fi

if [ "$WITH_APPLE_APPS" -eq 1 ]; then
  echo "==> xcodegen generate && xcodebuild (macOS & iOS)"
  (cd "$ROOT/apple/ComicApp" && xcodegen generate && \
   xcodebuild -scheme ComicApp_macOS -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO && \
   xcodebuild -scheme ComicApp_iOS -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO)
fi

echo "ALL GREEN"
