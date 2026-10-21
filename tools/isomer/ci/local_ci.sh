#!/bin/bash
# local_ci.sh [--review DIR] [suite…]: blue Visor's suites, run on this Mac.
#
# The Isomer repositories had no hosted CI (2026-10-19): their
# suites run here, each reported to the commit it tested as a check run,
# local/<suite> (tools/isomer/ci/check.py), as visor's hosted jobs report theirs.
# HEAD must be pushed and the tree clean, or there is no commit the result
# is true of.
#
# Suites, in order (all by default):
#   test              bazel test //...
#   snapshots         the fixture's screens on web-mobile (Mobile Safari in
#                     the visor-snapshots simulator), android (the hermetic
#                     emulator) and blue's iPhone app in each orientation
#                     (ios, ios-landscape: tests/isomer_ios_fixture, as red's CI
#                     pictures red's), against tests/snapshots; any change
#                     fails until accepted
#   layout-web        the transcript's code blocks and pictures in headless Chrome
#   composer-web      AgentUI's composer typed into in headless Chrome
#   layout-android    the same on the emulator
#   composer-android  the same on the emulator
#   android-flow      the UI flow on the emulator, portrait and landscape
#   web-e2e           the web client against a stub server, each orientation
#
# --review DIR keeps the android-flow and web-e2e review runs there, for
# tools/isomer/snapshots/publish_review.py.
set -u
cd "$(dirname "$0")/../../.."
REVIEW=""
if [ "${1:-}" = "--review" ]; then REVIEW="$2"; shift 2; fi
SUITES=("$@")
[ ${#SUITES[@]} -eq 0 ] && SUITES=(test snapshots layout-web composer-web layout-android composer-android android-flow web-e2e)

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "[ci] the tree has changes: commit them first, so a check names what it tested" >&2
  exit 2
fi
if ! git branch -r --contains HEAD | grep -q .; then
  echo "[ci] HEAD is not pushed: GitHub takes checks only on commits it has" >&2
  exit 2
fi

CHECK="python3 tools/isomer/ci/check.py run"
REVIEW_ARGS=()
[ -n "$REVIEW" ] && REVIEW_ARGS=(--review "$REVIEW")
SITE() { bazel cquery -c opt --output=files //applications/visor_web:visor_web_site 2>/dev/null; }
ADB="$(cd tools/isomer/uitests && python3 -c 'from android_flow import adb_path; print(adb_path())')"
failed=0
verdicts=""
# Each suite's verdict, said as it ends and again at the end.
verdict() {
  local word=passed
  [ "$2" = 0 ] || { word=FAILED; failed=1; }
  echo "[ci] $1: $word"
  verdicts="$verdicts $1:$word"
}

for suite in "${SUITES[@]}"; do
  case "$suite" in
    test) $CHECK local/test -- bazel test //... ;;
    snapshots) $CHECK local/snapshots -- python3 tools/isomer/snapshots/snapshots.py run --targets web-mobile,android,ios,ios-landscape ;;
    layout-web) bazel build -c opt //applications/visor_web:visor_web_site >/dev/null 2>&1
      $CHECK local/layout-web -- node tools/isomer/e2e/transcript_layout_check.js "$(SITE)" ;;
    composer-web) bazel build -c opt //applications/visor_web:visor_web_site >/dev/null 2>&1
      $CHECK local/composer-web -- node tools/isomer/e2e/composer_check.js "$(SITE)" ;;
    layout-android) $CHECK local/layout-android -- python3 tools/isomer/uitests/transcript_layout_android.py ;;
    composer-android) $CHECK local/composer-android -- python3 tools/isomer/uitests/composer_android.py ;;
    android-flow)
      # The flow expects a running emulator: boot one of our own, and stop
      # it after (by adb, not by a process pattern).
      booted=0
      if ! "$ADB" devices | grep -q "^emulator-5554[[:space:]]*device"; then
        (bazel run @isomer//tools/android/emulator -- -no-window -no-audio -port 5554 >/dev/null 2>&1 &)
        for _ in $(seq 1 100); do
          sleep 3
          [ "$("$ADB" -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && break
        done
        booted=1
      fi
      $CHECK local/android-flow -- python3 tools/isomer/uitests/android_flow.py ${REVIEW_ARGS[@]+"${REVIEW_ARGS[@]}"}
      code=$?
      [ $booted = 1 ] && "$ADB" -s emulator-5554 emu kill >/dev/null 2>&1
      verdict "$suite" $code
      continue ;;
    web-e2e) $CHECK local/web-e2e -- python3 tools/isomer/e2e/run.py ${REVIEW_ARGS[@]+"${REVIEW_ARGS[@]}"} ;;
    *) echo "[ci] no suite $suite" >&2; failed=1; continue ;;
  esac
  verdict "$suite" $?
  # The emulator tests leave it a moment to settle between them.
  case "$suite" in layout-android|composer-android) sleep 5 ;; esac
done
echo "[ci] $([ $failed = 0 ] && echo "all passed" || echo "FAILED") on $(git rev-parse --short HEAD):$verdicts"
exit $failed
