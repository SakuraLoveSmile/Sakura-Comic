#!/usr/bin/env bash
# Stage 6 acceptance — SSE 与 Mutation Outbox.
#
#   1/3 Real HTTP over loopback (always). `komga_fixture_server` grew the two
#       Komga write verbs and the event stream, so `KomgaClient` itself is
#       exercised end to end:
#         a. 断网 → 阅读 / 修改状态 → [SIGKILL] → 重新启动 → 恢复网络 →
#            Mutation 自动上传, and the *server's own journal* is the evidence
#            that no operation was lost (the stage's 验收标准).
#         b. retry / backoff / failed / 400-reject / 401-stop-the-run, driven by
#            injected HTTP faults on a real socket.
#         c. a server-confirmed 404 releases its queued action.
#         d. SSE: frames parsed off a real stream, a heartbeat that must not
#            become an event, a half frame that must not be dispatched, and a
#            reconnect that must reconcile before it consumes anything.
#   2/3 The shared contract fixtures (specs/contracts/fixtures) drive both the
#       Rust rules and the Swift rules, in one run.
#   3/3 Swift: the same fixtures + the scenario contract.
#
# Env: KOMGA_BASE_URL alone adds a credential-free check of the deployed UI bundle
#      (does the running server know /sse/v1/events and our event names?).
#      KOMGA_API_KEY additionally runs the authenticated handshake probe.
# Arg: --rust-only skips the Swift leg (the Rust half is the bulk of the run).
set -euo pipefail
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/android/komga_core"
WORK="$(mktemp -d)"
DB="$WORK/stage6.sqlite"
KEY="fixture-key"

cleanup() {
  kill "${SERVER_PID:-}" 2>/dev/null || true
  wait "${SERVER_PID:-}" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 0/3 build =="
(cd "$CORE" && cargo build --quiet --bins)
SERVER="$CORE/target/debug/komga_fixture_server"
SMOKE="$CORE/target/debug/stage6_smoke"

# The Stage 5 scenario snapshots already contain real BookDto shapes, so the
# write path runs against the same data the mirror path was verified on.
SCENARIO="$ROOT/specs/contracts/fixtures/sync/scenario-reconcile.json"
echo s1 > "$WORK/snapshot"

# Event stream: a committed fixture (`specs/contracts/fixtures/sse/stream.raw`)
# containing a CRLF comment heartbeat, CRLF and LF frames, an `id:` frame, an
# unknown event name and a trailing half frame. The fixture server replays it in
# 7-byte chunks, so frames straddle the read boundary exactly as on a real wire.
SSE_FIXTURE="$ROOT/specs/contracts/fixtures/sse/stream.raw"
cp "$SSE_FIXTURE" "$WORK/sse.raw"

start_server() {
  "$SERVER" --scenario "$SCENARIO" --snapshot-file "$WORK/snapshot" \
    --expect-key "$KEY" --journal "$WORK/journal" \
    --progress-file "$WORK/progress.json" --fault-file "$WORK/fault" \
    --sse-file "$WORK/sse.raw" --port "$1" > "$WORK/server$1.out" 2>&1 &
  SERVER_PID=$!
  for _ in $(seq 1 60); do
    grep -q LISTENING "$WORK/server$1.out" && return 0
    sleep 0.2
  done
  echo "  [FAIL] fixture server did not start"; cat "$WORK/server$1.out"; exit 1
}

start_server 0
PORT="$(awk '/LISTENING/{print $2}' "$WORK/server0.out")"
BASE="http://127.0.0.1:$PORT"
echo "  fixture server on $BASE"
# Auth is real: a wrong key must be refused on the write route too.
if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X PATCH -H 'Content-Type: application/json' -d '{"page":1}' "$BASE/api/v1/books/book-1-1/read-progress")" != "401" ]; then
  echo "  [FAIL] an unauthenticated PATCH was not refused"; exit 1
fi
# The stream is a stream, not JSON: the client's handshake check depends on it.
CTYPE="$(curl -s --max-time 10 -D - -o /dev/null -H "X-API-Key: $KEY" "$BASE/sse/v1/events" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-type"{print $2}')"
case "$CTYPE" in text/event-stream*) ;; *) echo "  [FAIL] /sse/v1/events served '$CTYPE'"; exit 1;; esac
echo "  204/401/text-event-stream routes behave like Komga"

smoke() {
  "$SMOKE" --db "$DB" --key "$KEY" --base-url "$BASE" \
    --offline-url "http://127.0.0.1:1" --journal "$WORK/journal" \
    --fault "$WORK/fault" "$@"
}

echo "== 1/3 断网 → 阅读 → 杀掉 App → 重启 → 恢复网络 → 自动上传 =="
rm -f "$DB" "$WORK/journal"
smoke --phase offline > "$WORK/offline.out" 2>&1 &
OFFLINE_PID=$!
for _ in $(seq 1 120); do grep -q "ready-to-kill" "$WORK/offline.out" && break; sleep 0.25; done
grep -q "ready-to-kill" "$WORK/offline.out" || { echo "  [FAIL] offline phase hung"; cat "$WORK/offline.out"; exit 1; }
kill -9 "$OFFLINE_PID" 2>/dev/null || true
wait "$OFFLINE_PID" 2>/dev/null || true
echo "  killed -9 with 3 actions queued (过程输出: $(grep -c '' "$WORK/offline.out") 行)"
smoke --phase restart
smoke --phase gone
smoke --phase fault
echo "  server journal:"
sed 's/^/    /' "$WORK/journal"

echo "== 2/3 SSE over a real stream =="
smoke --phase sse

echo "== 2b/3 shared contract fixtures (Rust side) =="
(cd "$CORE" && cargo test --offline --lib store::outbox 2>&1 | tail -3)
(cd "$CORE" && cargo test --offline --test sse_contract 2>&1 | tail -3)

if [[ -n "${KOMGA_BASE_URL:-}" ]]; then
  # The Komga web UI is a public static asset, so this cross-checks the event
  # table against the deployed server without anybody's credential.
  echo "== 2c/3 deployed UI bundle: does the running server know these events? =="
  APP_JS="$(curl -s --max-time 10 "$KOMGA_BASE_URL/" | grep -oE '/js/app\.[0-9a-f]+\.js' | head -1)"
  if [[ -z "$APP_JS" ]]; then
    echo "  [skip] no /js/app.*.js reference found at $KOMGA_BASE_URL/"
  else
    curl -s --max-time 60 "$KOMGA_BASE_URL$APP_JS" -o "$WORK/app.js"
    SSE_FIXTURE="$ROOT/specs/contracts/fixtures/sse/events.json" APP_JS_PATH="$WORK/app.js" python3 - <<'PYPROBE'
import json, os, sys
bundle = open(os.environ['APP_JS_PATH'], encoding='utf-8', errors='replace').read()
route = '/sse/v1/events'
in_route = route in bundle
names = sorted({c['event'] for c in json.load(open(os.environ['SSE_FIXTURE']))['cases']})
subscribed = {n for n in names if 'addEventListener("' + n + '"' in bundle}
skipped = {'HalfFrame', 'message', 'TaskQueueStatus', 'SessionExpired'}
# SomeFutureKomgaEvent is a deliberate unknown in the table: it proves the
# client's fallback, so the real UI must NOT subscribe to it.
real = [n for n in names if n not in skipped and n != 'SomeFutureKomgaEvent']
missing = [n for n in real if n not in subscribed]
print(f'  bundle {os.path.basename(os.environ["APP_JS_PATH"])}: route literal present={in_route}, '
      f'{len([n for n in real if n in subscribed])}/{len(real)} '
      f'catalogue names subscribed by the official UI')
if missing:
    print(f'  [FAIL] our table names events the server UI never subscribes: {missing}')
    sys.exit(1)
if not in_route:
    print('  [FAIL] the running server ships no /sse/v1/events at all')
    sys.exit(1)
print('  ok: the event table matches the deployed server')
PYPROBE
  fi
fi

if [[ -n "${KOMGA_BASE_URL:-}" && -n "${KOMGA_API_KEY:-}" ]]; then
  echo "== 2d/3 real server: SSE handshake =="
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -H "X-API-Key: $KOMGA_API_KEY" -H 'Accept: text/event-stream' "$KOMGA_BASE_URL/sse/v1/events" || echo timeout)"
  echo "  GET /sse/v1/events -> $CODE (200 = the route is live; anything else must be recorded, not guessed)"
else
  echo "== 2d/3 skipped: set KOMGA_API_KEY for the authenticated SSE handshake =="
fi

if [[ "${1:-}" == "--rust-only" ]]; then
  echo "== 3/3 skipped (--rust-only; CI has no Swift job) =="
else
  echo "== 3/3 Swift replays the same contracts =="
  (cd "$ROOT/apple/KomgaKit" && swift test 2>&1 | grep -E "Executed [0-9]+ tests|error:|\[FAIL\]" | tail -5)
fi

echo "STAGE 6 ACCEPTANCE OK (kill + restart upload, fault ladder, SSE reconnect ordering)"
