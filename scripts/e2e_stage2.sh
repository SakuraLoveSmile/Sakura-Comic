#!/usr/bin/env bash
# Stage 2 live acceptance against a real Komga server:
#   Rust core (stage2_smoke) + Apple (LiveConnectionTests).
# Env: KOMGA_BASE_URL, KOMGA_API_KEY (required);
#      KOMGA_DB (default /tmp/comic-stage2-live.sqlite)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${KOMGA_BASE_URL:?set KOMGA_BASE_URL (e.g. http://192.168.0.69:25600)}"
: "${KOMGA_API_KEY:?set KOMGA_API_KEY}"
DB="${KOMGA_DB:-/tmp/comic-stage2-live.sqlite}"

echo "== Android (Rust core) — stage2_smoke live =="
(cd "$ROOT/android/komga_core" && cargo run --quiet --bin stage2_smoke -- \
  --db "$DB" --base-url "$KOMGA_BASE_URL" --api-key "$KOMGA_API_KEY")

echo "== Apple (Swift) — LiveConnectionTests =="
(cd "$ROOT/apple/KomgaKit" && KOMGA_BASE_URL="$KOMGA_BASE_URL" KOMGA_API_KEY="$KOMGA_API_KEY" \
  swift test --filter LiveConnectionTests)

echo "STAGE 2 LIVE ACCEPTANCE OK"