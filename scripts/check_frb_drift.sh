#!/usr/bin/env bash
# Verifies flutter_rust_bridge generated bindings in an isolated temporary clone.
# Ensures the working tree is NEVER modified or overwritten on success, failure,
# diff detection, or process interruption.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

command -v flutter_rust_bridge_codegen >/dev/null || {
  echo "missing flutter_rust_bridge_codegen — install: cargo install flutter_rust_bridge_codegen --version 2.13.0" >&2
  exit 1
}

# Locate flutter / dart if not in current PATH
if ! command -v flutter >/dev/null && ! command -v dart >/dev/null; then
  for p in "$HOME/flutter/bin" "/Users/sakurasep/flutter/bin" "/usr/local/bin"; do
    if [ -x "$p/flutter" ] || [ -x "$p/dart" ]; then
      export PATH="$p:$PATH"
      break
    fi
  done
fi

if ! command -v flutter >/dev/null && ! command -v dart >/dev/null; then
  echo "missing flutter/dart toolchain — needed by flutter_rust_bridge_codegen" >&2
  exit 1
fi

TMPDIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'frb_drift')"
# Resolve physical path (important for macOS /var -> /private/var symlink)
TMPDIR="$(cd "$TMPDIR" && pwd -P)"
trap 'rm -rf "$TMPDIR"' EXIT INT TERM HUP

CORE_DST="$TMPDIR/komga_core"
APP_DST="$TMPDIR/app"

echo "==> Preparing isolated sandbox for FRB codegen..."
mkdir -p "$CORE_DST" "$APP_DST"

# Copy komga_core excluding target and git
if command -v rsync >/dev/null 2>&1; then
  rsync -a --exclude 'target' --exclude '.git' "$ROOT/android/komga_core/" "$CORE_DST/"
  rsync -a --exclude 'build' --exclude '.git' --exclude 'lib' "$ROOT/android/app/" "$APP_DST/"
else
  cp -R "$ROOT/android/komga_core" "$TMPDIR/"
  rm -rf "$CORE_DST/target"
  cp -R "$ROOT/android/app" "$TMPDIR/"
  rm -rf "$APP_DST/build" "$APP_DST/lib"
fi
mkdir -p "$APP_DST/lib/src/rust"

echo "==> Running flutter_rust_bridge_codegen in isolation..."
CODEGEN_LOG="$TMPDIR/codegen.log"
set +e
(cd "$APP_DST" && flutter_rust_bridge_codegen generate \
  --rust-root "$CORE_DST" \
  --rust-input crate::ffi::bridge \
  --rust-output "$CORE_DST/src/ffi/generated/frb_generated.rs" \
  --dart-output "$APP_DST/lib/src/rust" \
  --no-add-mod-to-lib > "$CODEGEN_LOG" 2>&1)
CODEGEN_EXIT=$?
set -e

if [ "$CODEGEN_EXIT" -ne 0 ]; then
  echo "::error::flutter_rust_bridge_codegen failed in isolation (exit code $CODEGEN_EXIT):" >&2
  cat "$CODEGEN_LOG" >&2
  exit 1
fi

echo "==> Comparing generated bindings with repository files..."
DRIFT=0

if ! cmp -s "$CORE_DST/src/ffi/generated/frb_generated.rs" "$ROOT/android/komga_core/src/ffi/generated/frb_generated.rs"; then
  echo "::error::Generated Rust binding differs from repository!" >&2
  diff -u "$ROOT/android/komga_core/src/ffi/generated/frb_generated.rs" "$CORE_DST/src/ffi/generated/frb_generated.rs" | head -30 >&2 || true
  DRIFT=1
fi

# Formatter behaviour drifts across Dart releases (3.7 folds short constructors
# that 3.11 expands), so a byte-compare fails on cosmetics even when the
# bindings are semantically identical. `dart format` resolves a file's language
# version from the surrounding package context, so both sides are normalised
# inside the SAME sandbox package by THIS toolchain — real drift still fails.
DART_BIN="$(command -v dart || true)"
if [ -z "$DART_BIN" ]; then
  DART_BIN="$(dirname "$(command -v flutter)")/dart"
fi
REPO_DART="$APP_DST/lib/repo_rust"
cp -R "$ROOT/android/app/lib/src/rust" "$REPO_DART"
mv "$APP_DST/lib/src/rust" "$APP_DST/lib/gen_rust"
"$DART_BIN" format "$APP_DST/lib/gen_rust" "$REPO_DART" >/dev/null

if ! diff -r -q "$APP_DST/lib/gen_rust" "$REPO_DART" >/dev/null 2>&1; then
  echo "::error::Generated Dart bindings differ from repository!" >&2
  diff -r -u "$REPO_DART" "$APP_DST/lib/gen_rust" | head -50 >&2 || true
  DRIFT=1
fi

if [ "$DRIFT" -ne 0 ]; then
  echo "" >&2
  echo "FRB bindings are stale! Please run 'scripts/frb_wire.sh' and commit the updated bindings." >&2
  exit 1
fi

echo "FRB bindings in sync (isolated check passed, working tree untouched)."
