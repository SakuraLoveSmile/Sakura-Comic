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
for arg in "$@"; do
  case "$arg" in
    --skip-flutter) SKIP_FLUTTER=1 ;;
    --skip-swift) SKIP_SWIFT=1 ;;
    --skip-android) SKIP_ANDROID=1 ;;
    --skip-frb) SKIP_FRB=1 ;;
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
# surface. Today the only thing that notices a stale binding is a runtime decode
# error on a phone: adding a field to a DTO compiles fine on both sides, the
# generated codec simply keeps sending the old shape. The check runs the real
# codegen and compares the result, then puts the tree back exactly as it found it
# so that verifying never overwrites work in progress.
if [ "$SKIP_FRB" -eq 0 ]; then
  if command -v flutter_rust_bridge_codegen >/dev/null 2>&1 && [ -d "$ROOT/android/app/lib/src/rust" ]; then
    echo "==> frb glue is in sync with crate::ffi::bridge"
    FRB_BACKUP="$ROOT/android/app/.frb-verify-backup.$$"
    mkdir -p "$FRB_BACKUP"
    cp -R "$ROOT/android/app/lib/src/rust" "$FRB_BACKUP/dart"
    cp "$ROOT/android/komga_core/src/ffi/generated/frb_generated.rs" "$FRB_BACKUP/frb_generated.rs"
    set +e
    (cd "$ROOT/android/app" && flutter_rust_bridge_codegen generate \
        --rust-root "$ROOT/android/komga_core" \
        --rust-input crate::ffi::bridge \
        --rust-output "$ROOT/android/komga_core/src/ffi/generated/frb_generated.rs" \
        --dart-output "$ROOT/android/app/lib/src/rust" \
        --no-add-mod-to-lib > "$FRB_BACKUP/codegen.log" 2>&1)
    CODEGEN=$?
    set -e
    DRIFT=""
    if [ "$CODEGEN" -ne 0 ]; then
      DRIFT="codegen failed (see below)"
      tail -15 "$FRB_BACKUP/codegen.log" >&2
    elif ! diff -r -q "$FRB_BACKUP/dart" "$ROOT/android/app/lib/src/rust" >/dev/null 2>&1; then
      DRIFT="generated Dart differs"
      diff -r -q "$FRB_BACKUP/dart" "$ROOT/android/app/lib/src/rust" | head -10 >&2
    elif ! cmp -s "$FRB_BACKUP/frb_generated.rs" "$ROOT/android/komga_core/src/ffi/generated/frb_generated.rs"; then
      DRIFT="generated Rust differs"
      diff "$FRB_BACKUP/frb_generated.rs" "$ROOT/android/komga_core/src/ffi/generated/frb_generated.rs" | head -20 >&2
    fi
    rm -rf "$ROOT/android/app/lib/src/rust"
    cp -R "$FRB_BACKUP/dart" "$ROOT/android/app/lib/src/rust"
    cp "$FRB_BACKUP/frb_generated.rs" "$ROOT/android/komga_core/src/ffi/generated/frb_generated.rs"
    rm -rf "$FRB_BACKUP"
    if [ -n "$DRIFT" ]; then
      echo "frb glue is stale: $DRIFT" >&2
      echo "run scripts/frb_wire.sh (or the codegen step alone) and commit the result" >&2
      exit 1
    fi
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

echo "ALL GREEN"
