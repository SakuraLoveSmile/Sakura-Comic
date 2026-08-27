#!/usr/bin/env bash
# Stage 5 acceptance — the sync engine converges SQLite on Komga without SSE.
#
#   1/3 scenario replay (specs/contracts/fixtures/sync, no network at all):
#       bootstrap → add / change / delete → reconcile → mirror == server,
#       interrupted bootstrap resumes from its cursor, an offline sweep
#       loses nothing and heals itself when the network returns.
#   2/3 live chain (only with KOMGA_BASE_URL + KOMGA_API_KEY): Bootstrap Sync
#       → Reconcile Sync → per-series mirror == server → second sweep clean.
#   3/3 offline replay of the live database with no credentials: the mirrored
#       library (and the deletions propagated into it) still answers queries.
#
# Env: KOMGA_BASE_URL, KOMGA_API_KEY, KOMGA_SERVER_ID (default stage5),
#      KOMGA_DB (default /tmp/comic-stage5-live.sqlite)
set -euo pipefail

# cargo may live outside the caller's PATH (rustup layout).
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_ID="${KOMGA_SERVER_ID:-stage5}"
DB="${KOMGA_DB:-/tmp/comic-stage5-live.sqlite}"
mkdir -p "$(dirname "$DB")"
rm -f "$DB"
rm -rf "$(dirname "$DB")/cache"

SMOKE=(cargo run --quiet --bin stage5_smoke --)

echo "== 1/3 Sync scenario replay (shared contract fixtures, SSE disabled) =="
(cd "$ROOT/android/komga_core" && "${SMOKE[@]}" --scenario)

if [[ -n "${KOMGA_BASE_URL:-}" && -n "${KOMGA_API_KEY:-}" ]]; then
  echo "== 2/3 Live: Bootstrap + Reconcile + mirror == Komga =="
  (cd "$ROOT/android/komga_core" && "${SMOKE[@]}" \
    --db "$DB" --server-id "$SERVER_ID" \
    --base-url "$KOMGA_BASE_URL" --api-key "$KOMGA_API_KEY")

  echo "== 2b/3 Live replay WITHOUT credentials (断网 = 本地库浏览) =="
  (cd "$ROOT/android/komga_core" && "${SMOKE[@]}" \
    --offline --db "$DB" --server-id "$SERVER_ID")
else
  echo "== 2/3 skipped: set KOMGA_BASE_URL + KOMGA_API_KEY for the live chain =="
fi

echo "STAGE 5 ACCEPTANCE OK (scenarios always run; live chain ran when env was set)"
