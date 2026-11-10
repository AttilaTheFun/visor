#!/bin/bash
# Blue Visor's web client (the client on Isomer: docs/isomer.md) in a Linux
# container (CI's own, visor-jit, of the agent image named): built optimized, its tests
# run, then checked in headless Chromium — the end-to-end test against the
# stand-in server on its three roads, the transcript's layout, and the
# composer typed into. Chromium is Playwright's arm64 build at a pinned
# release (Chrome for Testing has no arm64 Linux), fetched for the run.
# Without ffmpeg the end-to-end review keeps its screens and makes no
# recording. Run with `bazel run //tools/ci:container_blue_web`.
#
#   bazel run //tools/ci:container_blue_web -- <image> <review folder> [--build-only]
#
# --build-only builds the site and runs nothing, neither its tests nor
# Chromium: CI's run until the Mac Studio (Logan, 5 Nov 2026: Visor is
# iOS, macOS and Android for now; the web is kept building, not run).
#
# The review (tools/isomer/e2e/run.py --review) is written to the folder
# given, in the checkout, for the run's `blue-web-review` artifact. The
# script fails as the first step that fails, after all ran.
set -euo pipefail
ROOT="${BUILD_WORKSPACE_DIRECTORY:-$(cd "$(dirname "$0")/../.." && pwd)}"
IMAGE="${1:?the agent image, ghcr.io/attilathefun/visor-agent:<version>}"
REVIEW="$ROOT/${2:?the review folder, in the checkout}"
RUNS=1
case "${3:-}" in
    "") ;;
    --build-only) RUNS=0 ;;
    *) echo "usage: container_blue_web.sh <image> <review folder> [--build-only]" >&2; exit 2 ;;
esac
PLAYWRIGHT="1.64.1"

# In a Linux container (CI's visor-jit, its Bazel reading Shireworks'
# cache): run here, IMAGE unused, Chromium fetched for the run. Not on a
# Mac: Shireworks runs nothing in a container from one (no mounts, no
# volumes), so lease a container of the agent image and run it there.
if [ "$(uname -s)" != Linux ]; then
    echo "container_blue_web: runs in a Linux container (CI's visor-jit, or a Shireworks container lease of the agent image): Shireworks has no way to run it in one from a Mac" >&2
    exit 2
fi

steps='
root=$1 review=$2 playwright=$3 runs=$4
cd "$root"
failed=0
step() { echo "::group::$1"; shift; "$@" || { echo "::error::failed: $*"; failed=1; }; echo "::endgroup::"; }
if [ "$runs" -eq 0 ]; then
    step "Build" bazel build -c opt //applications/visor_web:visor_web_site
    exit $failed
fi
# Chromium needs NSS, which images before 0.44 lack.
if ! ldconfig -p | grep -q libnss3.so; then
    step "NSS" sh -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends libnss3 >/dev/null"
fi
export PLAYWRIGHT_BROWSERS_PATH=/var/cache/bazel/ms-playwright
step "Chromium" npx -y "playwright-core@$playwright" install chromium
chrome="$(ls -d "$PLAYWRIGHT_BROWSERS_PATH"/chromium-*/chrome-linux*/chrome | tail -1)"
# As root in a container, Chromium runs only without its sandbox.
mkdir -p /tmp/ci-bin
printf "#!/bin/sh\nexec \"%s\" --no-sandbox \"\$@\"\n" "$chrome" > /tmp/ci-bin/chrome
chmod 755 /tmp/ci-bin/chrome
export CHROME=/tmp/ci-bin/chrome
step "Build" bazel build -c opt //applications/visor_web:visor_web_site
step "Test" bazel test -c opt --test_output=errors //applications/visor_web/...
# The site by its full path: the image makes no bazel-out link in the checkout.
site="$(bazel info -c opt execution_root 2>/dev/null)/$(bazel cquery -c opt --output=files //applications/visor_web:visor_web_site 2>/dev/null)"
step "End to end" python3 tools/isomer/e2e/run.py --review "$review" "$site"
step "Layout" node tools/isomer/e2e/transcript_layout_check.js "$site"
step "Composer" node tools/isomer/e2e/composer_check.js "$site"
exit $failed
'

cd "$ROOT"
mkdir -p "$REVIEW"
# And how much memory it took (tools/ci/memory_watch.sh).
. "$ROOT/tools/ci/memory_watch.sh"
memory_watch_start
status=0
bash -c "$steps" container_blue_web "$ROOT" "$REVIEW" "$PLAYWRIGHT" "$RUNS" || status=$?
memory_watch_report "container_blue_web"
exit "$status"
