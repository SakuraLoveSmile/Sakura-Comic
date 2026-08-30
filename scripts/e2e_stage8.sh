#!/usr/bin/env bash
# Stage 8 — reader performance and cache acceptance.
#
# What Stage 7 proved was that the reader works. This proves it survives: a
# 520-page book read end to end, true 4K pages in a pool too small for them,
# a slider throw across the book, 300 webtoon advances, a link that answers
# slowly, no link at all, a link that changes under it, memory pressure, a
# background restore, and a server that hands back truncated images.
#
# Every phase runs as its own PROCESS. That is what makes the memory claim
# testable rather than rhetorical: the harness samples the child's resident set
# while it runs, so "memory does not grow" is a measured curve, not an opinion,
# and no phase can inherit another's caches.
#
#   scripts/e2e_stage8.sh [--rust-only] [--keep] [--only PHASE[,PHASE]]
#
# Live leg: KOMGA_BASE_URL + KOMGA_API_KEY run the same big-book walk against a
# real Komga. Without them the leg is skipped and says so.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/android/komga_core"
WORK="${TMPDIR:-/tmp}/stage8.$$"
SMOKE="$CORE/target/debug/stage8_smoke"
FIXTURE="$CORE/target/debug/komga_fixture_server"
SERVER_PID=""
SAMPLE_PID=""
PEAK_RSS=0
FAILURES=0
ONLY=""
KEEP=0
RUST_ONLY=0
KEY="fixture-key"
PORTS=()

cleanup() {
  for pid in ${PORTS[@]+"${PORTS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$SAMPLE_PID" ] && kill "$SAMPLE_PID" 2>/dev/null || true
  if [ "$KEEP" = 0 ]; then rm -rf "$WORK"; else echo "== kept $WORK"; fi
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --rust-only) RUST_ONLY=1 ;;
    --keep) KEEP=1 ;;
    --only) ONLY="$2"; shift ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$WORK"
DB="$WORK/stage8.sqlite"
CACHE="$WORK/cache"
export RUST_LOG="${RUST_LOG:-warn}"

say() { printf '\n== %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf '   FAIL %s\n' "$*" >&2; }
check() { # check <description> <actual> <expected>
  if [ "$2" = "$3" ]; then printf '   ok   %s (%s)\n' "$1" "$2"
  else fail "$1: got $2, want $3"; fi
}
check_le() { # check_le <description> <actual> <limit>
  if [ "$(awk -v a="$2" -v b="$3" 'BEGIN{print (a<=b)?1:0}')" = 1 ]; then
    printf '   ok   %s (%s <= %s)\n' "$1" "$2" "$3"
  else fail "$1: $2 exceeds $3"; fi
}

say "1/4 build"
(cd "$CORE" && cargo build --quiet --bin stage8_smoke --bin komga_fixture_server)

# ------------------------------------------------------------------ servers ---
# One server per shape of trouble. Each serves its own stress book so a phase
# cannot accidentally read someone else's warm files.
start_server() { # start_server <name> <stress-spec> [extra flags...]
  local name="$1" spec="$2"
  shift 2
  local log="$WORK/$name.log" port_file="$WORK/$name.port"
  "$FIXTURE" \
    --scenario "$ROOT/specs/contracts/fixtures/sync/scenario-reconcile.json" \
    --snapshot-file "$WORK/$name.snapshot" \
    --expect-key "$KEY" \
    --journal "$WORK/$name.journal" \
    --page-journal "$WORK/$name.pages" \
    --stress "$spec" \
    "$@" >"$log" 2>&1 &
  local pid=$!
  PORTS+=("$pid")
  for _ in $(seq 1 100); do
    if grep -q '^LISTENING ' "$log" 2>/dev/null; then break; fi
    sleep 0.05
  done
  grep '^LISTENING ' "$log" | awk '{print $2}' > "$port_file"
  # The Stage 5/6 scenario snapshots are keyed s1..sN; s1 is the converged
  # library, and the stress book is served independently of it.
  echo s1 > "$WORK/$name.snapshot"
  printf '   %s -> port %s\n' "$name" "$(cat "$port_file")"
}

BASE_SMALL="small-520,520,120,180,0"
BASE_4K="stress-4k,6,3840,2160,0"
BASE_SLOW="slow-40,40,160,220,0"
BASE_ROTTEN="rotten-12,12,140,200,0"
BASE_WARM="warm-40,40,140,200,0"

say "2/4 fixture servers"
start_server small "$BASE_SMALL"
start_server fourk "$BASE_4K"
start_server slow "$BASE_SLOW" --delay-ms 120
start_server rotten "$BASE_ROTTEN" --truncate-every 3
start_server warm "$BASE_WARM"
SMALL_URL="http://127.0.0.1:$(cat "$WORK/small.port")"
FOURK_URL="http://127.0.0.1:$(cat "$WORK/fourk.port")"
SLOW_URL="http://127.0.0.1:$(cat "$WORK/slow.port")"
ROTTEN_URL="http://127.0.0.1:$(cat "$WORK/rotten.port")"
WARM_URL="http://127.0.0.1:$(cat "$WORK/warm.port")"
# Port 1 is reserved and nothing can listen on it: a genuinely unreachable server.
OFFLINE_URL="http://127.0.0.1:1"
# An unreachable *host* is not the same as an unreachable port; this is the
# second half of "the outage is visible as a network error, not as a broken book".
[ "$(curl -s -o /dev/null -w '%{http_code}' "$SMALL_URL/api/v1/actuator/info" || true)" = 401 ] \
  || fail "the stress server is not answering as Komga does"

run() { # run <phase> <db> <cache> <base-url> [smoke flags...] -> metrics on stdout
  local phase="$1" db="$2" cache="$3" url="$4"
  shift 4
  "$SMOKE" --phase "$phase" --db "$db" --cache "$cache" \
    --base-url "$url" --offline-url "$OFFLINE_URL" --key "$KEY" \
    --server-id A "$@" 2>&1 | tee -a "$WORK/run.log"
}

metric() { # metric <file> <name>
  awk -v want="$2" '$1=="metric"{split($2,kv,"="); if(kv[1]==want) print kv[2]}' \
    "$1" | tail -1
}

# Sample the child's resident set while it runs. `ps` is the only honest source
# here: the reader's own counters describe what it allocated, not what the
# process is holding, and the acceptance line is about the process.
# Run a phase as its own process while sampling its resident set AND the traffic
# its server saw. The subshell turns `set -e` back off deliberately: a phase that
# fails must be reported as a failed *check*, not silently abort the run on the
# way past `wait`.
#
#   start_sampling <label> <server> <cmd...>
#
# The journal is the witness that cannot lie about request counts, because the
# server writes it rather than the reader: comparing `page_requests` (what the
# reader thinks it sent) against the journal delta (what arrived) is what turns
# "no duplicate requests" from a self-report into a measurement.
start_sampling() {
  local label="$1" server="$2"
  local out="$WORK/$label.out"
  local peak="$WORK/$label.rss"
  shift 2
  local before
  before=$(journal_reads "$server")
  (
    set +e
    "$@" > "$out" 2>&1 &
    local child=$!
    local seen=0
    local rss
    while kill -0 "$child" 2>/dev/null; do
      rss=$(ps -o rss= -p "$child" 2>/dev/null | tr -d ' ')
      if [ -n "$rss" ] && [ "$rss" -gt "$seen" ]; then seen=$rss; fi
      sleep 0.02
    done
    wait "$child"
    echo "$?" > "$WORK/$label.code"
    echo "$seen" > "$peak"
    exit 0
  ) &
  SAMPLE_PID=$!
  wait "$SAMPLE_PID"
  SAMPLE_PID=""
  local after delta code
  after=$(journal_reads "$server")
  delta=$((after - before))
  echo "$delta" > "$WORK/$label.jdelta"
  code=$(cat "$WORK/$label.code")
  if [ "$code" != "0" ]; then
    tail -30 "$out"
    fail "phase $label exited $code"
  fi
  printf '   %s: peak rss %s KB, server saw %s more page reads\n' \
    "$label" "$(cat "$peak")" "$delta"
}

# Page reads only: the manifest route journals into the same file, and counting
# it would make every phase look like it asked for one page too many.
journal_reads() { # journal_reads <server>
  local server="$1"
  if [ -f "$WORK/$server.pages" ]; then
    grep -c '"kind": *"page"' "$WORK/$server.pages" || true
  else
    echo 0
  fi
}

# How many *different* pages the server served in a window of its own log. A total
# request count cannot see the device's failure — twenty reads for four distinct
# pages — this can.
distinct_in() { # distinct_in <from> <to> <server>
  awk -F'"' -v lo="$1" -v hi="$2" '
    /"kind": *"page"/{n++; if (n>lo && n<=hi) { for(i=1;i<=NF;i++) if ($i=="asked") {gsub(/[^0-9]/,"",$(i+1)); print $(i+1)} }}' \
    "$WORK/$3.pages" 2>/dev/null | sort -u | grep -c . || true
}

# The reader's own count and the server's count must agree, or one of them is
# measuring the wrong thing.
check_no_duplicates() { # check_no_duplicates <label> <metric-name>
  local label="$1" name="$2"
  local claimed seen
  claimed=$(metric "$WORK/$label.out" "$name")
  seen=$(cat "$WORK/$label.jdelta")
  if [ "$claimed" = "$seen" ]; then
    printf '   ok   %s: reader said %s requests, server counted %s\n' "$label" "$claimed" "$seen"
  else
    fail "$label: reader reported $claimed requests but the server served $seen"
  fi
}

# ------------------------------------------------------------------ phases ----
say "3/4 stress phases (each its own process, memory and traffic both sampled)"

# The pool a mid-size phone would be given: 64 MiB. Deliberately far smaller than
# the 520-page book, which is the entire point of the eviction rules.
PHONE_RAM=4294967296
POOL=67108864

start_sampling big-book small "$SMOKE" --phase big-book --db "$DB" --cache "$CACHE" \
  --base-url "$SMALL_URL" --offline-url "$OFFLINE_URL" --key "$KEY" --server-id A \
  --book small-520 --device-memory $PHONE_RAM --pool-budget $POOL --network wifi
BIG="$WORK/big-book.out"
check "big book page count" "$(metric "$BIG" page_count)" "520"
check "one request per page" "$(metric "$BIG" page_requests)" "$(metric "$BIG" distinct_pages)"
check "distinct pages read" "$(metric "$BIG" distinct_pages)" "520"
check "manifest mirrored once" "$(metric "$BIG" manifest_requests)" "1"
check_no_duplicates big-book page_requests
check_le "memory tier stayed inside its budget" \
  "$(metric "$BIG" memory_peak_bytes)" "$(metric "$BIG" memory_budget_bytes)"
check_le "the pool did not overrun" \
  "$(metric "$BIG" ledger_bytes)" "$((POOL + 400000))"
if [ "$(awk -v a="$(metric "$BIG" mean_last_quarter_us)" -v b="$(metric "$BIG" mean_first_quarter_us)" \
     'BEGIN{print (a <= b*2 + 5000) ? 1 : 0}')" = 1 ]; then
  printf '   ok   the last quarter cost %sus vs %sus in the first\n' \
    "$(metric "$BIG" mean_last_quarter_us)" "$(metric "$BIG" mean_first_quarter_us)"
else
  fail "reading slowed across the book: $(metric "$BIG" mean_first_quarter_us)us -> $(metric "$BIG" mean_last_quarter_us)us"
fi
printf '   ok   turn p95 %sus over %s turns\n' "$(metric "$BIG" p95_us)" "520"

# 4K pages in a 40 MiB pool: two pages fill it. The plan has to notice.
start_sampling large-pages fourk "$SMOKE" --phase large-pages --db "$WORK/4k.sqlite" \
  --cache "$WORK/cache-4k" --base-url "$FOURK_URL" --offline-url "$OFFLINE_URL" \
  --key "$KEY" --server-id A --book stress-4k --device-memory $PHONE_RAM \
  --pool-budget 41943040 --network wifi
K="$WORK/large-pages.out"
check "4K pages are really 4K" "$(metric "$K" page_dimensions)" "3840x2160"
# The claim that matters is about the display path: page N is asked for once, in
# order. Anything after that is the window's own look-behind, which in a pool
# this small has genuinely been evicted.
check "each 4K page fetched once by the display path" \
  "$(metric "$K" sequence_planned | cut -d, -f1-6)" "1,2,3,4,5,6"
check_le "the window's look-behind stayed inside one extra page per turn" \
  "$(metric "$K" requests_planned)" "12"
check "the placeholder window thrashed instead" "1" "$(awk -v a="$(metric "$K" requests_placeholder)" 'BEGIN{print (a>12)?1:0}')"

# The same book, the same pool, with the memory tier cut to 32 MiB. If the tier
# were a leak rather than a ceiling, this number would not move.
start_sampling large-pages-small-tier fourk "$SMOKE" --phase large-pages \
  --db "$WORK/4k-small.sqlite" --cache "$WORK/cache-4k-small" --base-url "$FOURK_URL" \
  --offline-url "$OFFLINE_URL" --key "$KEY" --server-id A --book stress-4k \
  --device-memory $PHONE_RAM --pool-budget 41943040 --memory-budget 33554432 \
  --network wifi
if [ "$(awk -v a="$(cat "$WORK/large-pages-small-tier.rss")" -v b="$(cat "$WORK/large-pages.rss")" \
   'BEGIN{print (a*10 < b*9) ? 1 : 0}')" = 1 ]; then
  printf '   ok   a 32 MiB tier cost %s KB RSS where 256 MiB cost %s KB\n' \
    "$(cat "$WORK/large-pages-small-tier.rss")" "$(cat "$WORK/large-pages.rss")"
else
  fail "shrinking the memory tier did not shrink the process: $(cat "$WORK/large-pages-small-tier.rss") vs $(cat "$WORK/large-pages.rss") KB"
fi
printf '   ok   same book, same pool: placeholder %s requests vs planned %s\n' \
  "$(metric "$K" requests_placeholder)" "$(metric "$K" requests_planned)"
check "the window shrank for 4K pages" "1" "$(awk -v f="$(metric "$K" window_forward)" 'BEGIN{print (f<=2)?1:0}')"
check_no_duplicates large-pages requests_total
if [ "$(awk -v a="$(metric "$K" avg_page_bytes)" 'BEGIN{print (a > 20000000)?1:0}')" = 1 ]; then
  printf '   ok   one 4K page is %s bytes (%s MiB), pool %s, per page %sms\n' \
    "$(metric "$K" avg_page_bytes)" \
    "$(awk -v a="$(metric "$K" avg_page_bytes)" 'BEGIN{printf "%.1f", a/1048576}')" \
    "41943040" "$(awk -v a="$(metric "$K" per_page_ms)" 'BEGIN{printf "%.0f", a}')"
else
  fail "the 4K fixture is not a 4K page: $(metric "$K" avg_page_bytes) bytes"
fi
check_le "the pool held no more than itself plus one page" \
  "$(metric "$K" ledger_bytes_planned)" "$((41943040 + 25000000))"
check_le "4K pages never outgrew the memory tier" \
  "$(metric "$K" memory_peak_planned)" "$(metric "$K" memory_budget_bytes)"

start_sampling rapid-flip small "$SMOKE" --phase rapid-flip --db "$WORK/flip.sqlite" \
  --cache "$WORK/cache-flip" --base-url "$SMALL_URL" --offline-url "$OFFLINE_URL" \
  --key "$KEY" --server-id A --book small-520 --device-memory $PHONE_RAM \
  --pool-budget $POOL --turns 120
FLIP="$WORK/rapid-flip.out"
check "120 flips asked for no page twice" \
  "$(metric "$FLIP" page_requests)" "$(metric "$FLIP" distinct_pages)"
check "an unstable window dropped the look-behind" "$(metric "$FLIP" unstable_back)" "0"
check_no_duplicates rapid-flip page_requests
if [ "$(awk -v a="$(metric "$FLIP" unstable_cap)" -v b="$(metric "$FLIP" window_cap)" \
     'BEGIN{print (a<b)?1:0}')" = 1 ]; then
  printf '   ok   mid-flip cap %s < settled cap %s\n' \
    "$(metric "$FLIP" unstable_cap)" "$(metric "$FLIP" window_cap)"
else
  fail "the unstable plan did not shrink the window"
fi

# Six HOME / return cycles. Each one is: the platform signals memory pressure, the
# reader comes back and re-reports its device (which runs the sweep), then re-warms
# the same spread. On a real device that sequence asked the server for twenty pages
# to show four distinct ones, because the pressure response deleted the prefetch
# tier it had just filled.
RBEFORE=$(journal_reads small)
start_sampling resume-loop small "$SMOKE" --phase resume-loop --db "$WORK/resume.sqlite" \
  --cache "$WORK/cache-resume" --base-url "$SMALL_URL" --offline-url "$OFFLINE_URL" \
  --key "$KEY" --server-id A --book small-520 --device-memory $PHONE_RAM \
  --pool-budget $POOL
RESUME="$WORK/resume-loop.out"
RAFTER=$(journal_reads small)
check "six resume cycles asked for no page twice" \
  "$(cat "$WORK/resume-loop.jdelta")" "$(distinct_in "$RBEFORE" "$RAFTER" small)"
check "once the window was warm, the cycles fetched nothing" \
  "$(awk -F= '/metric resume[2-5]_landed/{s+=$2} END{print s+0}' "$RESUME")" "0"
check "the window still needed pages while it was filling" \
  "$(awk -F= '/metric resume[01]_landed/{s+=$2} END{print s+0}' "$RESUME")" "8"
printf '   metric resume_cycles_released_total=%s held=%s\n' \
  "$(awk -F= '/metric resume[0-9]_released/{s+=$2} END{print s+0}' "$RESUME")" \
  "$(metric "$RESUME" resume5_held)"

start_sampling long-scroll small "$SMOKE" --phase long-scroll --db "$WORK/scroll.sqlite" \
  --cache "$WORK/cache-scroll" --base-url "$SMALL_URL" --offline-url "$OFFLINE_URL" \
  --key "$KEY" --server-id A --book small-520 --device-memory $PHONE_RAM \
  --pool-budget $POOL --turns 300 --mode webtoon
SCROLL="$WORK/long-scroll.out"
check "300 webtoon advances" "$(metric "$SCROLL" advances)" "300"
check_le "a warm turn stayed under one 60Hz frame" \
  "$(metric "$SCROLL" warm_turn_p95_us)" "8000"
check_le "scrolling did not grow the memory tier" \
  "$(metric "$SCROLL" memory_peak_bytes)" "$(metric "$SCROLL" memory_budget_bytes)"
check_no_duplicates long-scroll page_requests
printf '   ok   turn p50 %sus p95 %sus p99 %sus\n' \
  "$(metric "$SCROLL" warm_turn_p50_us)" "$(metric "$SCROLL" warm_turn_p95_us)" \
  "$(metric "$SCROLL" warm_turn_p99_us)"

start_sampling weak-network slow "$SMOKE" --phase weak-network --db "$WORK/weak.sqlite" \
  --cache "$WORK/cache-weak" --base-url "$SLOW_URL" --offline-url "$OFFLINE_URL" \
  --key "$KEY" --server-id A --book slow-40 --device-memory $PHONE_RAM \
  --pool-budget $POOL
WEAK="$WORK/weak-network.out"
check "a weak link runs one request at a time" "$(metric "$WEAK" window_in_flight)" "1"
check "a weak link caps its queue" "$(metric "$WEAK" window_cap)" "3"
check_le "prefetch stayed inside the capped window" \
  "$(metric "$WEAK" page_requests)" "3"
check_no_duplicates weak-network page_requests

start_sampling network-switch small "$SMOKE" --phase network-switch --db "$WORK/switch.sqlite" \
  --cache "$WORK/cache-switch" --base-url "$SMALL_URL" --offline-url "$OFFLINE_URL" \
  --key "$KEY" --server-id A --book small-520 --device-memory $PHONE_RAM --pool-budget $POOL
SWITCH="$WORK/network-switch.out"
if grep -q 'offline=WindowPlan { forward: 0, back: 0, cap: 0' "$SWITCH"; then
  printf '   ok   offline queues nothing\n'
else
  fail "offline did not stop the queue: $(grep -o 'offline=.*' "$SWITCH" | head -1)"
fi
if awk '/^metric (wifi|cellular|weak|offline)=/{gsub(/.*cap: /,""); gsub(/,.*/,""); print}' "$SWITCH" \
     | awk 'NR>1 && $1>=prev {bad=1} {prev=$1} END{exit !bad ? 0 : 1}'; then
  printf '   ok   wifi > cellular > weak > offline, four distinct caps\n'
else
  fail "the link ladder did not tighten monotonically: $(grep '^metric ' "$SWITCH" | tr '\n' ' ')"
fi
# network-switch plans without fetching: it must touch the server not at all.
check "planning alone asked the server for nothing" "$(cat "$WORK/network-switch.jdelta")" "0"

start_sampling memory-pressure small "$SMOKE" --phase memory-pressure --db "$WORK/press.sqlite" \
  --cache "$WORK/cache-press" --base-url "$SMALL_URL" --offline-url "$OFFLINE_URL" \
  --key "$KEY" --server-id A --device-memory $PHONE_RAM --pool-budget $POOL \
  --memory-budget 65536
PRESS="$WORK/memory-pressure.out"
check_le "the tier never exceeded its 64 KiB ceiling" \
  "$(metric "$PRESS" memory_peak_bytes)" "65536"
check "the pressure response emptied RAM" "$(metric "$PRESS" memory_bytes_after_pressure)" "0"
check "and the eviction loop really ran" "1" \
  "$(awk -v e="$(metric "$PRESS" memory_evictions)" 'BEGIN{print (e>0)?1:0}')"

# Offline: warm a book over the live server, then read it with nothing listening.
start_sampling offline-read warm "$SMOKE" --phase offline --db "$WORK/off.sqlite" \
  --cache "$WORK/cache-off" --base-url "$WARM_URL" --offline-url "$OFFLINE_URL" \
  --key "$KEY" --server-id A --book warm-40 --device-memory $PHONE_RAM --pool-budget $POOL
OFF="$WORK/offline-read.out"
check "the warm window is what the plan said" "$(metric "$OFF" cached_pages)" "21"
check "reading offline sent zero requests" "$(metric "$OFF" page_requests)" "0"
check "and asked for no manifest" "$(metric "$OFF" manifest_requests)" "0"
# Everything the server saw was the warm-up: the dead-server half is proven by
# the reader sending nothing at all AND by the server having seen exactly the
# warm-up count.
check "the server saw only the warm-up traffic" \
  "$(metric "$OFF" warm_requests)" "$(cat "$WORK/offline-read.jdelta")"

# Background restore: two processes, one database, no network on the second.
BEFORE_BG=$(journal_reads warm)
"$SMOKE" --phase background-restore --db "$WORK/bg.sqlite" --cache "$WORK/cache-bg" \
  --base-url "$WARM_URL" --offline-url "$OFFLINE_URL" --key "$KEY" --server-id A \
  --book warm-40 --device-memory $PHONE_RAM --pool-budget $POOL > "$WORK/bg-1.out" 2>&1
MID_BG=$(journal_reads warm)
start_sampling background-restore warm "$SMOKE" --phase background-restore \
  --db "$WORK/bg.sqlite" --cache "$WORK/cache-bg" --base-url "$WARM_URL" \
  --offline-url "$OFFLINE_URL" --key "$KEY" --server-id A --book warm-40 \
  --device-memory $PHONE_RAM --pool-budget $POOL
BG="$WORK/background-restore.out"
check "the position came back" "$(metric "$BG" restored_page)" "$(metric "$WORK/bg-1.out" saved_page)"
check "restore over a dead server sent nothing" "$(metric "$BG" page_requests)" "0"
check "and the server confirms it heard nothing" "$(cat "$WORK/background-restore.jdelta")" "0"
printf '   ok   the first pass cost the server %s reads, the restore %s\n' \
  "$((MID_BG - BEFORE_BG))" "$(cat "$WORK/background-restore.jdelta")"

start_sampling corruption rotten "$SMOKE" --phase corruption --db "$WORK/rot.sqlite" \
  --cache "$WORK/cache-rot" --base-url "$ROTTEN_URL" --offline-url "$OFFLINE_URL" \
  --key "$KEY" --server-id A --book rotten-12 --device-memory $PHONE_RAM --pool-budget $POOL
ROT="$WORK/corruption.out"
check "short reads were refused" "$(metric "$ROT" pages_refused)" "4"
check "the rest was served" "$(metric "$ROT" pages_served)" "8"
check "no truncated page was cached" "0" \
  "$(awk -v a="$(metric "$ROT" still_refused_after_retry)" -v b="$(metric "$ROT" pages_refused)" 'BEGIN{print (a==b)?0:1}')"
check_no_duplicates corruption requests_total
printf '   ok   %s requests for %s served + %s refused pages, retries bounded\n' \
  "$(metric "$ROT" page_requests)" "$(metric "$ROT" pages_served)" "$(metric "$ROT" pages_refused)"

# ------------------------------------------------------------------ live leg --
if [ -n "${KOMGA_BASE_URL:-}" ] && [ -n "${KOMGA_API_KEY:-}" ]; then
  say "live leg: the same big-book walk against a real Komga"
  # The floor drops to 100 because a real library has what it has: the stress book
  # is 520 synthetic pages, while the biggest book on the server is whatever it is.
  # The line being carried over is the phase's own — one request per page, no page
  # twice — and the page count it found is printed, not assumed.
  "$SMOKE" --phase big-book --db "$WORK/live.sqlite" --cache "$WORK/cache-live" \
    --base-url "$KOMGA_BASE_URL" --offline-url "$OFFLINE_URL" --key "$KOMGA_API_KEY" \
    --server-id live --book "${KOMGA_BOOK_ID:?KOMGA_BOOK_ID names a real book}" \
    --min-pages 100 --device-memory $PHONE_RAM --pool-budget $POOL \
    > "$WORK/live.out" 2>&1 || fail "the live big-book walk failed"
  grep -E '^metric (page_count|page_requests|distinct_pages|manifest_requests|avg_page_bytes|pool_bytes|memory_peak|rss)' "$WORK/live.out" || true
  check "the live walk cost exactly one request per page" \
    "$(metric "$WORK/live.out" page_requests)" "$(metric "$WORK/live.out" page_count)"
  check "no live page was asked for twice" \
    "$(metric "$WORK/live.out" distinct_pages)" "$(metric "$WORK/live.out" page_count)"
else
  say "live leg skipped: set KOMGA_BASE_URL + KOMGA_API_KEY (+ KOMGA_BOOK_ID)"
  printf '   the LAN Komga answers 401 without a key, which only the user holds.\n'
fi

if [ "$RUST_ONLY" = 1 ]; then
  say "swift phases skipped (--rust-only)"
fi

# --------------------------------------------------------------------------------
# The shipped surface. Everything above drives the reader library directly, which is
# the right level for the algorithms and the wrong level for the product: the app
# calls App::reader_*, and the seams (the sweep that a device report triggers, the
# promotion of a prefetched page on display, the memory mirror, the per-call prefetch
# budget) only exist in that layer.
# --------------------------------------------------------------------------------
say "the facade: the same calls the app makes"
# `App` derives its cache from the database's own directory, so both go in one.
mkdir -p "$WORK/facade"
FDB="$WORK/facade/facade.sqlite"
FCACHE="$WORK/facade/cache"
mkdir -p "$FCACHE/pages" "$FCACHE/prefetch" "$FCACHE/thumbnails"
# Damage for the sweep to find, planted before the first device report.
echo junk > "$FCACHE/pages/zz-orphan.png"
echo junk > "$FCACHE/pages/zz-half.png.part"
run facade "$FDB" "$FCACHE" "$SMALL_URL" --book small-520 \
  --device-memory $PHONE_RAM --pool-budget $POOL > "$WORK/facade.out" 2>&1 \
  || { tail -20 "$WORK/facade.out"; fail "the facade phase failed"; }
grep -E "^metric " "$WORK/facade.out" | sed 's/^metric /   metric /'
check "the device report swept the orphan file" "$([ -e "$FCACHE/pages/zz-orphan.png" ] && echo yes || echo no)" "no"
check "the device report swept the .part debris" "$([ -e "$FCACHE/pages/zz-half.png.part" ] && echo yes || echo no)" "no"
check "prefetch landed in the prefetch tier" "1" \
  "$(awk -F= '$1=="metric facade_prefetch_bytes" && $2+0>0 {print 1}' "$WORK/facade.out" | tail -1)"
check "prefetched bytes were mirrored into RAM" "1" \
  "$(awk -F= '$1=="metric facade_memory_bytes" && $2+0>0 {print 1}' "$WORK/facade.out" | tail -1)"
PROMOTED=$(metric "$WORK/facade.out" promoted_path)
case "$PROMOTED" in
  */pages/*) printf '   ok   displaying a prefetched page promoted it into pages/\n' ;;
  *) fail "a displayed prefetched page was not promoted: '$PROMOTED'" ;;
esac
check "clearing prefetch kept the displayed pages" "1" \
  "$(awk -F= '$1=="metric page_bytes_after_clear" && $2+0>0 {print 1}' "$WORK/facade.out" | tail -1)"
check "the ledger and the filesystem agree" "1" \
  "$(awk -F= '$1=="metric facade_ledger_bytes"{l=$2} $1=="metric facade_disk_bytes"{d=$2} END{print ((l-d)<4096 && (d-l)<4096)?1:0}' "$WORK/facade.out" | tail -1)"


# --------------------------------------------------------------------------------
# A long session counted in books, not pages. Fifty books in a sitting is a
# different failure mode from one 500-page book: the pool and the memory tier are
# bounded, but the process-level registry of open readers is bounded only by a
# matching reader_close.
# --------------------------------------------------------------------------------
say "many books, one process"
BOOKS=$(python3 - "$ROOT/specs/contracts/fixtures/sync/scenario-reconcile.json" <<'PY'
import json, sys
found = {}
def walk(x):
    if isinstance(x, dict):
        i = x.get("id")
        if isinstance(i, str) and i.startswith("book-"):
            found[i] = x.get("media", {}).get("pagesCount", 0) or 0
        for v in x.values():
            walk(v)
    elif isinstance(x, list):
        for v in x:
            walk(v)
walk(json.load(open(sys.argv[1])))
# Every book needs at least three pages to read; the phase reads pages 1..3.
print(",".join(sorted(k for k, v in found.items() if v >= 3)))
PY
)
echo "   fixture books: $BOOKS"
run books "$WORK/books.sqlite" "$WORK/cache-books" "$SMALL_URL" --books "$BOOKS" \
  --device-memory $PHONE_RAM --pool-budget $POOL > "$WORK/books.out" 2>&1 \
  || { tail -20 "$WORK/books.out"; fail "the many-books phase failed"; }
grep -E "^metric " "$WORK/books.out" | sed 's/^metric /   metric /'
check "every opened session was closed again" "0" "$(metric "$WORK/books.out" readers_after_close)"
check "prefetch bytes were all reclaimed" "0" "$(metric "$WORK/books.out" prefetch_bytes_after)"
check "displayed pages survived the prefetch cleanup" "1" \
  "$(awk -F= '$1=="metric page_bytes_after" && $2+0>0 {print 1}' "$WORK/books.out" | tail -1)"
check "the memory tier came back down after the books" "1" \
  "$(awk -F= '$1=="metric memory_bytes_after" && $2+0==0 {print 1}' "$WORK/books.out" | tail -1)"

say "summary"
if [ "$FAILURES" = 0 ]; then
  echo "STAGE 8 ACCEPTANCE OK"
else
  echo "STAGE 8 ACCEPTANCE FAILED: $FAILURES check(s)"
  exit 1
fi
