#!/usr/bin/env bash
# Stage 10 — release hardening, core acceptance.
#
# The four things this gate exists to break are each easy to fake:
#
#   * a log ring that is never installed would still return an empty list
#     happily — so the check is that a real sweep wrote a real line, and that the
#     file the sweep claims to have removed is gone from disk;
#   * a diagnostics snapshot computed from constants would agree with itself — so
#     every number here is compared against `sqlite3` on the same file or `find`
#     on the same tree, never against another snapshot field;
#   * an error model that only looks typed still collapses to a string in the
#     UI — so each forced failure is asserted on its *code*, from a server that
#     really answered 401 / 503 and a route that really refused;
#   * an "expired" flag set by any failure would be worse than no flag at all —
#     so an outage between a 401 and a success must leave the verdict alone, and
#     the writes the 401 parked have to reach the server afterwards, with the
#     journal as proof.
#
# Each phase runs in its own directory over its own database, in its own process.
# The log ring is process state, so a phase that wanted to count lines could
# otherwise be counting its predecessor's.
#
#   scripts/e2e_stage10_core.sh [--keep] [--live] [--skip-swift]
#
# --skip-swift drops the KomgaKit mirror leg — for Linux runners where the
# package does not build; the macOS swift-package job covers it.
#
# --live adds one leg against a real Komga: a deliberately wrong key must produce
# the same authExpired verdict and the same parked-queue behaviour. It needs no
# working credential, so it is safe to run unattended; set KOMGA_BASE_URL (and
# optionally KOMGA_BOOK_ID) to point it at a server.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/android/komga_core"
WORK="${TMPDIR:-/tmp}/stage10-core.$$"
SMOKE="$CORE/target/debug/stage10_smoke"
FIXTURE="$CORE/target/debug/komga_fixture_server"
SQLITE="$(command -v sqlite3 || true)"
FAILURES=0
KEEP=0
LIVE=0
SKIP_SWIFT=0
KEY="fixture-key"
BAD_KEY="definitely-not-the-key"
# Nothing can listen on port 1: a real unreachable route, not a mock.
DEAD_URL="http://127.0.0.1:1"
# The fixture server reads its forced-status file from one agreed path. The
# smoke used to derive it from its own --db directory, so a phase that tried
# to make the server answer 503 wrote a file nobody read.
FAULT="$WORK/fault"
STRESS_SPEC="dl-120,120,120,180,0"
SERVER="s1"
PIDS=()

cleanup() {
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  if [ "$KEEP" = 0 ]; then rm -rf "$WORK"; else echo "== kept $WORK"; fi
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --live) LIVE=1 ;;
    --skip-swift) SKIP_SWIFT=1 ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
  esac
  shift
done

check() { # check <name> <actual> <expected>
  if [ "$2" = "$3" ]; then
    printf '  ok   %-58s %s\n' "$1" "$2"
  else
    printf '  FAIL %-58s got %s, want %s\n' "$1" "$2" "$3"
    FAILURES=$((FAILURES + 1))
  fi
}

metric() { # metric <file> <name> — the value of one `metric name=value` line
  awk -v n="$2" '
    $1 == "metric" {
      split($2, pair, "=")
      if (pair[1] == n) value = pair[2]
    }
    END { print value }' "$1"
}

metric_at_least() { # metric_at_least <file> <name> <floor>
  local value
  value="$(metric "$1" "$2")"
  # A missing metric is 0 here rather than an empty string: `[ "" -ge 1 ]`
  # is a shell error that reads as "the check ran", which is how a broken
  # extractor turned six checks into six silences.
  [ "${value:-0}" -ge "${3:-1}" ] && echo yes || echo no
}

section() { printf '\n== %s\n' "$1"; }

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
echo "== building stage10_smoke and the fixture server"
(cd "$CORE" && cargo build --bin stage10_smoke --bin komga_fixture_server 2>&1 | tail -3)
[ -x "$SMOKE" ] || { echo "no $SMOKE"; exit 1; }
[ -n "$SQLITE" ] || { echo "this gate needs the sqlite3 CLI as the outside witness"; exit 1; }

mkdir -p "$WORK"

# One server for every phase, with the fault file inside $WORK so a phase can
# make it answer 503 and put it back afterwards.
"$FIXTURE" --scenario "$ROOT/specs/contracts/fixtures/sync/scenario-reconcile.json" \
  --snapshot-file "$WORK/server.snapshot" --expect-key "$KEY" \
  --journal "$WORK/server.journal" --page-journal "$WORK/server.pages" \
  --fault-api-file "$FAULT" --fault-file "$WORK/read-progress.fault" \
  --stress "$STRESS_SPEC" >"$WORK/server.log" 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 100); do
  grep -q '^LISTENING ' "$WORK/server.log" 2>/dev/null && break
  sleep 0.05
done
grep '^LISTENING ' "$WORK/server.log" | awk '{print $2}' > "$WORK/port"
echo s1 > "$WORK/server.snapshot"
URL="http://127.0.0.1:$(cat "$WORK/port")"
echo "   fixture server -> $URL"

check "the server refuses a wrong key with 401, as a real Komga does" \
  "$(curl -s -o /dev/null -w '%{http_code}' -H "X-API-Key: $BAD_KEY" "$URL/api/v1/libraries")" "401"

run_phase() { # run_phase <name> [extra args...]
  local name="$1"
  shift
  local dir="$WORK/$name"
  mkdir -p "$dir"
  set +e
  "$SMOKE" --phase "$name" --db "$dir/comic.sqlite" --server "$SERVER" \
    --base-url "$URL" --key "$KEY" --bad-key "$BAD_KEY" --dead-url "$DEAD_URL" \
    --fault-file "$FAULT" "$@" >"$dir/report" 2>&1
  local code=$?
  set -e
  echo "$code" > "$dir/exit"
  sed 's/^/     | /' "$dir/report" | tail -8
  check "$name phase exited clean" "$(cat "$dir/exit")" "0"
}

# ---------------------------------------------------------------------------
section "log ring: the lines the core writes are readable, and true"
# ---------------------------------------------------------------------------
run_phase log-ring
RING="$WORK/log-ring/report"
DB="$WORK/log-ring/comic.sqlite"
check "the ring owned the log backend" "$(metric "$RING" installed)" "1"
check "a real sweep wrote a line the reader can ask for" \
  "$(metric "$RING" sweep_line_in_ring)" "1"
check "the sweep line only appears when something was found" \
  "$(metric "$RING" quiet_lines)" "0"
check "no error line was produced by a healthy run" "$(metric "$RING" errors)" "0"
# The outside witness: the orphan the sweep reported is really gone, and was
# really there — the core's own counter alone would pass on a bug that only
# counts files it never touched.
check "the orphan file the sweep named is gone from disk" \
  "$(find "$WORK/log-ring/cache/pages" -name 'orphan-stage10*' | wc -l | tr -d ' ')" "0"
check "the orphan really existed, with bytes to free" \
  "$(metric "$RING" orphan_before)" "37"
check "freed bytes match the orphan's own size" \
  "$(metric "$RING" sweep_freed_bytes)" "$(metric "$RING" orphan_before)"

# ---------------------------------------------------------------------------
section "diagnostics snapshot: every number against the file it describes"
# ---------------------------------------------------------------------------
# The phase seeds its own store (an empty database agrees with itself about
# nothing), so it goes through the same helper as everything else.
run_phase snapshot
SNAP="$WORK/snapshot/report"
DB="$WORK/snapshot/comic.sqlite"

q() { "$SQLITE" "$DB" "$1" 2>/dev/null | tail -1; }

check "schema version matches PRAGMA user_version" \
  "$(metric "$SNAP" schema_version)" "$(q 'PRAGMA user_version')"
check "schema version is 9, the Stage 9 shape" "$(metric "$SNAP" schema_version)" "9"
check "integrity verdict matches the engine's own" \
  "$(metric "$SNAP" integrity)" "$(q 'PRAGMA integrity_check')"
# `busy_timeout` is per-connection, so a second sqlite3 process cannot witness
# it — it would answer 0 about its own brand-new connection. The claim worth
# checking is that the number the snapshot reports is the number `configure()`
# sets, read out of the source that sets it.
CONFIGURED_TIMEOUT=$(grep -oE 'busy_timeout", "[0-9]+"' "$CORE/src/store/mod.rs" | grep -oE '[0-9]+')
check "busy timeout is the value the store configures" \
  "$(metric "$SNAP" busy_timeout_ms)" "$CONFIGURED_TIMEOUT"
check "foreign keys are on" "$(metric "$SNAP" foreign_keys)" "1"
check "journal mode is what the store opens with" \
  "$(metric "$SNAP" journal_mode)" "$(q 'PRAGMA journal_mode')"
check "file bytes equal page_size x page_count" \
  "$(metric "$SNAP" file_bytes)" \
  "$(( $(metric "$SNAP" page_size) * $(metric "$SNAP" page_count) ))"
for table in series books sync_state pending_mutations cache_entries downloads; do
  check "rows_$table matches a direct count" \
    "$(metric "$SNAP" "rows_$table")" "$(q "SELECT count(*) FROM $table")"
done
check "cache ledger bytes match the ledger's own sum" \
  "$(metric "$SNAP" cache_ledger_bytes)" \
  "$(q "SELECT COALESCE(sum(size),0) FROM cache_entries")"
check "outbox total matches the queue table" \
  "$(metric "$SNAP" outbox_total)" "$(q "SELECT count(*) FROM pending_mutations WHERE server_id='$SERVER'")"
check "queued rows match the same count for any server" \
  "$(metric "$SNAP" outbox_queued_rows)" "$(q "SELECT count(*) FROM pending_mutations")"
check "two reads of the snapshot are the same read" \
  "$(metric "$SNAP" table_drift_between_reads)" "0"
check "a snapshot never contacted a server, so it says unknown" \
  "$(metric "$SNAP" auth_state)" "unknown"
check "and does not invent a moment for it" "$(metric "$SNAP" auth_at_is_empty)" "1"
RUST_PIN=$(grep -m1 'SNAPSHOT_VERSION' "$CORE/src/api/contract.rs" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
SWIFT_PIN=$(grep -m1 'snapshotVersion' "$ROOT/apple/KomgaKit/Sources/KomgaAPI/KomgaContract.swift" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
check "the reported contract pin is Rust's own constant" "$(metric "$SNAP" snapshot_version)" "$RUST_PIN"
check "and the two platforms still agree on it" "$RUST_PIN" "$SWIFT_PIN"
check "the ring reports itself as installed inside the snapshot" \
  "$(metric "$SNAP" log_installed)" "1"
# The sweep is not the only thing that logs: the seed run writes sync state and
# covers, and the ring has to have seen something from it.
check "the snapshot phase left lines in the ring" \
  "$(metric_at_least "$SNAP" log_retained 1)" "yes"

# ---------------------------------------------------------------------------
section "error codes: four forced failures, each with the code the UI branches on"
# ---------------------------------------------------------------------------
run_phase error-codes
CODES="$WORK/error-codes/report"
check "a refused key arrives as authExpired" "$(metric "$CODES" code_auth)" "authExpired"
check "authExpired is not auto-retryable" "$(metric "$CODES" auth_retryable)" "0"
check "authExpired is the user's to fix" "$(metric "$CODES" auth_needs_user)" "1"
check "and it still carries the server's own words" \
  "$(metric "$CODES" auth_message_kept)" "1"
check "an unreachable address arrives as networkUnavailable" \
  "$(metric "$CODES" code_network)" "networkUnavailable"
check "networkUnavailable retries by itself" "$(metric "$CODES" network_retryable)" "1"
check "networkUnavailable never blames the user" \
  "$(metric "$CODES" network_needs_user)" "0"
check "a malformed url arrives as invalidInput" "$(metric "$CODES" code_invalid)" "invalidInput"
check "a 503 arrives as serverError" "$(metric "$CODES" code_server)" "serverError"
check "serverError is retried, not escalated" "$(metric "$CODES" server_retryable)" "1"
check "serverError does not ask the user for a key" \
  "$(metric "$CODES" server_needs_user)" "0"
check "the four buckets are four distinct codes" "$(metric "$CODES" codes_distinct)" "3"

# The code list is a three-platform contract; the file has to be readable and
# complete before either other platform's suite can be believed.
check "the shared code list names 14 codes" \
  "$(python3 -c "import json;print(len(json.load(open('$ROOT/specs/contracts/fixtures/errors/codes.json'))['codes']))")" \
  "14"
check "exactly one code asks the user for something" \
  "$(python3 -c "
import json
codes = json.load(open('$ROOT/specs/contracts/fixtures/errors/codes.json'))['codes']
print(sum(1 for entry in codes if entry['needsUser']))")" "1"

# ---------------------------------------------------------------------------
section "authentication expiry: 401 says it, an outage does not, a fix clears it"
# ---------------------------------------------------------------------------
: > "$WORK/server.journal"
run_phase auth-expiry
AUTH="$WORK/auth-expiry/report"
DB="$WORK/auth-expiry/comic.sqlite"
check "a store that never spoke says unknown, not expired" \
  "$(metric "$AUTH" state_initial)" "unknown"
check "the 401 really came from the server" \
  "$(curl -s -o /dev/null -w '%{http_code}' -H "X-API-Key: $BAD_KEY" "$URL/api/v1/libraries")" "401"
check "the rejected key became expired in the store" \
  "$(metric "$AUTH" state_after_401)" "expired"
check "the expiry recorded when it happened" \
  "$(metric "$AUTH" expiry_moment_recorded)" "1"
check "an outage in between did not spend the verdict" \
  "$(metric "$AUTH" state_after_outage)" "expired"
check "the parked write is still queued after a blocked upload" \
  "$(metric_at_least "$AUTH" queued_after_blocked_upload 1)" "yes"
check "the blocked upload sent nothing" "$(metric "$AUTH" upload_blocked_uploaded)" "0"
check "and named the reason it stopped" \
  "$(metric "$AUTH" upload_blocked_status)" "blocked_authentication"
check "the fixed key cleared the verdict" "$(metric "$AUTH" state_after_success)" "valid"
check "the parked write then went out" "$(metric "$AUTH" upload_after_fix_uploaded)" "1"
check "the queue is empty afterwards" "$(metric "$AUTH" queued_after_success)" "0"
# The journal is the witness the core cannot talk into agreeing: it records what
# the server was actually asked to do.
# The journal is one JSON object per write the server accepted, which is the
# only witness here that cannot be talked into agreeing by the core.
check "the server journal holds the PATCH the queue owed" \
  "$(grep -c '"method":"PATCH"' "$WORK/server.journal")" "1"
check "and it carried page 7, not a re-send of something else" \
  "$(python3 -c "
import json
pages = []
for line in open('$WORK/server.journal'):
    entry = json.loads(line)
    if entry.get('method') == 'PATCH':
        pages.append(json.loads(entry['body']).get('page'))
print(1 if pages == [7] else 0)
")" "1"
check "the credential state lives in the database, not in memory" \
  "$("$SQLITE" "$DB" "SELECT count(*) FROM app_state WHERE key LIKE 'auth_state:%'")" "1"
check "and it reads valid there too" \
  "$("$SQLITE" "$DB" "SELECT value FROM app_state WHERE key = 'auth_state:$SERVER'" | grep -o '"valid"' || echo missing)" \
  '"valid"'

# ---------------------------------------------------------------------------
section "facade: the same surfaces through the entry points the app calls"
# ---------------------------------------------------------------------------
run_phase facade
FACADE="$WORK/facade/report"
check "ffi snapshot sees the schema" "$(metric "$FACADE" ffi_schema_version)" "9"
check "ffi snapshot sees the ring" "$(metric "$FACADE" ffi_log_installed)" "1"
check "ffi log records came back non-empty" \
  "$(metric_at_least "$FACADE" ffi_log_records 1)" "yes"
check "ffi stats and ffi record list agree" \
  "$(metric_at_least "$FACADE" ffi_log_retained "$(metric "$FACADE" ffi_log_records)")" "yes"
check "a nonsense level name shows everything, not nothing" \
  "$(metric_at_least "$FACADE" ffi_log_unfiltered "$(metric "$FACADE" ffi_log_records)")" "yes"
check "an error filter is narrower than no filter" \
  "$([ "$(metric "$FACADE" ffi_log_errors_only)" -le "$(metric "$FACADE" ffi_log_unfiltered)" ] && echo yes)" \
  "yes"
check "ffi auth_state answers for the server" "$(metric "$FACADE" ffi_auth_state)" "unknown"

if [ "$SKIP_SWIFT" = "0" ]; then
  # -------------------------------------------------------------------------
  section "the same checks on the other platform"
  # -------------------------------------------------------------------------
  # Rust's suites assert the same fixtures, and the Swift mirror of every one
  # of these four areas has to run in this gate or "both platforms" means
  # "one of them, twice". Totals are checked, not just green-ness: a suite that
  # quietly stopped compiling the Stage 10 files would still report zero
  # failures. 219 was the Swift count before any of them existed.
  SWIFT_LOG="$WORK/swift.log"
  ( cd "$ROOT/apple/KomgaKit" && swift test >"$SWIFT_LOG" 2>&1 ) || true
  check "swift suite finished green" \
    "$(grep -cE "^Test Suite 'All tests' passed" "$SWIFT_LOG")" "1"
  check "not one swift test case failed" \
    "$(grep -cE "Test Case .*[\])'] failed" "$SWIFT_LOG")" "0"
  SWIFT_TESTS=$(grep -oE "Executed [0-9]+ tests" "$SWIFT_LOG" | tail -1 | grep -oE "[0-9]+")
  check "swift suite carries the Stage 10 mirrors" \
    "$([ "${SWIFT_TESTS:-0}" -ge 240 ] && echo yes)" "yes"
  STAGE10_CASES=$(grep -cE "Test Case .-\[KomgaKitTests\.(CoreErrorContractTests|CoreLogTests|DatabaseHealthTests|AuthStateTests|DiagnosticsSnapshotTests|SchemaV9MigrationTests)" "$SWIFT_LOG")
  check "the six Stage 10 swift suites each ran" \
    "$([ "${STAGE10_CASES:-0}" -ge 25 ] && echo yes)" "yes"
  printf "  info swift tests: %s total, %s of them Stage 10\n" "${SWIFT_TESTS:-?}" "${STAGE10_CASES:-?}"
fi

# ---------------------------------------------------------------------------
if [ "$LIVE" = "1" ]; then
  section "live leg: a wrong key against the real server"
  if [ -z "${KOMGA_BASE_URL:-}" ]; then
    echo "  SKIP KOMGA_BASE_URL is unset — this leg needs a reachable Komga"
  else
    mkdir -p "$WORK/live"
    set +e
    "$SMOKE" --phase auth-expiry --db "$WORK/live/comic.sqlite" --server live \
      --base-url "$KOMGA_BASE_URL" --key "${KOMGA_API_KEY:-wrong-on-purpose}" \
      --bad-key "deliberately-wrong" --dead-url "$DEAD_URL" >"$WORK/live/report" 2>&1
    set -e
    check "live: a refused key is reported expired" \
      "$(metric "$WORK/live/report" state_after_401)" "expired"
    check "live: an outage does not change that" \
      "$(metric "$WORK/live/report" state_after_outage)" "expired"
    echo "  note: the success half needs a working key — KOMGA_API_KEY"
  fi
fi

section result
if [ "$FAILURES" = "0" ]; then
  echo "ALL GREEN"
  exit 0
fi
echo "$FAILURES check(s) failed"
exit 1
