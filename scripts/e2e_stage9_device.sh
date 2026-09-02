#!/usr/bin/env bash
# Stage 9 — offline download acceptance on a device (emulator or phone).
#
# `scripts/e2e_stage9.sh` proves the queue against a closed port. A closed port is not
# a radio: it cannot show what Android does to a live socket when connectivity goes
# away, whether the process survives it, whether a downloaded book reads with the
# network physically off, and whether the progress write made during that window
# reaches the server afterwards. Those are what this script measures, with the server's
# own journal as the second witness.
#
#   scripts/e2e_stage9_device.sh [--device <serial>] [--avd-memory MB] [--skip-build]
#                                [--keep] [--no-radio]
#
# Without --device, the first installed AVD boots headless with `-gpu host`. That flag
# is not cosmetic: a software renderer costs ~900 ms per page turn, and Stage 8 mistook
# that for a cache defect once.
#
# The radio choreography is what makes the Wi-Fi rule testable rather than asserted.
# Measured on this AVD, and the reasons are worth keeping:
#
#   wifi off,  data on  -> metered    (the emulator's active network is CELLULAR, which
#                                      really is metered)
#   wifi on,   data off -> unmetered  (needs `cmd wifi connect-network AndroidWifi
#                                      open`; `svc wifi enable` alone leaves nothing
#                                      associated, which reads as unknown)
#   both off            -> unknown
#
# So book A may only download after the user's cellular consent, book B downloads
# without any consent because the link is unmetered, and book C is killed mid-pass and
# resumed by a second launch — three different claims, none taken on the core's word.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/android/komga_core"
APP="$ROOT/android/app"
WORK="${TMPDIR:-/tmp}/stage9d.$$"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
PKG="dev.sakurasep.comic"
KEY="fixture-key"
PAGES=60
DEVICE=""
AVD_MEMORY=""
SKIP_BUILD=0
KEEP=0
USE_RADIO=1
FAILURES=0
PIDS=()

cleanup() {
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  if [ "$USE_RADIO" = 1 ]; then
    $ADB shell svc wifi enable >/dev/null 2>&1 || true
    $ADB shell svc data enable >/dev/null 2>&1 || true
  fi
  if [ "$KEEP" = 0 ]; then rm -rf "$WORK"; else echo "== kept $WORK"; fi
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --avd-memory) AVD_MEMORY="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --keep) KEEP=1; shift ;;
    --no-radio) USE_RADIO=0; shift ;;
    --pages) PAGES="$2"; shift 2 ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$WORK"
[ -x "$ADB" ] || { echo "adb not found at $ADB" >&2; exit 1; }
# Flutter is not on PATH by default here, and a build step that cannot find it would
# leave the whole Android half unverified with a message that reads like a tooling
# hiccup. Same for JAVA_HOME: /usr/libexec/java_home only resolves the 1.8 Applet JRE,
# while the project targets 17.
command -v flutter >/dev/null || [ ! -d "$HOME/flutter/bin" ] || export PATH="$HOME/flutter/bin:$PATH"
if [ -z "${JAVA_HOME:-}" ] && [ -d /opt/homebrew/opt/openjdk@17 ]; then
  export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
  export PATH="$JAVA_HOME/bin:$PATH"
fi
command -v flutter >/dev/null || { echo "flutter not found; add it to PATH" >&2; exit 1; }

say() { printf '\n== %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf '   FAIL %s\n' "$*" >&2; }
ok() { printf '   ok   %s (%s)\n' "$1" "$2"; }
check() {
  if [ "$2" = "$3" ]; then ok "$1" "$2"; else fail "$1: got $2, want $3"; fi
}
check_ge() {
  if [ "$(awk -v a="$2" -v b="$3" 'BEGIN{print (a>=b)?1:0}')" = 1 ]; then
    ok "$1" "$2 >= $3"
  else fail "$1: $2 below the floor $3"; fi
}
# metric <label> <name> — one DL line from the captured logcat, as a number.
metric() {
  awk -v n="$2" '{for(i=1;i<=NF;i++) if ($i ~ "^"n"=") {split($i,a,"="); v=a[2]}} END{print v+0}' \
    "$WORK/$1.logcat"
}
# text_metric <label> <name> — the same, as written.
text_metric() {
  awk -v n="$2" '{for(i=1;i<=NF;i++) if ($i ~ "^"n"=") {split($i,a,"="); v=a[2]}} END{print v}' \
    "$WORK/$1.logcat"
}
reads_of() {
  if [ -f "$WORK/$1.pages" ]; then grep -c '"kind": *"page"' "$WORK/$1.pages" || true; else echo 0; fi
}
mutations_of() {
  if [ -f "$WORK/$1.journal" ]; then grep -c '"method": *"PATCH"' "$WORK/$1.journal" || true; else echo 0; fi
}
# A guest URL is not reachable from this shell; the same port on loopback is.
host_url() { echo "$1" | sed 's|10\.0\.2\.2|127.0.0.1|'; }

# ------------------------------------------------------------------ device --
say "1/9 device"
if [ -z "$DEVICE" ]; then
  AVD=$("$SDK/emulator/emulator" -list-avds 2>/dev/null | head -1)
  [ -n "$AVD" ] || { echo "no AVD found; pass --device <serial>" >&2; exit 1; }
  printf '   booting %s headless (-gpu host)\n' "$AVD"
  # bash 3.2 under `set -u` reads an empty array expansion as unbound, so the optional
  # -memory flag has to be spliced in rather than always present.
  EMU_ARGS=("$SDK/emulator/emulator" -avd "$AVD" -no-window -no-audio -no-boot-anim -gpu host)
  [ -n "$AVD_MEMORY" ] && EMU_ARGS+=(-memory "$AVD_MEMORY")
  "${EMU_ARGS[@]}" >"$WORK/emulator.log" 2>&1 &
  PIDS+=("$!")
  for _ in $(seq 1 120); do
    [ "$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
    sleep 1
  done
  DEVICE=$($ADB devices | awk 'NR==2{print $1}')
fi
[ -n "$DEVICE" ] || { echo "no device available" >&2; exit 1; }
export ANDROID_SERIAL="$DEVICE"
check "the device is online" "$($ADB get-state 2>/dev/null | tr -d '\r')" "device"
$ADB shell getprop ro.build.version.release | tr -d '\r' | xargs printf '   Android %s\n'
# A dozing display pushes the app through paused() and stalls the rasterizer, after
# which every number describes an idle app rather than the run being measured.
$ADB shell svc power stayon true >/dev/null 2>&1 || true
$ADB shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
$ADB shell wm dismiss-keyguard >/dev/null 2>&1 || true

# ------------------------------------------------------------------- build --
say "2/9 build and install"
if [ "$SKIP_BUILD" = 0 ]; then
  (cd "$CORE" && cargo build --quiet --bin komga_fixture_server)
  printf '   refreshing the native libraries (cargo ndk, release + frb)\n'
  (cd "$CORE" && cargo ndk -t arm64-v8a -o "$APP/android/app/src/main/jniLibs" \
    build --release --features frb >"$WORK/ndk.log" 2>&1) || {
      tail -20 "$WORK/ndk.log"; fail "the native library did not build"; exit 1; }
  printf '   building the profile APK\n'
  (cd "$APP" && flutter build apk --profile >"$WORK/apk.log" 2>&1) || {
    tail -20 "$WORK/apk.log"; fail "the APK did not build"; exit 1; }
  $ADB install -r -g "$APP/build/app/outputs/flutter-apk/app-profile.apk" \
    >"$WORK/install.log" 2>&1 || { tail -5 "$WORK/install.log"; fail "install failed"; exit 1; }
fi
check "the app is installed" "$($ADB shell pm list packages | grep -c "$PKG" || true)" "1"

# ------------------------------------------------------------------ servers --
say "3/9 fixture servers (the guest reaches the host at 10.0.2.2)"
start_fixture() { # start_fixture <name> <book> [extra...]
  local name="$1" book="$2"
  shift 2
  "$CORE/target/debug/komga_fixture_server" \
    --scenario "$ROOT/specs/contracts/fixtures/sync/scenario-reconcile.json" \
    --snapshot-file "$WORK/$name.snapshot" --expect-key "$KEY" \
    --journal "$WORK/$name.journal" --page-journal "$WORK/$name.pages" \
    --stress "$book,$PAGES,120,180,0" "$@" >"$WORK/$name.log" 2>&1 &
  PIDS+=("$!")
  for _ in $(seq 1 100); do grep -q '^LISTENING ' "$WORK/$name.log" && break; sleep 0.05; done
  echo s1 > "$WORK/$name.snapshot"
  local port
  port=$(grep '^LISTENING ' "$WORK/$name.log" | awk '{print $2}')
  printf '   %s: %s -> %s\n' "$name" "$book" "http://10.0.2.2:$port"
  case "$name" in
    cell) CELL_URL="http://10.0.2.2:$port" ;;
    wifi) WIFI_URL="http://10.0.2.2:$port" ;;
    slow) SLOW_URL="http://10.0.2.2:$port" ;;
  esac
}
start_fixture cell bookA
start_fixture wifi bookB
start_fixture slow bookC --delay-ms 250
check "the metered-link server answers 401 without a key" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$(host_url "$CELL_URL")/api/v1/actuator/info")" "401"
check "and declares all $PAGES pages" \
  "$(curl -s -H "X-API-Key: $KEY" "$(host_url "$CELL_URL")/api/v1/books/bookA/pages" | grep -o '"number"' | wc -l | tr -d ' ')" "$PAGES"

radio() { # radio <metered|unmetered|off>
  case "$1" in
    metered)
      $ADB shell svc wifi disable >/dev/null 2>&1
      $ADB shell svc data enable >/dev/null 2>&1
      sleep 3 ;;
    unmetered)
      $ADB shell svc data disable >/dev/null 2>&1
      $ADB shell svc wifi enable >/dev/null 2>&1
      sleep 2
      # `svc wifi enable` alone leaves the emulator with nothing associated, which reads
      # as `unknown` rather than `unmetered`: the AVD's own AP has to be joined.
      $ADB shell cmd wifi connect-network AndroidWifi open >/dev/null 2>&1 || true
      sleep 5 ;;
    off)
      $ADB shell svc wifi disable >/dev/null 2>&1
      $ADB shell svc data disable >/dev/null 2>&1
      sleep 3 ;;
  esac
}
start_route() { # start_route <label> <route>
  local label="$1" route="$2"
  $ADB shell am force-stop "$PKG" >/dev/null 2>&1 || true
  sleep 1
  $ADB logcat -c >/dev/null 2>&1 || true
  : > "$WORK/$label.logcat"
  $ADB logcat -v time > "$WORK/$label.logcat" 2>&1 &
  LOGCAT_PID=$!
  PIDS+=("$LOGCAT_PID")
  # Quoted for the device shell: an unquoted `&` backgrounds the rest of the command
  # there, and the activity receives a truncated route.
  $ADB shell "am start -S -n $PKG/.MainActivity --es route '$route'" >/dev/null
}
wait_for() { # wait_for <label> <pattern> <seconds>
  local label="$1" pattern="$2" limit="$3"
  for _ in $(seq 1 "$((limit * 2))"); do
    grep -q "$pattern" "$WORK/$label.logcat" 2>/dev/null && return 0
    sleep 0.5
  done
  return 1
}
stop_logging() {
  local keep=()
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do
    if ps -p "$pid" -o args= 2>/dev/null | grep -q logcat; then
      kill "$pid" 2>/dev/null || true
    else
      keep+=("$pid")
    fi
  done
  PIDS=(${keep[@]+"${keep[@]}"})
  sleep 1
}

# -------------------------------------------------- 4. a metered link says no --
say "4/9 蜂窝：没有用户同意，一个字节都不许花"
radio metered
$ADB shell pm clear "$PKG" >/dev/null 2>&1 || true
sleep 1
start_route refused "/download-stress?mode=download&base=$CELL_URL&key=$KEY&book=bookA&max=4"
if ! wait_for refused "DL done mode=download" 120; then
  tail -20 "$WORK/refused.logcat"; fail "the metered refusal run never finished"
fi
stop_logging
check "the platform really reported a metered link" \
  "$(text_metric refused linkAtStart)" "metered"
check "the queue stopped on the link rule" "$(text_metric refused lastStop)" "linkBlocked"
check "and spent no bytes" "$(metric refused served)" "0"
check "nothing landed on the device" "$(metric refused treeFiles)" "0"
# The claim, from the server's side rather than the client's: a metered link produced
# zero page requests.
check "the server was asked for nothing at all" "$(reads_of cell)" "0"
check "and the book is still waiting for its owner" \
  "$(text_metric refused state)" "waiting"

say "5/9 用户同意后，同一本下载完了"
start_route consent "/download-stress?mode=download&base=$CELL_URL&key=$KEY&book=bookA&max=4&cellular=1"
if ! wait_for consent "DL done mode=download" 180; then
  tail -20 "$WORK/consent.logcat"; fail "the consented download never finished"
fi
stop_logging
check "consent was granted on the device" "$(metric consent consentGranted)" "1"
check "the book reached completed" "$(text_metric consent state)" "completed"
check "every page recorded" "$(metric consent pagesDone)" "$PAGES"
check "one file per page" "$(metric consent treeFiles)" "$PAGES"
check "and no staging debris" "$(metric consent treeParts)" "0"
check "rows and directory agree on the bytes" \
  "$(metric consent bytesDb)" "$(metric consent diskBytes)"
check "the server saw exactly one request per page" "$(reads_of cell)" "$PAGES"
check "the pass bound held on a device too" "$(metric consent passes)" \
  "$(( (PAGES + 3) / 4 ))"
check "the platform answered about its free space" \
  "$(awk -v a="$(metric consent freeBytes)" 'BEGIN{print (a>0)?1:0}')" "1"
printf '   throughput on the metered link: %s pages in %ss (%s pages/s)\n' \
  "$PAGES" "$(text_metric consent seconds)" "$(text_metric consent pagesPerSecond)"

# ------------------------------------------------ 6. Wi-Fi advances by itself --
say "6/9 仅 Wi-Fi 自动推进：第二本书没有同意也必须能下"
radio unmetered
start_route wifi-auto "/download-stress?mode=download&base=$WIFI_URL&key=$KEY&book=bookB&max=4"
if ! wait_for wifi-auto "DL done mode=download" 180; then
  tail -20 "$WORK/wifi-auto.logcat"; fail "the Wi-Fi download never finished"
fi
stop_logging
check "the link really read as unmetered" "$(text_metric wifi-auto linkAtStart)" "unmetered"
check "no cellular consent was ever granted for this book" \
  "$(text_metric wifi-auto consentGranted)" ""
check "and the queue advanced on its own to completed" \
  "$(text_metric wifi-auto state)" "completed"
check "with every page on the device" "$(metric wifi-auto treeFiles)" "$PAGES"
check "the Wi-Fi server saw one request per page" "$(reads_of wifi)" "$PAGES"

# ------------------------------------ 7. a download the platform interrupts --
say "7/9 中断与续传"
before_slow=$(reads_of slow)
start_route killed "/download-stress?mode=download&base=$SLOW_URL&key=$KEY&book=bookC&max=4"
wait_for killed "DL startState" 60 >/dev/null || {
  tail -20 "$WORK/killed.logcat"; fail "the killed run never started"; }
sleep 4
$ADB shell am force-stop "$PKG" >/dev/null 2>&1 || true
stop_logging
start_route resumed "/download-stress?mode=resume&base=$SLOW_URL&key=$KEY&book=bookC&max=4"
if ! wait_for resumed "DL done mode=resume" 180; then
  tail -25 "$WORK/resumed.logcat"; fail "the resumed download never finished"
fi
stop_logging
# The killed run was force-stopped, so it never printed its own total: the resume's
# startPages IS the evidence of what survived, and it has to be a partial state —
# zero would mean the kill landed before any commit, and PAGES would mean there was
# nothing left to resume.
resumed_from=$(metric resumed startPages)
check_ge "the killed run had committed pages before it died" "$resumed_from" "1"
check_le "without finishing the book" "$resumed_from" "$((PAGES - 1))"
check "it fetched exactly what was left" "$(metric resumed served)" \
  "$((PAGES - resumed_from))"
check "and the book completed" "$(text_metric resumed state)" "completed"
check "with every page on the device" "$(metric resumed treeFiles)" "$PAGES"
check "and no staging debris after the kill" "$(metric resumed treeParts)" "0"
# `resume` never enqueues, which is what a relaunch does. A harness that always
# enqueued could not tell a resume from a restart.
check "the resume did not restart from zero" "$(awk -v a="$(metric resumed startPages)" 'BEGIN{print (a>0)?1:0}')" "1"
check_le "and it did not re-download the whole book either" \
  "$(metric resumed served)" "$PAGES"

say "8/9 断网读完整一本，并存进度"
radio off
pinged=$($ADB shell ping -c 1 -W 2 10.0.2.2 2>&1 | grep -c "Network is unreachable" || true)
if [ "$USE_RADIO" = 1 ]; then
  check "the guest really has no route out" "$pinged" "1"
fi
before_offline_reads=$(reads_of slow)
start_route offline "/download-stress?mode=offline&base=$SLOW_URL&dead=http://10.0.2.2:1&key=$KEY&book=bookC&pages=$PAGES"
if ! wait_for offline "DL done mode=offline" 180; then
  tail -25 "$WORK/offline.logcat"; fail "the offline read never finished"
fi
stop_logging
alive=$($ADB shell pidof "$PKG" | tr -d '\r' | grep -c . || true)
check "the process survived the radio going away" "$alive" "1"
check "opening the book was a local operation" "$(metric offline openedFromMirror)" "1"
check "the download tree is on the device" "$(metric offline treeExists)" "1"
check "every page was read" "$(metric offline pagesServed)" "$PAGES"
check "and every one of them came out of the download tree" \
  "$(metric offline servedFromDownloads)" "$PAGES"
check "nothing failed to resolve" "$(metric offline pagesFailed)" "0"
# The strongest line in this file: the host's journal did not move by one read while
# the app read a whole book. Not the client's word about its cache — the server's record
# of what it was asked for.
check "the server was asked for nothing during the offline read" \
  "$(( $(reads_of slow) - before_offline_reads ))" "0"
check "progress was saved with the network off" "$(metric offline positionPage)" "3"
check "and the write was queued rather than dropped" "$(metric offline pendingAfter)" "1"
check "the saved page still resolves locally" "$(metric offline positionStillReads)" "1"

say "9/9 网络回来，欠的写自己上传"
radio unmetered
before_mutations=$(mutations_of slow)
start_route upload "/download-stress?mode=upload&base=$SLOW_URL&key=$KEY&book=bookC"
if ! wait_for upload "DL done mode=upload" 120; then
  tail -25 "$WORK/upload.logcat"; fail "the upload run never finished"
fi
stop_logging
check "the offline write was still pending when the link came back" \
  "$(metric upload pendingBefore)" "1"
check "the drainer sent it" "$(metric upload uploaded)" "1"
check "and the queue is empty afterwards" "$(metric upload pendingAfter)" "0"
check "nothing landed in the failed bucket" "$(metric upload failedAfter)" "0"
check "the server received the write the device owed it" \
  "$(( $(mutations_of slow) - before_mutations ))" "1"
if grep -qF 'page\":3' "$WORK/slow.journal" 2>/dev/null; then
  ok "the journal carries page 3, the page the offline read turned to" "1"
else
  fail "the server journal has no PATCH carrying page 3 — the upload is unproven"
fi

say "summary"
if [ "$FAILURES" = 0 ]; then
  echo "STAGE 9 DEVICE ACCEPTANCE OK"
else
  echo "STAGE 9 DEVICE ACCEPTANCE FAILED — $FAILURES check(s) above"
  exit 1
fi
