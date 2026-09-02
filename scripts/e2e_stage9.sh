#!/usr/bin/env bash
# Stage 9 — offline download acceptance.
#
# The claims this gate exists to break: a book the user downloaded is readable with
# the network off; nothing that cleans a cache can delete it; and a progress write
# made while offline reaches the server the moment the link comes back.
#
# Every phase runs as its own process over its own directory. That is not tidiness:
# the download tree is derived from the database's location (`<db dir>/downloads`), so
# two phases sharing a directory would share a tree — and a sweep that adopted another
# phase's orphan files would pass while proving nothing. That exact confusion produced
# `arm_adopted=89` while this gate was being written.
#
# Each phase's own report is checked against two witnesses it cannot talk into
# agreeing: the fixture server's journals (what was requested, what was written) and
# the filesystem (`find`, `stat`). Where they disagree, this script believes the disk.
#
#   scripts/e2e_stage9.sh [--keep] [--rust-only]
#
# Live leg: KOMGA_BASE_URL + KOMGA_API_KEY + KOMGA_BOOK_ID download and read a real
# book. Without them the leg is skipped and says so.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/android/komga_core"
WORK="${TMPDIR:-/tmp}/stage9.$$"
SMOKE="$CORE/target/debug/stage9_smoke"
FIXTURE="$CORE/target/debug/komga_fixture_server"
FAILURES=0
KEEP=0
RUST_ONLY=0
KEY="fixture-key"
PORTS=()
STRESS_BOOK="dl-120"
STRESS_SPEC="dl-120,120,120,180,0"
PAGES=120
SERVER_ID="A"
BOOK="$STRESS_BOOK"

cleanup() {
  for pid in ${PORTS[@]+"${PORTS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  if [ "$KEEP" = 0 ]; then rm -rf "$WORK"; else echo "== kept $WORK"; fi
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP=1 ;;
    --rust-only) RUST_ONLY=1 ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$WORK"
export RUST_LOG="${RUST_LOG:-warn}"

say() { printf '\n== %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf '   FAIL %s\n' "$*" >&2; }
check() {
  if [ "$2" = "$3" ]; then printf '   ok   %s (%s)\n' "$1" "$2"; else fail "$1: got $2, want $3"; fi
}
check_ge() {
  if [ "$(awk -v a="$2" -v b="$3" 'BEGIN{print (a>=b)?1:0}')" = 1 ]; then
    printf '   ok   %s (%s >= %s)\n' "$1" "$2" "$3"
  else fail "$1: $2 below the floor $3"; fi
}
check_le() {
  if [ "$(awk -v a="$2" -v b="$3" 'BEGIN{print (a<=b)?1:0}')" = 1 ]; then
    printf '   ok   %s (%s <= %s)\n' "$1" "$2" "$3"
  else fail "$1: $2 exceeds $3"; fi
}

# metric <label> <name> — what the phase itself reported. `metric name=value` is one
# whitespace-separated pair, so the line splits on space first and on `=` second.
metric() {
  awk -v want="$2" '$1=="metric"{split($2,kv,"="); if(kv[1]==want) print kv[2]}' \
    "$WORK/$1.out" | tail -1
}

# Page reads only: the manifest route journals into the same file, and counting it
# would make every phase look like it asked for one page too many.
journal_reads() {
  if [ -f "$WORK/$1.pages" ]; then grep -c '"kind": *"page"' "$WORK/$1.pages" || true; else echo 0; fi
}
mutation_journal() {
  if [ -f "$WORK/$1.journal" ]; then grep -c '"method": *"PATCH"' "$WORK/$1.journal" || true; else echo 0; fi
}

# A phase that continues another phase's work names that phase's database: the queue
# is SQLite plus a tree derived from the database's location, so "the same download"
# means literally the same file. Phases that start fresh leave <db-label> = <label>.
# The base URL is passed by value, not by name: bash 3.2's indirect expansion cannot
# see a variable declared in a multi-assignment `local`, and reports it unbound.
run_phase() { # run_phase <label> <db-label> <phase> <base-url> <journal> [args...]
  local label="$1" db_label="$2" phase="$3" base_url="$4" journal="$5"
  shift 5
  local dir="$WORK/$db_label"
  mkdir -p "$dir"
  local before
  before=$(journal_reads "$journal")
  if ! "$SMOKE" --phase "$phase" --db "$dir/comic.sqlite" \
      --base-url "$base_url" --offline-url "$OFFLINE_URL" --gone-url "$GONE_URL" \
      --key "$KEY" --server-id "$SERVER_ID" --book "$BOOK" "$@" \
      >"$WORK/$label.out" 2>&1; then
    fail "$phase reported failure"
    tail -6 "$WORK/$label.out" >&2
  fi
  echo "$(( $(journal_reads "$journal") - before ))" > "$WORK/$label.jdelta"
  # The journal line the phase started at, so a distinct-page count can be taken over
  # exactly its own window. Two cumulative counts do not subtract into an answer: the
  # second pass over the same 120 pages would report "0 distinct".
  echo "$before" > "$WORK/$label.jbase"
}
journal_delta() { cat "$WORK/$1.jdelta"; }
# distinct_pages <label> <server> — different pages served within this phase's window.
distinct_pages() {
  local label="$1" server="$2" lo hi
  lo=$(cat "$WORK/$label.jbase")
  hi=$(( lo + $(cat "$WORK/$label.jdelta") ))
  awk -F'"' -v lo="$lo" -v hi="$hi" '
    /"kind": *"page"/{n++; if (n>lo && n<=hi) {for(i=1;i<=NF;i++) if ($i=="asked") {gsub(/[^0-9]/,"",$(i+1)); print $(i+1)}}}' \
    "$WORK/$server.pages" 2>/dev/null | sort -u | grep -c . || true
}

# The tree a phase built, measured by the shell rather than by the core.
tree_dir() { echo "$WORK/$1/downloads/$SERVER_ID/$BOOK"; }   # <db-label>
tree_pages() {
  local dir; dir=$(tree_dir "$1")
  if [ -d "$dir" ]; then find "$dir" -maxdepth 1 -type f -name '[0-9]*' ! -name '*.part' | wc -l | tr -d ' '; else echo 0; fi
}
tree_parts() {
  local dir; dir=$(tree_dir "$1")
  if [ -d "$dir" ]; then find "$dir" -maxdepth 1 -type f -name '*.part' | wc -l | tr -d ' '; else echo 0; fi
}
tree_bytes() {
  local dir; dir=$(tree_dir "$1")
  if [ -d "$dir" ]; then
    find "$dir" -maxdepth 1 -type f -name '[0-9]*' ! -name '*.part' -exec stat -f %z {} + | awk '{s+=$1} END {print s+0}'
  else echo 0; fi
}

# ------------------------------------------------------------------ build ----
say "1/5 build"
(cd "$CORE" && cargo build --quiet --bin stage9_smoke --bin komga_fixture_server)
check "the smoke and the fixture server build" "$?" "0"

# ---------------------------------------------------------------- servers ---
say "2/5 fixture servers (one per shape of trouble)"
start_server() { # start_server <name> <stress-spec|none> [extra flags...]
  local name="$1" spec="$2"
  shift 2
  local log="$WORK/$name.log"
  local args=(
    --scenario "$ROOT/specs/contracts/fixtures/sync/scenario-reconcile.json"
    --snapshot-file "$WORK/$name.snapshot" --expect-key "$KEY"
    --journal "$WORK/$name.journal" --page-journal "$WORK/$name.pages"
  )
  [ "$spec" != "none" ] && args+=(--stress "$spec")
  "$FIXTURE" "${args[@]}" "$@" >"$log" 2>&1 &
  PORTS+=("$!")
  for _ in $(seq 1 100); do
    grep -q '^LISTENING ' "$log" 2>/dev/null && break
    sleep 0.05
  done
  grep '^LISTENING ' "$log" | awk '{print $2}' > "$WORK/$name.port"
  # The Stage 5/6 scenario snapshots are keyed s0..sN; s1 is the converged library.
  echo s1 > "$WORK/$name.snapshot"
  printf '   %s -> port %s\n' "$name" "$(cat "$WORK/$name.port")"
}

start_server dl "$STRESS_SPEC"
start_server slow "$STRESS_SPEC" --delay-ms 400
start_server rotten "$STRESS_SPEC" --truncate-every 3
start_server gone none
DL_URL="http://127.0.0.1:$(cat "$WORK/dl.port")"
SLOW_URL="http://127.0.0.1:$(cat "$WORK/slow.port")"
ROTTEN_URL="http://127.0.0.1:$(cat "$WORK/rotten.port")"
GONE_URL="http://127.0.0.1:$(cat "$WORK/gone.port")"
# Nothing can listen on port 1: an outage that is a real unreachable route, not a mock.
OFFLINE_URL="http://127.0.0.1:1"
for server in dl slow rotten; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$DL_URL/api/v1/actuator/info" || true)
  [ "$server" = "dl" ] && check "$server answers 401 without a key, as a real Komga does" "$code" "401"
done
check "the 404 server really has no such book" \
  "$(curl -s -o /dev/null -w '%{http_code}' -H "X-API-Key: $KEY" "$GONE_URL/api/v1/books/$STRESS_BOOK/pages/1?zero_based=false")" "404"
check "the honest server declares every page" \
  "$(curl -s -H "X-API-Key: $KEY" "$DL_URL/api/v1/books/$STRESS_BOOK/pages" | grep -o '"number"' | wc -l | tr -d ' ')" "$PAGES"
check "and declares the size the body actually has" \
  "$(curl -s -H "X-API-Key: $KEY" "$DL_URL/api/v1/books/$STRESS_BOOK/pages" | grep -o '"sizeBytes":65048' | head -1 | grep -c sizeBytes)" "1"
check "a truncated page really is shorter than declared" \
  "$([ "$(curl -s -H "X-API-Key: $KEY" "$ROTTEN_URL/api/v1/books/$STRESS_BOOK/pages/3?zero_based=false" | wc -c | tr -d ' ')" -lt 65048 ] && echo yes)" "yes"

# ------------------------------------------------------------------ phases --
say "3/5 the queue"


run_phase enqueue-pump enqueue-pump enqueue-pump "$DL_URL" dl --max-pages 4
check "整书下载 ends completed" "$(metric enqueue-pump final_state)" "completed"
check "every page is accounted for" "$(metric enqueue-pump pages_done)" "$PAGES"
check "one file per page" "$(metric enqueue-pump files)" "$PAGES"
check "the per-pass bound was obeyed (120 pages at 4 a pass)" "$(metric enqueue-pump passes)" "30"
check "the passes add up to the book" "$(metric enqueue-pump served_total)" "$PAGES"
check "no staging file survives a finished download" "$(metric enqueue-pump parts_left)" "0"
check "the server served exactly one request per page" "$(journal_delta enqueue-pump)" "$PAGES"
check "and they were 120 different pages" "$(distinct_pages enqueue-pump dl)" "$PAGES"
check "rows and disk agree on the bytes" "$(metric enqueue-pump bytes_db)" "$(metric enqueue-pump bytes_disk)"
check "the manifest agrees with both" "$(metric enqueue-pump manifest_bytes)" "$(metric enqueue-pump bytes_disk)"
check "the manifest lists every page" "$(metric enqueue-pump manifest_pages)" "$PAGES"
check "the queue knew the size before it started" "$(metric enqueue-pump queued_pages)" "$PAGES"
check "a queued book starts with an empty manifest" "$(metric enqueue-pump initial_manifest_pages)" "0"
check "find counts what the core counted" "$(tree_pages enqueue-pump)" "$PAGES"
check "du agrees with the reported bytes" "$(tree_bytes enqueue-pump)" "$(metric enqueue-pump bytes_disk)"
check "no .part anywhere in the tree" "$(tree_parts enqueue-pump)" "0"
first=$(basename "$(find "$(tree_dir enqueue-pump)" -name '[0-9]*' | sort | head -1)")
last=$(basename "$(find "$(tree_dir enqueue-pump)" -name '[0-9]*' | sort | tail -1)")
check "files are named by page number, first" "$first" "0001.png"
check "files are named by page number, last" "$last" "0120.png"

run_phase read-while read-while read-while "$DL_URL" dl --max-pages 2
check "边下边读 read the whole book" "$(metric read-while pages_read)" "$PAGES"
check_ge "the reader took downloaded pages without fetching them again" \
  "$(metric read-while read_from_download_tier)" "1"
check_ge "and overtook the queue at least once, which is the mixed walk" \
  "$(metric read-while reader_own_fetches)" "1"
check "the queue still finished the book" "$(metric read-while final_state)" "completed"
check "with one file per page" "$(metric read-while files)" "$PAGES"
# Deliberately NOT a "no duplicate requests" claim: the reader and the queue can each
# want the page the other is mid-way through, and one extra request for it is correct
# behaviour. What must hold is that no page is missing and none is duplicated on disk.
check_ge "the server saw at least one request per page" "$(journal_delta read-while)" "$PAGES"
check "and no page was missing from the walk" "$(distinct_pages read-while dl)" "$PAGES"
check "no .part survived the interleaving" "$(tree_parts read-while)" "0"

run_phase link-down link-down link-down "$DL_URL" dl --max-pages 4
check "断网续传 burned no attempts while the route was down" \
  "$(metric link-down attempts_during)" "$(metric link-down attempts_before)"
check "the book's progress did not move during the outage" \
  "$(metric link-down pages_during)" "$(metric link-down before_outage_pages)"
check "a pass against a dead route says linkDown" "$(metric link-down outage_stop)" "linkDown"
check "the queue finished on its own when the link came back" \
  "$(metric link-down final_state)" "completed"
check "and fetched exactly what was left, with no manual retry" \
  "$(metric link-down after_recovery_served)" "$((PAGES - $(metric link-down before_outage_pages)))"

run_phase rotten-pages rotten-pages rotten-pages "$ROTTEN_URL" rotten --max-pages 4
check "单页失败: the book says failed rather than pretending to be whole" \
  "$(metric rotten-pages rotten_state)" "failed"
check "bad pages were counted, not swallowed" "$(metric rotten-pages bad_pages)" "40"
check "the queue moved past them and kept the other 80" \
  "$(metric rotten-pages served_first_try)" "80"
check "no page was retried past the contract" "$(metric rotten-pages attempts_max)" "3"
run_phase rotten-repair rotten-pages rotten-repair "$DL_URL" dl --max-pages 4
check "the retry cost exactly the pages that had failed" \
  "$(metric rotten-repair repair_served)" "$(metric rotten-repair repair_failed_before)"
check "and the book completed" "$(metric rotten-repair repair_state)" "completed"
check "the healthy server saw 40 requests, not 120" "$(journal_delta rotten-repair)" "40"

run_phase interrupted-write interrupted-write interrupted-write "$DL_URL" dl --max-pages 8
check "a torn write is reaped" "$(metric interrupted-write arm_stale_parts)" "1"
check "a row whose file is gone is healed" "$(metric interrupted-write arm_ghost_rows)" "1"
check "a file the database forgot is adopted, not deleted" "$(metric interrupted-write arm_adopted)" "1"
check "a file that is not an image is refused by the container walk" \
  "$(metric interrupted-write arm_corrupt)" "1"
check "a file whose length drifted is caught by the size check" \
  "$(metric interrupted-write arm_size_mismatch)" "1"
check "derived counters were recomputed from the rows" \
  "$(metric interrupted-write arm_counters)" "1"
check "the manifest was rebuilt from the rows" "$(metric interrupted-write arm_manifests)" "1"
check "a dead pass's mark does not stay on the book forever" \
  "$(metric interrupted-write state_after_sweep)" "waiting"
check_le "the sweep only freed the files it removed" \
  "$(metric interrupted-write arm_freed)" "$((6 * 65048))"

run_phase survives-everything survives-everything survives-everything "$DL_URL" dl --max-pages 8
protected=$(metric survives-everything files_before)
check "the download under attack holds the whole book" "$protected" "$PAGES"
for attack in after_budget after_clear_prefetch after_clear_page after_reconcile after_prune after_restart; do
  check "$attack left every downloaded file alone" "$(metric survives-everything $attack)" "$protected"
done
check "a book the server dropped is labelled, not hidden" \
  "$(metric survives-everything stale_after_prune)" "true"
check "the user's delete really removes the files" \
  "$(metric survives-everything after_delete)" "0"
check "and reports the bytes it freed" \
  "$(metric survives-everything delete_bytes)" "$(metric survives-everything bytes_before)"
check "nothing is left in the tree after a delete" "$(tree_pages survives-everything)" "0"

run_phase offline-setup offline-setup enqueue-pump "$DL_URL" dl --max-pages 8
# Snapshot the honest server's page journal around the offline walk: the phase's own
# URL is the dead port, so any growth here means something reached out anyway.
DL_READS_BEFORE=$(journal_reads dl)
run_phase offline-run offline-setup offline-run "$DL_URL" none --max-pages 8
# More than the one row this harness seeded: the library has to be a synced library.
check_ge "断网: the local media library answers with no server" "$(metric offline-run library_rows)" "5"
check "the downloaded book is listed" "$(metric offline-run downloaded_books)" "1"
check "opening it was a local operation" "$(metric offline-run opened_from_mirror)" "true"
check "the whole book read" "$(metric offline-run pages_read)" "$PAGES"
check "every page came out of the download tree" \
  "$(metric offline-run served_from_downloads)" "$PAGES"
check "the position the user turned to was saved locally" "$(metric offline-run position_saved)" "3"
check "and the write queued itself instead of being dropped" "$(metric offline-run outbox_queued)" "1"
# The strongest line in this file. Not the client's word about its cache: the server's
# own record of what it was asked for while the app read a whole book.
check "the server was asked for nothing during the offline read" \
  "$(journal_reads dl)" "$DL_READS_BEFORE"

run_phase reconnect-upload offline-setup reconnect-upload "$DL_URL" dl --max-pages 8
check "the queued position was pending before the upload" \
  "$(metric reconnect-upload pending_before)" "1"
check "nothing is pending afterwards" "$(metric reconnect-upload pending_after)" "0"
check "the uploader says it sent the row" "$(metric reconnect-upload rows_uploaded)" "1"
if grep -qF 'page\":3' "$WORK/dl.journal" 2>/dev/null; then
  printf '   ok   the server received the progress write it could not get while offline\n'
else
  fail "the server journal has no PATCH carrying page 3 — the upload is unproven"
fi
check "the journal holds exactly the writes the queue made" "$(mutation_journal dl)" "$(metric reconnect-upload uploaded)"

run_phase storage-check offline-setup storage "$DL_URL" dl --max-pages 8
run_phase storage-build storage-build enqueue-pump "$DL_URL" dl --max-pages 40
check "two screens report the same download total" \
  "$(metric storage-check stats_download_bytes)" "$(metric storage-check download_bytes)"
check "the platform's answer is passed through, not rewritten" \
  "$(metric storage-check free_volume_bytes)" "1073741824"
check "the storage figure matches the tree on disk" \
  "$(metric storage-build bytes_disk)" "$(tree_bytes storage-build)"
run_phase storage-unknown storage-build storage "$DL_URL" dl --max-pages 8 --free-bytes 0
check "a platform that will not talk reports 0, which the core reads as unknown" \
  "$(metric storage-unknown free_volume_bytes)" "0"

run_phase facade facade facade "$DL_URL" dl --max-pages 4
check "the facade queues a book" "$(metric facade facade_enqueue)" "waiting"
check "the facade pauses it" "$(metric facade facade_pause)" "paused"
check "the facade resumes it" "$(metric facade facade_resume)" "waiting"
check "cellular consent sticks to the book" "$(metric facade facade_consent)" "true"
check "the queue lists one book" "$(metric facade facade_list)" "1"
check "a healthy tree needs no repair" "$(metric facade facade_sweep_repairs)" "0"
check "two concurrent passes: one got the database" "$(metric facade pump_worked_count)" "1"
check "and the other was told so" "$(metric facade pump_none_count)" "1"
check "the pass that ran made progress" "$(metric facade facade_served)" "4"
check "the facade's delete removed the files" "$(metric facade facade_files_after)" "0"

run_phase remote-gone remote-gone remote-gone "$DL_URL" gone --max-pages 4
check "a 404 is read as the book being gone" "$(metric remote-gone gone_stop)" "gone"
check "the book ends failed rather than looping" "$(metric remote-gone gone_state)" "failed"
check "a vanished book burned no page retries" "$(metric remote-gone attempts_burned)" "0"
check "one request proved it for the whole book" "$(journal_delta remote-gone)" "1"
check "the next pass leaves a failed book alone" "$(metric remote-gone second_stop)" "idle"

# ------------------------------------------- a process that really dies -----
say "4/5 SIGKILL inside a pass"
mkdir -p "$WORK/kill"
"$SMOKE" --phase kill-resume --db "$WORK/kill/comic.sqlite" --base-url "$SLOW_URL" \
  --offline-url "$OFFLINE_URL" --gone-url "$GONE_URL" --key "$KEY" \
  --server-id "$SERVER_ID" --book "$BOOK" --max-pages 4 > "$WORK/kill.out" 2>&1 &
KILL_PID=$!
for _ in $(seq 1 400); do
  grep -q ready-to-kill "$WORK/kill.out" && break
  sleep 0.1
done
sleep 1.0
kill -9 "$KILL_PID" 2>/dev/null || true
wait "$KILL_PID" 2>/dev/null || true
check "the process was killed inside a pass, not between them" \
  "$(grep -c ready-to-kill "$WORK/kill.out")" "1"
check_ge "it had downloaded something before the kill" "$(metric kill killed_after_pages)" "1"
check "the killed process left no half-written file" "$(tree_parts kill)" "0"
run_phase kill-finish kill kill-finish "$DL_URL" dl --max-pages 8
check "真断点: the resume saw the pages the killed run had committed" \
  "$(metric kill-finish resumed_pages)" "$(metric kill-finish pages_before_resume)"
check "the resume fetched exactly the pages that were left" \
  "$(metric kill-finish resume_served)" "$(metric kill-finish expected_remaining)"
check "and the book finished" "$(metric kill-finish final_state)" "completed"
check "with every page on disk" "$(metric kill-finish files)" "$PAGES"
check "with no debris" "$(metric kill-finish parts_left)" "0"

# -------------------------------------------- the two trees, and the live --
say "5/5 the separation, and the live leg"
# downloads/<server>/<book> is three levels below the directory holding the database.
check "the download tree hangs off the database directory" \
  "$(dirname "$(dirname "$(dirname "$WORK/enqueue-pump/downloads/A/$STRESS_BOOK")")")" \
  "$WORK/enqueue-pump"
check "and the cache the reader uses is its sibling, not its parent" \
  "$(dirname "$WORK/enqueue-pump/cache")" "$(dirname "$WORK/enqueue-pump/downloads")"
check "no downloaded page lives under cache/" \
  "$(find "$WORK/enqueue-pump/cache" -name '0120.png' 2>/dev/null | grep -c . || true)" "0"
check "no cache file lives under downloads/" \
  "$(find "$WORK/enqueue-pump/downloads" -name "$SERVER_ID-$STRESS_BOOK-*" 2>/dev/null | grep -c . || true)" "0"
check "and no download ever entered the LRU ledger" \
  "$(sqlite3 "$WORK/enqueue-pump/comic.sqlite" "SELECT COUNT(*) FROM cache_entries WHERE kind='download'" 2>/dev/null || echo skip)" "0"
check "manifest.json carries the raw ids and a complete page list" \
  "$(python3 -c "
import json,sys
d=json.load(open('$WORK/enqueue-pump/downloads/$SERVER_ID/$STRESS_BOOK/manifest.json'))
print(d['pagesCount'], len(d['pages']), d['serverId'], d['bookId'], d['pages'][0]['fileName'], d['pages'][0]['sizeBytes'])
" 2>/dev/null || echo unreadable)" \
  "$PAGES $PAGES $SERVER_ID $STRESS_BOOK 0001.png 65048"

if [ "$RUST_ONLY" = 1 ]; then
  say "live leg skipped (--rust-only)"
elif [ -z "${KOMGA_BASE_URL:-}" ] || [ -z "${KOMGA_API_KEY:-}" ] || [ -z "${KOMGA_BOOK_ID:-}" ]; then
  say "live leg skipped: set KOMGA_BASE_URL, KOMGA_API_KEY and KOMGA_BOOK_ID to run it"
else
  say "live leg: a real book, downloaded and read with the network off"
  LIVE_URL="$KOMGA_BASE_URL"
  SERVER_ID="live"
  BOOK="$KOMGA_BOOK_ID"
  # Live phases authenticate with the real key, not the fixture server's:
  # `run_phase` passes --key "$KEY", so this must be swapped before the phases.
  KEY="$KOMGA_API_KEY"
  PAGES=$(curl -s -H "X-API-Key: $KOMGA_API_KEY" \
    "$LIVE_URL/api/v1/books/$BOOK/pages" | grep -o '"number"' | wc -l | tr -d ' ')
  check_ge "the live book has pages to download" "$PAGES" "20"
  run_phase live-download live-download enqueue-pump "$LIVE_URL" none --max-pages 4
  check "live: the book downloaded to completion" "$(metric live-download final_state)" "completed"
  check "live: one file per page" "$(metric live-download files)" "$PAGES"
  check "live: rows, disk and manifest agree" \
    "$(metric live-download bytes_db)" "$(metric live-download manifest_bytes)"
  run_phase live-offline live-download offline-run "$LIVE_URL" none --max-pages 4
  check "live: every page came out of the download tree" \
    "$(metric live-offline served_from_downloads)" "$PAGES"
  printf '   (live leg: %s pages read from %s)\n' "$PAGES" "$LIVE_URL"
fi

say "summary"
if [ "$FAILURES" = 0 ]; then
  echo "STAGE 9 ACCEPTANCE OK"
else
  echo "STAGE 9 ACCEPTANCE FAILED — $FAILURES check(s) above"
  exit 1
fi
