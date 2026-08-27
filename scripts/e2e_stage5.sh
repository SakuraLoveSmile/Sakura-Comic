#!/usr/bin/env bash
# Stage 5 acceptance — the sync engine converges SQLite on Komga without SSE.
#
#   1/4 scenario replay (specs/contracts/fixtures/sync, no network at all) +
#       a scale sweep, so "the mirror is correct for a big library" is checked
#       on every run rather than assumed:
#       bootstrap → add / change / delete → reconcile → mirror == server,
#       interrupted runs resume from their cursors, an offline sweep loses
#       nothing and heals itself when the network returns.
#   2/4 real HTTP over loopback (always): komga_fixture_server serves the same
#       snapshots on 127.0.0.1, so KomgaClient itself is exercised — URLs, auth
#       header, page/size slicing, Spring Data page envelopes. Bootstrap +
#       reconcile against it, then the server changes underneath the client
#       (adds/edits, then deletes) and reconcile-only sweeps must re-converge.
#   3/4 live chain (only with KOMGA_BASE_URL + KOMGA_API_KEY): Bootstrap Sync
#       → Reconcile Sync → per-series mirror == server → second sweep clean.
#   4/4 the Swift side replays the same scenario contract.
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
CORE="$ROOT/android/komga_core"

echo "== 1/4 Sync scenario replay (shared contract fixtures, SSE disabled) =="
(cd "$CORE" && "${SMOKE[@]}" --scenario)

echo "== 1b/4 Scale sweep (300 series / 6000 books): correctness of a big mirror =="
(cd "$CORE" && "${SMOKE[@]}" --scale 300 20)

echo "== 2/4 Real HTTP over loopback: KomgaClient against the fixture server =="
WORK="$(mktemp -d)"
# Kill the server itself, not a `cargo run` wrapper: if only the wrapper dies,
# the server it spawned keeps listening forever.
trap 'kill "${SERVER_PID:-}" 2>/dev/null || true; wait "${SERVER_PID:-}" 2>/dev/null || true; rm -rf "$WORK"' EXIT
SCENARIO="$ROOT/specs/contracts/fixtures/sync/scenario-reconcile.json"
echo s0 > "$WORK/snapshot"
(cd "$CORE" && cargo build --quiet --bin komga_fixture_server)
"$CORE/target/debug/komga_fixture_server" \
  --scenario "$SCENARIO" --snapshot-file "$WORK/snapshot" \
  --expect-key fixture-key --port 0 > "$WORK/server.out" 2>&1 &
SERVER_PID=$!

PORT=""
for _ in $(seq 1 60); do
  PORT="$(awk '/LISTENING/{print $2}' "$WORK/server.out" 2>/dev/null || true)"
  [ -n "$PORT" ] && break
  sleep 0.2
done
if [ -z "$PORT" ]; then
  echo "  [FAIL] fixture server did not start"
  cat "$WORK/server.out"
  exit 1
fi
# Authentication is real: no key and the wrong key must both be refused, and the
# configured key must be accepted — that is the client's own header path.
NO_AUTH="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/v1/libraries")"
WRONG_KEY="$(curl -s -o /dev/null -w '%{http_code}' -H 'X-API-Key: nope' "http://127.0.0.1:$PORT/api/v1/libraries")"
GOOD_KEY="$(curl -s -o /dev/null -w '%{http_code}' -H 'X-API-Key: fixture-key' "http://127.0.0.1:$PORT/api/v1/libraries")"
echo "  fixture server on 127.0.0.1:$PORT (none -> $NO_AUTH, wrong -> $WRONG_KEY, key -> $GOOD_KEY)"
if [ "$NO_AUTH" != "401" ] || [ "$WRONG_KEY" != "401" ] || [ "$GOOD_KEY" != "200" ]; then
  echo "  [FAIL] credential handling is not Komga-like"
  exit 1
fi

LOOP_DB="/tmp/comic-stage5-loopback.sqlite"
run_loopback() {
  (cd "$CORE" && "${SMOKE[@]}" \
    --db "$LOOP_DB" --server-id loopback \
    --base-url "http://127.0.0.1:$PORT" --api-key fixture-key "$@")
}
rm -f "$LOOP_DB"
run_loopback
echo s1 > "$WORK/snapshot"
run_loopback --reconcile-only
echo s2 > "$WORK/snapshot"
run_loopback --reconcile-only
(cd "$CORE" && "${SMOKE[@]}" --offline --db "$LOOP_DB" --server-id loopback)

# A rejected credential has to fail safely: error recorded, mirror untouched,
# still browsable, healed by the next healthy sweep. Deterministic here, because
# the fixture server answers 401 for any key but the configured one.
(cd "$CORE" && "${SMOKE[@]}" --auth-failure \
  --db /tmp/comic-stage5-auth.sqlite --server-id authfail \
  --base-url "http://127.0.0.1:$PORT")
rm -f /tmp/comic-stage5-auth.sqlite

if [[ -n "${KOMGA_BASE_URL:-}" ]]; then
  # Read-only probe of the real server with a deliberately wrong key: proves the
  # auth-failure path against actual Komga behaviour (it answers 401) without
  # needing anybody's credential.
  echo "== 3a/4 Real server: a rejected credential must fail safely =="
  (cd "$CORE" && "${SMOKE[@]}" --auth-failure \
    --db /tmp/comic-stage5-auth-real.sqlite --server-id real-authfail \
    --base-url "$KOMGA_BASE_URL")
  rm -f /tmp/comic-stage5-auth-real.sqlite
fi

if [[ -n "${KOMGA_BASE_URL:-}" && -n "${KOMGA_API_KEY:-}" ]]; then
  echo "== 3b/4 Live: Bootstrap + Reconcile + mirror == Komga =="
  (cd "$CORE" && "${SMOKE[@]}" \
    --db "$DB" --server-id "$SERVER_ID" \
    --base-url "$KOMGA_BASE_URL" --api-key "$KOMGA_API_KEY")

  echo "== 3c/4 Live replay WITHOUT credentials (断网 = 本地库浏览) =="
  (cd "$CORE" && "${SMOKE[@]}" \
    --offline --db "$DB" --server-id "$SERVER_ID")
else
  echo "== 3/4 skipped: set KOMGA_BASE_URL + KOMGA_API_KEY for the live chain =="
fi

echo "== 4/4 Swift replays the same scenario contract =="
(cd "$ROOT/apple/KomgaKit" && swift test --filter SyncScenarioTests 2>&1 |
  grep -E "Executed [0-9]+ tests|\[FAIL\]")

echo "STAGE 5 ACCEPTANCE OK (scenarios + loopback HTTP always run; live chain ran when env was set)"
