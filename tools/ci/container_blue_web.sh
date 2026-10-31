#!/bin/bash
# Blue Visor's web client (the client on Isomer: docs/isomer.md) in a Linux
# container leased from the runner's Mac's OS Server (`oss machine run
# container --inside`), of Visor's agent image: built optimized, its tests
# run, then checked in headless Chromium — the end-to-end test against the
# stand-in server on its three roads, the transcript's layout, and the
# composer typed into. Chromium is Playwright's arm64 build at a pinned
# release (Chrome for Testing has no arm64 Linux), kept in Bazel's volume.
# Without ffmpeg the end-to-end review keeps its screens and makes no
# recording. Run with `bazel run //tools/ci:container_blue_web`.
#
#   bazel run //tools/ci:container_blue_web -- <image> <review folder>
#
#   OSS_FILES_HOST   the name the container reaches this Mac's OS Server by
#                    (default: this Mac's tailnet name, from Tailscale)
#   VISOR_CI_VOLUME  Bazel's tree and Chromium, kept between runs (default:
#                    visor-web-ci, `:keep`). One run at a time uses it
#                    (ci.yml's concurrency).
#
# The review (tools/isomer/e2e/run.py --review) is written to the folder
# given, in the checkout, for the run's `blue-web-review` artifact. The
# script fails as the first step that fails, after all ran.
set -euo pipefail
ROOT="${BUILD_WORKSPACE_DIRECTORY:?run it with bazel run}"
IMAGE="${1:?the agent image, ghcr.io/attilathefun/visor-agent:<version>}"
REVIEW="$ROOT/${2:?the review folder, in the checkout}"
VOLUME="${VISOR_CI_VOLUME:-visor-web-ci}"
PLAYWRIGHT="1.64.1"

OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss)"
host="${OSS_FILES_HOST:-}"
if [ -z "$host" ]; then
    host="$(/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
fi

steps='
root=$1 review=$2 playwright=$3
cd "$root"
failed=0
step() { echo "::group::$1"; shift; "$@" || { echo "::error::failed: $*"; failed=1; }; echo "::endgroup::"; }
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
exec "$OSS" machine run container --image="$IMAGE" --cpus=6 --memory=16 \
    --mount="$ROOT:$ROOT" --volume="$VOLUME:/var/cache/bazel:64:keep" \
    --inside --cache="$host" -- \
    bash -c "$steps" container_blue_web "$ROOT" "$REVIEW" "$PLAYWRIGHT"
