#!/usr/bin/env bash
# Phase 0 acceptance: real server -> auth -> series (10) -> SQLite -> cover cache.
# Env: KOMGA_BASE_URL, KOMGA_API_KEY (required);
#      KOMGA_SERVER_ID (default demo), KOMGA_DB (default /tmp/comic-phase0.sqlite)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${KOMGA_BASE_URL:?set KOMGA_BASE_URL (e.g. http://192.168.1.10:25600)}"
: "${KOMGA_API_KEY:?set KOMGA_API_KEY}"
SERVER_ID="${KOMGA_SERVER_ID:-demo}"
DB="${KOMGA_DB:-/tmp/comic-phase0.sqlite}"

echo "server_id=$SERVER_ID db=$DB base_url=$KOMGA_BASE_URL"
(cd "$ROOT/android/komga_core" && cargo run --bin phase0_smoke -- \
  --db "$DB" --server-id "$SERVER_ID" --base-url "$KOMGA_BASE_URL" --api-key "$KOMGA_API_KEY")
