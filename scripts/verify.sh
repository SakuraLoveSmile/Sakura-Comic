#!/usr/bin/env bash
# Runs the three Phase 0 verification suites.
# Usage: scripts/verify.sh [--skip-flutter] [--skip-swift]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKIP_FLUTTER=0
SKIP_SWIFT=0
for arg in "$@"; do
  case "$arg" in
    --skip-flutter) SKIP_FLUTTER=1 ;;
    --skip-swift) SKIP_SWIFT=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "==> cargo fmt --check"
(cd "$ROOT/android/komga_core" && cargo fmt --check)

echo "==> cargo clippy (all targets, warnings as errors)"
(cd "$ROOT/android/komga_core" && cargo clippy --all-targets -- -D warnings)

echo "==> cargo test"
(cd "$ROOT/android/komga_core" && cargo test)

if [ "$SKIP_SWIFT" -eq 0 ]; then
  echo "==> swift build && swift test (KomgaKit)"
  (cd "$ROOT/apple/KomgaKit" && swift build && swift test)
fi

if [ "$SKIP_FLUTTER" -eq 0 ]; then
  echo "==> flutter analyze && flutter test"
  (cd "$ROOT/android/app" && flutter analyze && flutter test)
fi

echo "ALL GREEN"
