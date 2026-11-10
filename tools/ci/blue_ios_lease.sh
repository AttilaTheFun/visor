#!/bin/bash
# Blue Visor's web client on the iPhone, from a Linux container (CI's
# visor-jit): the web site built where it runs (tools/ci/container_build.sh),
# then pictured on an iOS lease as tools/isomer/snapshots/snapshots.py
# pictures it on a Mac:
#
#   web-mobile          the web site served on a Mac slot of Shireworks'
#                       primary Mac VM (tools/ci/mac_slot.sh,
#                       tools/isomer/snapshots/serve_site.py), on that VM's
#                       loopback, which the simulators it runs share, and
#                       opened in an iPhone 17 Pro lease's Mobile Safari
#                       (`shireworks.sh simctl <id> openurl`, the lease's
#                       screenshots)
#
# then compared with tests/snapshots by snapshots.py, its run (report.html,
# manifests) in <run dir>. The script fails
# as snapshots.py does (a changed or failed screen), or when a step fails.
# (Blue's own iPhone apps, the WasmKit one and the one compiled against
# Isomer's frameworks, were pictured here too until they went, 4 Nov 2026.)
#
#   tools/ci/blue_ios_lease.sh --image <agent image> --run <dir>
#
# Each lease, and the slot, is the script's alone: renewed while it runs,
# released however it ends (a kill nothing can trap leaves it its hour at
# most).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
me="$(basename "$0")"
SW="$ROOT/tools/ci/shireworks.sh"

usage() { echo "usage: tools/ci/blue_ios_lease.sh --image <agent image> --run <dir>" >&2; exit 2; }
image=""
run_dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --image) image="${2:?--image takes the agent image}"; shift 2 ;;
        --run) run_dir="${2:?--run takes a folder}"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$image" ] && [ -n "$run_dir" ] || usage

work="$(mktemp -d)"
chmod 700 "$work"
built="$ROOT/.ci/blue-ios-build"
lease=""
renewer=""
child=""
server=""
finished=""
. "$ROOT/tools/ci/mac_slot.sh"
release() {
    if [ -n "$renewer" ]; then kill "$renewer" 2> /dev/null || true; wait "$renewer" 2> /dev/null || true; renewer=""; fi
    # A lease asked for as the script was stopped: its id, if it came.
    [ -n "$lease" ] || lease="$(. "$work/lease" 2> /dev/null; printf '%s' "${SHIREWORKS_ID:-}")"
    if [ -n "$lease" ]; then
        sh "$SW" release "$lease" || echo "$me: lease $lease was not released: shireworks.sh release $lease" >&2
        lease=""
        rm -f "$work/lease"
    fi
}
# macOS's bash (3.2) runs this with $? 0 when an unset variable stops the
# script (set -eu): an end before the last line is a failure, whatever it says.
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    [ -z "$child" ] || kill "$child" 2> /dev/null || true
    release
    [ -z "$server" ] || kill "$server" 2> /dev/null || true
    mac_slot_release
    rm -rf "$work"
    # The build's files too: the checkout is the runner's, kept between jobs.
    [ -z "${built:-}" ] || { chmod -R u+w "$built" 2> /dev/null || true; rm -rf "$built"; }
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Long commands run in the background and are waited for, so a signal (the
# runner cancelling the job) reaches the trap at once, not when they end.
run() {
    "$@" &
    child=$!
    local status=0
    wait "$child" || status=$?
    child=""
    return "$status"
}

# An iOS lease of the device named, renewed every ten minutes while the
# script lives (a cancel that kills it past its trap leaves no renewer: $$ is
# the script's, in the subshell too).
lease_ios() {
    echo "::group::An iOS lease ($1)"
    # --device: the device type, passed on as the lease's `device`.
    run sh "$SW" lease ios --device="$1" --minutes=60 > "$work/lease"
    lease="$(. "$work/lease"; printf '%s' "$SHIREWORKS_ID")"
    echo "Leased $lease"
    (
        trap 'kill $! 2> /dev/null; exit 0' TERM
        while kill -0 "$$" 2> /dev/null; do
            sleep 600 &
            wait $!
            kill -0 "$$" 2> /dev/null || break
            sh "$SW" renew "$lease" --minutes=60 > /dev/null || true
        done
    ) &
    renewer=$!
    echo "::endgroup::"
}

echo "::group::The web site, built on Linux"
# --compilation_mode=opt, not -c opt: container_build tells options from
# targets by a leading dash. Here, in the job's own container.
(cd "$ROOT" && VISOR_CI_PACKAGE="$built" run tools/ci/container_build.sh "$image" \
    --compilation_mode=opt //applications/visor_web:visor_web_site)
[ -e "$built/visor_web_site" ] || { echo "$me: the build left no visor_web_site" >&2; exit 1; }
echo "::endgroup::"

# The site on a Mac slot, served on the primary's loopback (a port of the
# run's own, beside the slots of other runs), where the lease's simulator
# reaches it: a server in this container is on no network the VM routes to.
echo "::group::The web site, served on a Mac slot"
mac_slot_lease
cp "$ROOT/tools/isomer/snapshots/serve_site.py" "$built/"
tar -C "$built" -cf "$work/blue-ios.tar" visor_web_site serve_site.py
mac_slot_upload "$work/blue-ios.tar" blue-ios.tar
mac_slot_exec /bin/bash -c 'cd && rm -rf blue-ios && mkdir blue-ios && tar -xf blue-ios.tar -C blue-ios && rm blue-ios.tar'
port=$((20000 + RANDOM % 20000))
sh "$SW" run "$slot" -- /usr/bin/python3 blue-ios/serve_site.py blue-ios/visor_web_site 127.0.0.1 "$port" &
server=$!
up=""
for _ in $(seq 1 30); do
    if mac_slot_exec /usr/bin/curl -fsS -o /dev/null "http://127.0.0.1:$port/"; then up=1; break; fi
    sleep 1
done
[ -n "$up" ] || { echo "$me: the site didn't come up on the slot's port $port" >&2; exit 1; }
echo "Served on the slot's 127.0.0.1:$port"
echo "::endgroup::"

# Mobile Safari, on an iPhone 17 Pro (web-mobile's pictures'), compared by
# snapshots.py.
lease_ios "iPhone 17 Pro"
mkdir -p "$run_dir"
snapshots_status=0
run env VISOR_SNAPSHOT_RUN_DIR="$run_dir/snapshots" VISOR_SNAPSHOT_IOS_LEASE="$lease" \
    VISOR_SNAPSHOT_WEB_BASE="http://localhost:$port" \
    python3 "$ROOT/tools/isomer/snapshots/snapshots.py" run --targets web-mobile || snapshots_status=$?
release
kill "$server" 2> /dev/null || true
server=""
mac_slot_release

finished=1
exit "$snapshots_status"
