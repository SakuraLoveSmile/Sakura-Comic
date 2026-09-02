#!/usr/bin/env bash
# Stage 8 — device acceptance: the lines the loopback harness cannot reach.
#
#   "不明显掉帧"      → per-turn wall time measured through a painted frame, on a
#                     hardware-GPU Android build.
#   "内存不持续增长"  → `dumpsys meminfo` PSS sampled across a whole driven read.
#   "App 内存压力"    → `am send-trim-memory`, i.e. the platform's own signal, and
#                     what the process holds afterwards.
#   "断网 / 切换"     → `svc wifi disable && svc data disable`: a real radio loss,
#                     through the same network stack the app's sockets use.
#
# All of it runs against the real reading path — same ReaderScreen,
# ReaderController, FrbReaderApi and ReaderDevice a user gets — driven through the
# `/reader-stress` route so no tap coordinates are involved. Each pass starts from
# `pm clear`, so no pass can inherit another's cache or journals.
#
#   scripts/e2e_stage8_device.sh [--pages N] [--delay MS] [--device SERIAL]
#   scripts/e2e_stage8_device.sh --network-switch     # add the radio-loss pass
#   scripts/e2e_stage8_device.sh --lifecycle          # real background /
#                                                     # foreground cycles
#   scripts/e2e_stage8_device.sh --soak               # 400 turns with trim-memory
#                                                     # injected repeatedly:
#                                                     # 长时间使用 without a phone
#   scripts/e2e_stage8_device.sh --device-ram BYTES   # a smaller device class: the
#                                                     # plan must shrink to match
#   scripts/e2e_stage8_device.sh --avd-memory 1536    # boot a headless AVD if
#                                                     # nothing is attached
#   scripts/e2e_stage8_device.sh --device <serial> \
#       --base-url http://192.168.0.69:25600 --key "$KOMGA_API_KEY" --book <id>
#
# Two instrument facts this script encodes, both learned the hard way:
#   * `-gpu swift_shader_indirect` costs ~900 ms per page turn that `-gpu host`
#     does not (56 ms p50 for the same build). Never quote a timing taken on the
#     software rasterizer.
#   * The screen has to be held awake. When it dozes, Android pushes the app
#     through `paused()`, which drops live images and stalls the rasterizer, and
#     every number below then describes an idle app rather than a read.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/android/komga_core"
APP="$ROOT/android/app"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
PKG=dev.sakurasep.comic
KEY=fixture-key
PAGES=120
DELAY=100
SERIAL=""
BASE_URL=""
BOOK=""
AVD_MEMORY=""
DEVICE_RAM=""
NETWORK_SWITCH=""
SOAK=""
LIFECYCLE=""
SKIP_BUILD=""
GPU_MODE="${GPU_MODE:-host}"
WORK="${TMPDIR:-/tmp}/stage8-device.$$"
FAILURES=0
SERVER_PIDS=()
RADIO_WAS_CUT=0

cleanup() {
  if [ "$RADIO_WAS_CUT" = 1 ]; then
    $ADB shell svc wifi enable >/dev/null 2>&1 || true
    $ADB shell svc data enable >/dev/null 2>&1 || true
  fi
  for pid in ${SERVER_PIDS[@]+"${SERVER_PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  [ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"
}
trap cleanup EXIT

say() { printf '\n== %s\n' "$*"; }
ok() { printf '   ok   %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf '   FAIL %s\n' "$*" >&2; }
check() { # check <description> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1 ($2)"; else fail "$1: got '$2', want '$3'"; fi
}
metric() { # metric <metrics-file> <key>
  awk -F= -v want="$2" '$1==want{v=$2} END{print v}' "$1" 2>/dev/null
}

while [ $# -gt 0 ]; do
  case "$1" in
    --pages) PAGES="$2"; shift ;;
    --delay) DELAY="$2"; shift ;;
    --device) SERIAL="$2"; shift ;;
    --base-url) BASE_URL="$2"; shift ;;
    --book) BOOK="$2"; shift ;;
    --key) KEY="$2"; shift ;;
    --avd-memory) AVD_MEMORY="$2"; shift ;;
    --device-ram) DEVICE_RAM="$2"; shift ;;
    --network-switch) NETWORK_SWITCH=1 ;;
    --soak) SOAK=1; PAGES=${SOAK_PAGES:-300}; DELAY=${SOAK_DELAY:-200} ;;
    --lifecycle) LIFECYCLE=1 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --keep) KEEP_WORK=1 ;;
    *) echo "unknown flag $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$WORK"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="$SDK" ANDROID_SDK_ROOT="$SDK"
export PATH="$HOME/flutter/bin:$JAVA_HOME/bin:$HOME/.cargo/bin:$PATH"
[ -x "$ADB" ] || { echo "no adb at $ADB" >&2; exit 2; }
if [ -n "$SERIAL" ]; then ADB="$ADB -s $SERIAL"; fi
$ADB start-server >/dev/null 2>&1 || true

device_present() { $ADB devices 2>/dev/null | awk 'NR>1 && $2=="device"' | grep -q .; }

if ! device_present; then
  if [ -z "$AVD_MEMORY" ]; then
    echo "no Android device in state 'device': attach a phone, or pass --avd-memory <MB>." >&2
    exit 2
  fi
  AVD=$("$SDK/emulator/emulator" -list-avds | head -1)
  [ -n "$AVD" ] || { echo "no AVD defined" >&2; exit 2; }
  say "booting $AVD (${AVD_MEMORY} MB, -gpu $GPU_MODE)"
  (nohup "$SDK/emulator/emulator" -avd "$AVD" -no-window -no-audio -no-boot-anim \
      -gpu "$GPU_MODE" -memory "$AVD_MEMORY" -cores 4 > "$WORK/emulator.log" 2>&1 &)
  for _ in $(seq 1 150); do
    if [ "$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then break; fi
    sleep 2
  done
  device_present || { fail "the emulator never booted"; tail -20 "$WORK/emulator.log"; exit 1; }
fi

say "device: Android $($ADB shell getprop ro.build.version.release | tr -d '\r') (API $($ADB shell getprop ro.build.version.sdk | tr -d '\r')), gpu=$GPU_MODE"
$ADB shell svc power stayon true >/dev/null 2>&1 || true
$ADB shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
$ADB shell wm dismiss-keyguard >/dev/null 2>&1 || true

if [ -n "$SKIP_BUILD" ]; then
  say "1/3 build skipped (--skip-build)"
else
say "1/3 native library + APK"
(cd "$CORE" && cargo ndk -t arm64-v8a -o "$APP/android/app/src/main/jniLibs" build --release --features frb 2>&1 | tail -2)
(cd "$APP" && flutter build apk --profile 2>&1 | tail -2)
$ADB install -r "$APP/build/app/outputs/flutter-apk/app-profile.apk" | tail -1
fi

start_fixture() { # start_fixture <name> <stress-spec> -> guest URL
  local name="$1" spec="$2"
  local log="$WORK/$name.log"
  ( "$CORE/target/debug/komga_fixture_server" \
      --scenario "$ROOT/specs/contracts/fixtures/sync/scenario-reconcile.json" \
      --snapshot-file "$WORK/$name.snap" --expect-key "$KEY" \
      --page-journal "$WORK/$name.pages" --stress "$spec" >"$log" 2>&1 & )
  echo s1 > "$WORK/$name.snap"
  for _ in $(seq 1 100); do grep -q '^LISTENING ' "$log" && break; sleep 0.05; done
  echo "http://10.0.2.2:$(awk '/^LISTENING/{print $2}' "$log")"   # host as the guest sees it
}

journal_reads() { # journal_reads <server-name> — page entries only
  local file="$WORK/${1}.pages" count=0
  if [ -f "$file" ]; then count=$(grep -c '"kind": *"page"' "$file" || true); fi
  echo "${count:-0}"
}

pss_now() {
  $ADB shell dumpsys meminfo "$PKG" 2>/dev/null | awk '
    /^ *TOTAL PSS:/ { print $3; found=1; exit }
    /^TOTAL /       { print $2; found=1; exit }
    END { if (!found) print 0 }' | tr -d '\r'
}

ram_param() { if [ -n "$DEVICE_RAM" ]; then echo "&ram=$DEVICE_RAM"; fi; }

launch() { # launch <label> <route>
  local label="$1" route="$2"
  $ADB shell am force-stop "$PKG"
  $ADB shell pm clear "$PKG" >/dev/null
  $ADB logcat -c
  : > "$WORK/$label.logcat"
  ( $ADB logcat -v time > "$WORK/$label.logcat" 2>&1 & )
  # Quoted for the *device* shell: the route carries `&` between parameters and
  # mksh would background everything after the first one.
  $ADB shell "am start -n $PKG/.MainActivity --es route '$route'" >/dev/null
}

stop_logging() { pkill -f "logcat -v time" || true; sleep 1; }

# collect <label> — freeze this pass's own numbers, so the verdict never grades one
# pass on another pass's traffic.
collect() {
  local label="$1"
  local log="$WORK/$label.logcat" out="$WORK/$label.metrics"
  local done_line pressure_line window_line
  done_line=$(grep 'STRESS done' "$log" | tail -1)
  pressure_line=$(grep 'STRESS pressure' "$log" | tail -1)
  window_line=$(grep 'STRESS window' "$log" | tail -1)
  : > "$out"
  local kv
  for kv in $window_line $done_line $pressure_line; do
    case "$kv" in *=*) printf '%s\n' "$kv" >> "$out" ;; esac
  done
}

# run_pass <label> <journal> <book> <pages> <delay> <mode> <url> [extra-route]
run_pass() {
  local label="$1" jname="$2" book="$3" pages="$4" delay="$5" mode="$6" url="$7"
  local extra="${8:-}"
  local log="$WORK/$label.logcat" pss="$WORK/$label.pss"
  say "$label: $pages turns at ${delay}ms ($mode)"
  local jb; jb=$(journal_reads "$jname")
  : > "$WORK/$label.pss"
  launch "$label" "/reader-stress?base=$url&key=$KEY&book=$book&pages=$pages&delay=$delay&mode=$mode&warmup=6000$(ram_param)$extra"
  sleep 12   # the open (manifest + first page) is not part of the read
  # Soaking: pressure is injected throughout the read, not once at the end, because
  # the acceptance line is about a long session under repeated memory pressure —
  # whether the reader survives it, and whether its footprint trends flat while it
  # does. One trim at the end only ever proves the handler runs.
  if [ -n "$SOAK" ]; then
    # Escalating levels, not the same one repeatedly: the Flutter embedding tracks
    # the last level it forwarded and ignores anything not more severe, so five
    # identical `COMPLETE` calls produce one callback. Ascending severity is what
    # the platform actually offers, and it is what a real memory squeeze looks like.
    ( for level in RUNNING_MODERATE RUNNING_LOW RUNNING_CRITICAL COMPLETE BACKGROUND; do
        pgrep -f "logcat -v time" >/dev/null 2>&1 || break
        sleep "${SOAK_TRIM_SECONDS:-8}"
        $ADB shell am send-trim-memory "$PKG" "$level" >/dev/null 2>&1 || true
      done ) &
    printf '   soaking: %s turns at %sms, escalating trim-memory every %ss\n' \
      "$pages" "$delay" "${SOAK_TRIM_SECONDS:-8}"
  fi
  local deadline=$((SECONDS + pages * (delay + 1500) / 1000 + 300))
  while [ $SECONDS -lt $deadline ]; do
    echo "$(pss_now)" >> "$WORK/$label.pss"
    # `if`, not `&&`: a failing grep as the last command of a loop body trips
    # `set -e`, which is how a passing run aborts the script mid-read.
    if grep -qE "STRESS (done|open-failed)" "$WORK/$label.logcat"; then break; fi
    sleep 2
  done
  grep -q "STRESS done" "$WORK/$label.logcat" || {
    tail -20 "$WORK/$label.logcat"; fail "$label: the driven read never finished"; }

  local pb pa held
  pb=$(pss_now)
  $ADB shell am send-trim-memory "$PKG" COMPLETE >/dev/null 2>&1 \
    || $ADB shell am send-trim-memory "$PKG" RUNNING_LOW >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    if grep -q "STRESS pressure" "$WORK/$label.logcat"; then break; fi
    sleep 1
  done
  pa=$(pss_now)
  stop_logging
  held=$(awk '/STRESS done/{for(i=1;i<=NF;i++) if ($i ~ /^cacheBytes=/) {split($i,a,"="); v=a[2]}} END{print v+0}' "$WORK/$label.logcat")
  collect "$label"
  {
    printf 'journal_before=%s\njournal_after=%s\n' "$jb" "$(journal_reads "$jname")"
    printf 'pss_before_pressure=%s\npss_after_pressure=%s\n' "$pb" "$pa"
    printf 'images_held_at_end=%s\n' "$held"
    printf 'pressure_events=%s\n' "$(grep -c 'STRESS pressure' "$WORK/$label.logcat" || true)"
    printf 'pss_samples=%s\n' "$(wc -l < "$WORK/$label.pss" | tr -d ' ')"
    printf 'pss_first=%s\npss_peak=%s\npss_late=%s\n' \
      "$(head -1 "$WORK/$label.pss")" \
      "$(sort -n "$WORK/$label.pss" | tail -1)" \
      "$(tail -n +$(( $(wc -l < "$WORK/$label.pss") * 3 / 4 + 1 )) "$WORK/$label.pss" | sort -n | tail -1)"
  } >> "$WORK/$label.metrics"
  local M="$WORK/$label.metrics"
  printf '   %s: cold p50 %sms / p95 %sms, warm p50 %sms / p95 %sms\n' "$label" \
    "$(metric "$M" coldP50ms)" "$(metric "$M" coldP95ms)" \
    "$(metric "$M" warmP50ms)" "$(metric "$M" warmP95ms)"
  printf '   %s: PSS %s -> %s KB during the read (peak %s KB, %s samples, %s pressure events); %s -> %s KB at the last trim\n' "$label" \
    "$(metric "$M" pss_first)" "$(metric "$M" pss_late)" \
    "$(metric "$M" pss_peak)" "$(metric "$M" pss_samples)" "$(metric "$M" pressure_events)" \
    "$(metric "$M" pss_before_pressure)" "$(metric "$M" pss_after_pressure)"
  printf '   %s: %s page reads served, %s of them distinct\n' "$label" \
    "$(( $(metric "$M" journal_after) - $(metric "$M" journal_before) ))" \
    "$(distinct_in "$(metric "$M" journal_before)" "$(metric "$M" journal_after)" "$jname")"
}

distinct_in() { # distinct_in <from> <to> <server>
  awk -F'"' -v lo="$1" -v hi="$2" '
    /"kind": *"page"/{n++; for(i=1;i<=NF;i++) if ($i=="asked" && n>lo && n<=hi) {gsub(/[^0-9]/,"",$(i+1)); print $(i+1)}}' \
    "$WORK/$3.pages" 2>/dev/null | sort -u | grep -c . || true
}

say "2/3 server"
if [ -n "$BASE_URL" ]; then
  [ -n "$BOOK" ] || { echo "--book is required with --base-url" >&2; exit 2; }
  SMALL_URL="$BASE_URL"; FOURK_URL=""
  printf '   external server (no fixture journal): %s\n' "$SMALL_URL"
else
  (cd "$CORE" && cargo build --quiet --bin komga_fixture_server)
  SMALL_URL=$(start_fixture small "stress-520,520,120,180,0")
  FOURK_URL=$(start_fixture fourk "stress-4k,40,3840,2160,0")
  BOOK=stress-520
  printf '   small  %s\n   4K     %s\n' "$SMALL_URL" "$FOURK_URL"
fi

run_pass small small "$BOOK" "$PAGES" "$DELAY" single "$SMALL_URL"
if [ -n "$FOURK_URL" ]; then run_pass fourk fourk stress-4k 8 1500 single "$FOURK_URL"; fi

if [ -n "$NETWORK_SWITCH" ] && [ -z "$BASE_URL" ]; then
  say "network-switch: read forward, cut the radio, keep reading into uncached pages"
  # Observation only from here: a reader that hits an uncached page with the radio
  # off is *supposed* to report a failure, which makes `STRESS error` a normal end
  # to this pass rather than an abort. The assertions below decide what counts.
  set +e
  # `back=0` sends the driver forward only. Out-and-back would stay inside the
  # pages the prefetch already warmed, and a reader that never needs the network
  # cannot notice that it is gone.
  # A slow-enough cadence that the cut can actually land mid-read: on a host-GPU
  # emulator 60 forward turns finish in a couple of seconds, and an outage noticed
  # after the reading stopped proves nothing.
  NET_DELAY=${NET_DELAY:-450}
  NET_PAGES=${NET_PAGES:-60}
  # Cut after a handful of turns, not a third of the book: each turn warms up to
  # `in_flight` pages ahead, so on a short book a late cut means the outage is
  # discovered by nobody — every remaining page is already local, which is the
  # right behaviour for the reader and the wrong setup for this test.
  CUT=${NET_CUT:-3}
  launch netswitch "/reader-stress?base=$SMALL_URL&key=$KEY&book=$BOOK&pages=$NET_PAGES&delay=$NET_DELAY&mode=single&warmup=4000&back=0$(ram_param)"
  for _ in $(seq 1 240); do
    if grep -q "STRESS turn at=$CUT " "$WORK/netswitch.logcat"; then break; fi
    if grep -qE "STRESS (done|error|open-failed)" "$WORK/netswitch.logcat"; then break; fi
    sleep 0.5
  done
  NB=$(journal_reads small)
  $ADB shell svc wifi disable >/dev/null 2>&1 || true
  $ADB shell svc data disable >/dev/null 2>&1 || true
  RADIO_WAS_CUT=1
  printf '   radio cut at turn %s of %s, %s page reads served\n' "$CUT" "$NET_PAGES" "$NB"
  deadline=$((SECONDS + NET_PAGES * (NET_DELAY + 1500) / 1000 + 240))
  while [ $SECONDS -lt $deadline ]; do
    if grep -qE "STRESS (done|error|open-failed)" "$WORK/netswitch.logcat"; then break; fi
    sleep 1
  done
  NA=$(journal_reads small)
  $ADB shell svc wifi enable >/dev/null 2>&1 || true
  $ADB shell svc data enable >/dev/null 2>&1 || true
  RADIO_WAS_CUT=0
  sleep 2
  stop_logging
  collect netswitch
  printf '%s\njournal_before=%s\njournal_after=%s\n' \
    "$(grep -E 'STRESS (done|error)' "$WORK/netswitch.logcat" | tail -1 | sed 's/.*flutter *: //')" \
    "$NB" "$NA" >> "$WORK/netswitch.metrics"
  printf '   %s\n' "$(grep -E 'STRESS (done|error)' "$WORK/netswitch.logcat" | tail -1 | sed 's/.*flutter *: //')"
  printf '   link states reported: %s; requests after the cut: %s\n' \
    "$(grep -o 'STRESS link network=[a-z]*' "$WORK/netswitch.logcat" | sed 's/.*=//' | sort -u | tr '\n' ' ')" \
    "$((NA - NB))"
  if grep -q "STRESS link network=offline" "$WORK/netswitch.logcat"; then
    ok "a real radio loss reached the prefetch planner on the device"
  else
    fail "the reader never reported the outage it was reading through"
  fi
  if [ "$((NA - NB))" -le 6 ]; then
    ok "it stopped dialing once the link was known to be down ($((NA - NB)) late requests)"
  else
    fail "$((NA - NB)) requests went out after the radio was cut"
  fi
  if [ -n "$($ADB shell pidof "$PKG" | tr -d '\r')" ]; then
    ok "the process survived reading into an outage"
  else
    fail "the process died when the radio went off"
  fi
  set -e
fi

# --------------------------------------------------------------------------------
# Background / foreground, for real. "App 后台恢复" is the one stress line that could
# previously only be checked by reading the source for `controller.resumed()`. This
# sends the actual HOME key and brings the activity back, N times, and asserts what
# the reader did: it noticed each cycle, kept the page it was on, did not re-download
# anything it already had, and did not grow across the cycling.
# --------------------------------------------------------------------------------
if [ -n "$LIFECYCLE" ]; then
  say "lifecycle: background and foreground the reader ${LIFECYCLE_CYCLES:-5} times"
  CYCLES=${LIFECYCLE_CYCLES:-5}
  launch lifecycle "/reader-stress?base=$SMALL_URL&key=$KEY&book=$BOOK&pages=10&delay=200&mode=single&warmup=4000&back=0$(ram_param)"
  for _ in $(seq 1 90); do
    if grep -q "STRESS done" "$WORK/lifecycle.logcat"; then break; fi
    sleep 1
  done
  BASE_PSS=$(pss_now)
  JB=$(journal_reads small)
  for i in $(seq 1 "$CYCLES"); do
    $ADB shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
    sleep 3
    $ADB shell "am start -n $PKG/.MainActivity" >/dev/null 2>&1 || true
    sleep 3
    printf '   cycle %s: PSS %s KB\n' "$i" "$(pss_now)"
  done
  END_PSS=$(pss_now)
  stop_logging
  collect lifecycle small
  {
    printf 'journal_before=%s\njournal_after=%s\n' "$JB" "$(journal_reads small)"
    printf 'pss_first=%s\npss_late=%s\npss_peak=%s\n' "$BASE_PSS" "$END_PSS" "$END_PSS"
  } >> "$WORK/lifecycle.metrics"
  L=$(grep -E "STRESS lifecycle" "$WORK/lifecycle.logcat" | tail -1 | sed 's/.*flutter *: //')
  printf '   %s\n' "${L:-no lifecycle line was reported}"
  PAUSES=$(printf '%s' "$L" | sed -n 's/.*pauses=\([0-9]*\).*/\1/p')
  RESUMES=$(printf '%s' "$L" | sed -n 's/.*resumes=\([0-9]*\).*/\1/p')
  PAGE=$(printf '%s' "$L" | sed -n 's/.*page=\([0-9]*\).*/\1/p')
  printf '   reader saw %s pauses and %s resumes, still on page %s\n' \
    "${PAUSES:-0}" "${RESUMES:-0}" "${PAGE:-0}"
  if [ "${PAUSES:-0}" -ge "$CYCLES" ] && [ "${RESUMES:-0}" -ge "$((CYCLES - 1))" ]; then
    ok "every background/foreground cycle reached the reader"
  else
    fail "cycles sent: $CYCLES, reader reported ${PAUSES:-0} pauses / ${RESUMES:-0} resumes"
  fi
  if [ "${PAGE:-0}" -ge 10 ]; then
    ok "the reader stayed on its place in the book across the cycling"
  else
    fail "the page position was lost across backgrounding (page=${PAGE:-0})"
  fi
  LREADS=$(( $(journal_reads small) - JB ))
  LDISTINCT=$(distinct_in "$JB" "$(journal_reads small)" small)
  printf '   after the read: %s further page reads, %s distinct\n' "$LREADS" "$LDISTINCT"
  if [ "$LREADS" = "$LDISTINCT" ]; then
    ok "no already-served page was re-downloaded on resume"
  else
    fail "$((LREADS - LDISTINCT)) duplicate reads after resuming"
  fi
  if [ "$(awk -v a="$END_PSS" -v b="$BASE_PSS" 'BEGIN{print (a<=b*1.25+20480)?1:0}')" = 1 ]; then
    ok "PSS did not grow across $CYCLES background cycles ($BASE_PSS -> $END_PSS KB)"
  else
    fail "PSS grew across backgrounding: $BASE_PSS -> $END_PSS KB"
  fi
fi

say "3/3 verdict"
M="$WORK/small.metrics"
RAM=$(metric "$M" deviceRam); MEM=$(metric "$M" memoryBudget)
CACHE=$(metric "$M" cacheMaxBytes); SLOTS=$(metric "$M" decodeSlots)
printf '   deviceRam=%s memoryBudget=%s imageCacheMax=%s decodeSlots=%s settledCap=%s\n' \
  "$RAM" "$MEM" "$CACHE" "$SLOTS" "$(metric "$M" cap)"
if [ "${RAM:-0}" -gt 268435456 ] 2>/dev/null; then
  ok "the platform channel reported ${RAM} bytes of RAM"
else
  fail "device RAM probe returned '${RAM:-empty}': the tier is sizing itself blind"
fi
check "the UI applied the plan's memory budget to its image cache" "$CACHE" "$MEM"
if [ "${SLOTS:-0}" -ge 4 ] && [ "${SLOTS:-0}" -le 32 ]; then
  ok "decode slots $SLOTS, inside the contract floor and ceiling"
else
  fail "decode slots was ${SLOTS:-empty}"
fi
EFFECTIVE="${DEVICE_RAM:-$RAM}"
if [ "${EFFECTIVE:-0}" -gt 0 ] 2>/dev/null; then
  EXPECT=$((EFFECTIVE / 8)); [ "$EXPECT" -gt 268435456 ] && EXPECT=268435456
  [ "$EXPECT" -lt 16777216 ] && EXPECT=16777216
  if [ "$(awk -v m="${MEM:-0}" -v e="$EXPECT" 'BEGIN{print (m<=e*1.35 && m>=e*0.6)?1:0}')" = 1 ]; then
    ok "a $((EFFECTIVE / 1048576)) MB device sized its tier at ${MEM} bytes (expected near $EXPECT)"
  else
    fail "${EFFECTIVE} bytes of RAM should size the tier near $EXPECT, got ${MEM:-?}"
  fi
fi
FIRST=$(metric "$M" pss_first); LATE=$(metric "$M" pss_late); PEAK=$(metric "$M" pss_peak)
printf '   PSS across %s turns: first %s KB, last-quarter peak %s KB, overall peak %s KB\n' \
  "$PAGES" "$FIRST" "$LATE" "$PEAK"
if [ "$(awk -v a="${LATE:-0}" -v b="${FIRST:-1}" 'BEGIN{print (a<=b*1.35+20480)?1:0}')" = 1 ]; then
  ok "PSS did not climb across the session"
else
  fail "PSS grew across the run: $FIRST KB -> $LATE KB"
fi
EVENTS=$(metric "$M" pressure_events)
SAMPLES=$(metric "$M" pss_samples)
if [ -n "$SOAK" ]; then
  printf '   soak: %s trim-memory callbacks handled over %s PSS samples across %s turns\n' \
    "${EVENTS:-0}" "${SAMPLES:-0}" "$PAGES"
  # How many callbacks the platform chose to deliver is not the reader's contract:
  # the embedding forwards a trim only when severity *increases*, so a session gets
  # a few at most. The asserted properties are that escalating pressure arrived
  # more than once, and that the page on screen survived the one that mattered
  # (checked separately below) — not an exact count, which the OS does not promise.
  if [ "${EVENTS:-0}" -ge 2 ]; then
    ok "the reader took $EVENTS escalating pressure callbacks without losing the session"
  elif [ "${EVENTS:-0}" -ge 1 ]; then
    printf '   ok   %s pressure callback handled (Android sends more only as severity rises)\n' "$EVENTS"
  else
    fail "no memory-pressure callback reached the reader during a $PAGES-turn soak"
  fi
  if [ -n "$($ADB shell pidof "$PKG" | tr -d '\r')" ]; then
    ok "still the same process at the end of the soak (nothing was killed)"
  else
    fail "the process did not survive the soak"
  fi
fi
if [ -n "$BASE_URL" ]; then
  printf '   the duplicate check needs the fixture journal; skipped for --base-url\n'
else
  JB=$(metric "$M" journal_before); JA=$(metric "$M" journal_after)
  READS=$((JA - JB)); DISTINCT=$(distinct_in "$JB" "$JA" small)
  printf '   this pass served %s page reads, %s distinct pages\n' "$READS" "$DISTINCT"
  # The acceptance line is "fast page turns do not produce *large numbers* of
  # duplicate requests", so the bound is a rate. Zero duplicates is the normal
  # result and is printed; a single one is a retry after a transient failure, which
  # is what the reader is supposed to do.
  DUPES=$((READS - DISTINCT))
  if [ "${READS:-0}" -gt 0 ] && [ "$DUPES" -le 0 ]; then
    ok "not one page was served twice across $READS reads"
  elif [ "$(awk -v d="$DUPES" -v r="$READS" 'BEGIN{print (d<=r/100)?1:0}')" = 1 ]; then
    ok "$DUPES duplicate read in $READS (a retry after a transient failure)"
  else
    fail "$DUPES duplicates in $READS reads: more than 1%"
  fi
fi
PB=$(metric "$M" pss_before_pressure); PA=$(metric "$M" pss_after_pressure)
printf '   under trim-memory: PSS %s -> %s KB, image cache handed back %s bytes (%s KB of images held at the end)\n' \
  "$PB" "$PA" "$(metric "$M" cacheBytesGivenBack)" "$(( $(metric "$M" images_held_at_end) / 1024 ))"
if [ -n "$(metric "$M" events)" ]; then
  ok "the app reported the platform's trim-memory callback"
else
  fail "no STRESS pressure line: onTrimMemory never reached the reader"
fi
HELD_KB=$(( $(metric "$M" images_held_at_end) / 1024 ))
GOT_BACK=$((PB - PA))
if [ "$GOT_BACK" -ge 4096 ]; then
  ok "trim-memory made the process give back $GOT_BACK KB"
elif [ "$HELD_KB" -gt 1024 ]; then
  fail "$HELD_KB KB of decoded images held, yet only $GOT_BACK KB came back"
elif [ "$(awk -v a="${PA:-0}" -v b="${PB:-1}" 'BEGIN{print (a<=b*1.02)?1:0}')" = 1 ]; then
  ok "nothing material was held, and PSS did not climb under the request"
else
  fail "PSS rose by more than 2% while the platform was asking for memory back"
fi
case "$(metric "$M" stillReadable)" in
  true) ok "the page on screen survived the pressure response" ;;
  *) fail "the pressure response cost the reader the page it was showing" ;;
esac
SMALL_WARM=$(metric "$M" warmP95ms); SMALL_COLD=$(metric "$M" coldP95ms)
printf '   turn cost: cold p95 %sms, warm p95 %sms' "$SMALL_COLD" "$SMALL_WARM"
if [ -f "$WORK/fourk.metrics" ]; then
  F=$(metric "$WORK/fourk.metrics" warmP95ms); FC=$(metric "$WORK/fourk.metrics" coldP95ms)
  FP=$(metric "$WORK/fourk.metrics" pss_peak)
  printf ', 4K cold %sms, 4K warm %sms\n' "$FC" "$F"
  printf '   4K peak PSS %s KB vs small-page peak %s KB\n' "$FP" "$PEAK"
  if [ "$(awk -v a="${FP:-0}" -v b="${PEAK:-1}" 'BEGIN{print (a<=b*4+262144)?1:0}')" = 1 ]; then
    ok "pages 200x heavier cost a bounded multiple of memory"
  else
    fail "4K pages blew the memory bound: $FP KB vs $PEAK KB"
  fi
else
  printf '\n'
fi
if [ "$(awk -v w="${SMALL_WARM:-999999}" -v c="${SMALL_COLD:-1}" 'BEGIN{print (w<=c)?1:0}')" = 1 ]; then
  ok "a cached page turn is no more expensive than reaching a new one"
else
  fail "a cached turn (${SMALL_WARM}ms p95) cost more than a cold one (${SMALL_COLD}ms)"
fi

echo
if [ "$FAILURES" = 0 ]; then
  echo "STAGE 8 DEVICE ACCEPTANCE OK"
else
  echo "STAGE 8 DEVICE ACCEPTANCE FAILED: $FAILURES check(s)"
  exit 1
fi
