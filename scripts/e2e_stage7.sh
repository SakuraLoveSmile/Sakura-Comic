#!/usr/bin/env bash
# Stage 7 acceptance — 阅读器基础版.
#
#   1/3 Real HTTP over loopback (always). `komga_fixture_server` grew the
#       reader's two read endpoints, serving deterministic PNGs whose width
#       encodes the page number, and it journals every page read. That journal
#       is the evidence for the two claims a unit test cannot make:
#         a. 正常打开漫画 / 单页 / 双页 / 条漫 — the layouts come from a real
#            manifest fetched over a real socket;
#         b. 快速翻页 — 30 turns cost 30 local writes, ONE queued row and, once
#            flushed, ONE request (禁止每页一请求);
#         c. 重启后恢复位置 — a separate process restores the page AND the
#            layout, and the page journal does not move by a single line while
#            it does, so the reopen provably asked the server for nothing;
#         d. 断网后继续阅读已缓存页面 — the server is replaced by an unroutable
#            address and reading continues off disk;
#         e. 阅读状态最终同步 Komga — READ_PROGRESS, MARK_READ and MARK_UNREAD
#            each arrive as themselves (the fixture rejects anything else), and
#            the server's own state is read back to confirm it.
#   2/3 The shared reader contract (specs/contracts/fixtures/reader) drives the
#       Rust rules and the Swift rules from the same four JSON files.
#   3/3 Swift: same fixtures + the reader mirror's own unit tests.
#
# Env: KOMGA_BASE_URL + KOMGA_API_KEY additionally run the real-server leg
#      (--phase live-reader), which verifies a real book's reported page
#      dimensions against the pixels actually served and then restores that
#      book's progress exactly as it found it.
# Arg: --rust-only skips the Swift leg.
set -euo pipefail
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/android/komga_core"
WORK="$(mktemp -d)"
DB="$WORK/stage7.sqlite"
CACHE="$WORK/cache"
KEY="fixture-key"
SERVER_ID="A"
BOOK="book-3-3"
OFFLINE_URL="http://127.0.0.1:1"
PAGES="$WORK/pages.jsonl"
WRITES="$WORK/journal.jsonl"

cleanup() {
  kill "${SERVER_PID:-}" 2>/dev/null || true
  wait "${SERVER_PID:-}" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== 1/3 build =="
(cd "$CORE" && cargo build --quiet --bins)
SERVER="$CORE/target/debug/komga_fixture_server"
SMOKE="$CORE/target/debug/stage7_smoke"

# The Stage 5/6 snapshots already carry real BookDto shapes with
# media.pagesCount, so the reader runs against the same data the mirror was
# verified on. book-3-3 is a cbz (image-paged); book-1-1 is a pdf.
SCENARIO="$ROOT/specs/contracts/fixtures/sync/scenario-reconcile.json"
echo s1 > "$WORK/snapshot"
: > "$PAGES"
: > "$WRITES"

"$SERVER" --scenario "$SCENARIO" --snapshot-file "$WORK/snapshot" \
  --expect-key "$KEY" --journal "$WRITES" --page-journal "$PAGES" \
  --progress-file "$WORK/progress.json" > "$WORK/server.out" &
SERVER_PID=$!
for _ in $(seq 1 50); do
  grep -q '^LISTENING' "$WORK/server.out" 2>/dev/null && break
  sleep 0.1
done
PORT=$(awk '/^LISTENING/{print $2}' "$WORK/server.out")
BASE="http://127.0.0.1:$PORT"
test -n "$PORT" || { echo "fixture server never listened"; cat "$WORK/server.out"; exit 1; }
echo "   fixture server on $BASE"

# Both new endpoints must demand credentials before they answer anything.
for probe in "/api/v1/books/$BOOK/pages" "/api/v1/books/$BOOK/pages/1"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE$probe")
  test "$code" = "401" || { echo "unauthenticated $probe answered $code, expected 401"; exit 1; }
done
echo "   reader endpoints are authenticated (401 without a key)"

page_reads() { grep -c '"kind":"page"' "$PAGES" || true; }
manifest_reads() { grep -c '"kind":"manifest"' "$PAGES" || true; }
write_count() { grep -c . "$WRITES" || true; }

run() {
  local phase="$1"
  shift
  echo "-- phase $phase"
  "$SMOKE" --phase "$phase" --db "$DB" --cache "$CACHE" \
    --base-url "$BASE" --offline-url "$OFFLINE_URL" --key "$KEY" \
    --server-id "$SERVER_ID" --book "$BOOK" "$@"
}

echo
echo "== 2/3 reader phases over real HTTP =="
before_open=$(page_reads)
run open
after_open=$(page_reads)
test "$after_open" -gt "$before_open" || { echo "open made no page request"; exit 1; }
# The client must state the numbering it is asking in, every single time.
unmarked=$(grep '"kind":"page"' "$PAGES" | grep -vc '"zeroBasedSent":true' || true)
test "$unmarked" = "0" || { echo "$unmarked page reads did not send zero_based=false"; exit 1; }
echo "   page manifest mirrored; $after_open page reads, all explicitly 1-based"

run modes

before_flip=$(write_count)
run flip
after_flip=$(write_count)
flushed=$((after_flip - before_flip))
test "$flushed" = "1" || { echo "a 30-page burst produced $flushed requests, expected 1"; exit 1; }
echo "   the whole burst reached the server as exactly 1 write request"

before_reopen=$(page_reads)
run reopen
after_reopen=$(page_reads)
test "$after_reopen" = "$before_reopen" || {
  echo "reopen asked the server for $((after_reopen - before_reopen)) more pages, expected 0"; exit 1;
}
grep -q '"kind":"manifest"' "$PAGES" || { echo "no manifest read was ever journalled"; exit 1; }
before_manifests=$(manifest_reads)
run reopen
test "$(manifest_reads)" = "$before_manifests" || {
  echo "the second reopen re-fetched the page manifest"; exit 1;
}
echo "   reopen restored position with zero requests (page journal unchanged)"

run offline

before_prefetch=$(page_reads)
run prefetch
after_prefetch=$(page_reads)
test "$after_prefetch" -gt "$before_prefetch" || { echo "prefetch fetched nothing"; exit 1; }
echo "   prefetch pulled $((after_prefetch - before_prefetch)) pages ahead of the reader"

before_sync=$(write_count)
run sync
after_sync=$(write_count)
synced=$((after_sync - before_sync))
test "$synced" = "3" || { echo "sync produced $synced requests, expected 3"; exit 1; }
# Read the server's own journal as JSON, not as text: the request body is stored
# as a string inside the entry, so a text grep would be matching escapes.
python3 - "$WRITES" <<'PYTHON'
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
def body(row):
    return json.loads(row.get("body") or "{}")

deletes = [row for row in rows if row["method"] == "DELETE"]
marks = [row for row in rows if row["method"] == "PATCH" and body(row) == {"completed": True}]
paged = [row for row in rows if row["method"] == "PATCH" and "page" in body(row)]
assert deletes, "MARK_UNREAD never reached the server as a DELETE"
assert marks, "MARK_READ never reached the server as a page-less completed=true"
assert paged, "no read-progress page write ever reached the server"
for row in marks:
    assert "page" not in body(row), "an explicit mark must not rewrite the server's page"
print(f"   journal: {len(paged)} progress PATCH, {len(marks)} mark-read PATCH (no page), {len(deletes)} mark-unread DELETE")
PYTHON
echo "   READ_PROGRESS + MARK_READ + MARK_UNREAD each reached the server as themselves"

# The reader must not be able to ask for a page that does not exist and get
# something else back.
code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-API-Key: $KEY" "$BASE/api/v1/books/$BOOK/pages/99999")
test "$code" = "404" || { echo "an out-of-range page answered $code, expected 404"; exit 1; }
code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-API-Key: $KEY" "$BASE/api/v1/books/$BOOK/pages/0")
test "$code" = "404" || { echo "page 0 answered $code, expected 404"; exit 1; }
echo "   page 0 and page N+1 are 404, never a clamped image"

echo
echo "== shared reader contract (Rust) =="
(cd "$CORE" && cargo test --lib reader:: -- --test-threads=1 2>&1 | tail -3)

if [ "${1:-}" = "--rust-only" ]; then
  echo "skipped: Swift leg (--rust-only)"
else
  echo
  echo "== 3/3 Swift: the same fixtures, the same rules =="
  (cd "$ROOT/apple/KomgaKit" && swift build 2>&1 | tail -2 && swift test 2>&1 | tail -5)
fi

if [ -n "${KOMGA_BASE_URL:-}" ] && [ -n "${KOMGA_API_KEY:-}" ]; then
  echo
  echo "== real server: open, read, sync, restore =="
  LIVE_DB="$WORK/live.sqlite"
  # Point the book at whatever the server actually has: the first on-deck book
  # is a real image book in practice, and the phase refuses to run otherwise.
  LIVE_BOOK=$(curl -s -H "X-API-Key: $KOMGA_API_KEY" \
    "$KOMGA_BASE_URL/api/v1/books/ondeck?page=0&size=1" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); c=d.get("content") or []; print(c[0]["id"] if c else "")')
  if [ -z "$LIVE_BOOK" ]; then
    echo "skipped: no on-deck book on $KOMGA_BASE_URL to read"
  else
    "$SMOKE" --phase live-reader --db "$LIVE_DB" --cache "$WORK/live-cache" \
      --base-url "$KOMGA_BASE_URL" --offline-url "$OFFLINE_URL" \
      --key "$KOMGA_API_KEY" --server-id live --book "$LIVE_BOOK"
    echo "   live book $LIVE_BOOK read and restored"
  fi
else
  echo
  echo "real-server reader leg skipped: set KOMGA_BASE_URL + KOMGA_API_KEY"
fi

echo
echo "STAGE 7 ACCEPTANCE OK — reader, layouts, prefetch, restore, offline, sync"
