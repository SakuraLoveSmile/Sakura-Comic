#!/usr/bin/env bash
# Stage 3 live acceptance (vertical slice): 
#   添加服务器 → 认证 → 拉取 Series → SQLite → Cover → SQLite 查询 → 封面墙数据
#
# Offline half always runs (fixtures, no network); the live half runs when
# KOMGA_BASE_URL / KOMGA_API_KEY are set.
# Env: KOMGA_BASE_URL, KOMGA_API_KEY, KOMGA_SERVER_ID (default demo),
#      KOMGA_DB (default /tmp/comic-stage3-live.sqlite)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_ID="${KOMGA_SERVER_ID:-demo}"
DB="${KOMGA_DB:-/tmp/comic-stage3-live.sqlite}"
mkdir -p "$(dirname "$DB")"
rm -f "$DB"
rm -rf "$(dirname "$DB")/cache"

echo "== 1/3 Offline fixture chain (no network) =="
(cd "$ROOT/android/komga_core" && cargo run --quiet --bin phase0_smoke -- \
  --fixture --db "$DB" --server-id "$SERVER_ID")

if [[ -n "${KOMGA_BASE_URL:-}" && -n "${KOMGA_API_KEY:-}" ]]; then
  echo "== 2/3 Live: 添加服务器 → 认证 → 验证 → 保存 Profile =="
  (cd "$ROOT/android/komga_core" && cargo run --quiet --bin stage2_smoke -- \
    --db "$DB" --base-url "$KOMGA_BASE_URL" --api-key "$KOMGA_API_KEY")

  echo "== 3/3 Live: 拉取 Series → SQLite → Cover → SQLite 查询 =="
  (cd "$ROOT/android/komga_core" && cargo run --quiet --bin phase0_smoke -- \
    --db "$DB" --server-id "$SERVER_ID" \
    --base-url "$KOMGA_BASE_URL" --api-key "$KOMGA_API_KEY")
else
  echo "== 2-3/3 skipped: set KOMGA_BASE_URL + KOMGA_API_KEY for the live chain =="
fi

echo "STAGE 3 ACCEPTANCE OK (offline chain complete; live chain ran when env was set)"