#!/usr/bin/env bash
# Stage 4 live acceptance (full media library):
#   FullSync（Series → Books → Collections → Readlists → Progress → Covers）
#   → 离线查询电池（搜索/筛选/排序/分页/Continue Reading 全部走 SQLite）
#   → --offline 重放（无任何网络路径，模拟断网后浏览）
#
# Offline half always runs (fixtures, no network); the live half runs when
# KOMGA_BASE_URL / KOMGA_API_KEY are set.
# Env: KOMGA_BASE_URL, KOMGA_API_KEY, KOMGA_SERVER_ID (default stage4),
#      KOMGA_DB (default /tmp/comic-stage4-live.sqlite)
set -euo pipefail

# cargo may live outside the caller's PATH (rustup layout).
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_ID="${KOMGA_SERVER_ID:-stage4}"
DB="${KOMGA_DB:-/tmp/comic-stage4-live.sqlite}"
mkdir -p "$(dirname "$DB")"
rm -f "$DB"
rm -rf "$(dirname "$DB")/cache"

SMOKE=(cargo run --quiet --bin stage4_smoke --)

echo "== 1/3 Offline fixture battery (no network) =="
(cd "$ROOT/android/komga_core" && "${SMOKE[@]}" \
  --fixture --db "$DB" --server-id demo)

echo "== 2/3 Offline replay on the fixture DB (network disconnected) =="
(cd "$ROOT/android/komga_core" && "${SMOKE[@]}" \
  --offline --db "$DB" --server-id demo)

if [[ -n "${KOMGA_BASE_URL:-}" && -n "${KOMGA_API_KEY:-}" ]]; then
  echo "== 3/3 Live: FullSync 完整媒体库 + 离线查询电池 =="
  (cd "$ROOT/android/komga_core" && "${SMOKE[@]}" \
    --db "$DB" --server-id "$SERVER_ID" \
    --base-url "$KOMGA_BASE_URL" --api-key "$KOMGA_API_KEY")

  echo "== 3b/3 Live replay WITHOUT credentials (断网 = 本地库浏览) =="
  (cd "$ROOT/android/komga_core" && "${SMOKE[@]}" \
    --offline --db "$DB" --server-id "$SERVER_ID")
else
  echo "== 3/3 skipped: set KOMGA_BASE_URL + KOMGA_API_KEY for the live chain =="
fi

echo "STAGE 4 ACCEPTANCE OK (offline battery complete; live chain ran when env was set)"