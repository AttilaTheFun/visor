#!/bin/bash
# Blue Visor's web client (the client on Isomer: docs/isomer.md), in a
# macOS VM leased from OS Server (xcode-27.0, which has Chrome): built
# optimized, its tests run, then checked in headless Chrome — the
# end-to-end test against the stand-in server on its three roads, the
# transcript's layout, and the composer typed into. node comes in with the
# tree (the image has none); without ffmpeg the end-to-end review keeps its
# screens and makes no recording.
#
#   tools/ci/mac_vm_blue_web.sh <review folder>
#
# The review (tools/isomer/e2e/run.py --review) is copied out to the folder
# given, for the run's `blue-web-review` artifact. The VM
# (tools/ci/mac_vm.sh) is the script's alone, released however it ends. The
# script fails as the first step that fails, after all ran.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REVIEW="${1:?the folder the review is copied out to}"
. "$ROOT/tools/ci/mac_vm.sh"
mac_vm_start visor-ci

mac_vm_steps << 'STEPS'
    build)
        cd visor && bazel build -c opt //applications/visor_web:visor_web_site
        ;;
    test)
        cd visor && bazel test -c opt --test_output=errors //applications/visor_web/...
        ;;
    e2e)
        cd visor && python3 tools/isomer/e2e/run.py --review ../review
        ;;
    layout)
        cd visor && node tools/isomer/e2e/transcript_layout_check.js "$(bazel cquery -c opt --output=files //applications/visor_web:visor_web_site)"
        ;;
    composer)
        cd visor && node tools/isomer/e2e/composer_check.js "$(bazel cquery -c opt --output=files //applications/visor_web:visor_web_site)"
        ;;
STEPS

echo "::group::A macOS VM (xcode-27.0)"
mac_vm_lease
mac_vm_node
mac_vm_copy_tree
echo "::endgroup::"

status=0
for step in build test e2e layout composer; do
    case "$step" in
        build) title="Build" ;;
        test) title="Test" ;;
        e2e) title="End to end" ;;
        layout) title="Transcript layout" ;;
        composer) title="Composer" ;;
    esac
    echo "::group::$title"
    step_status=0
    run in_vm "$step" || step_status=$?
    echo "::endgroup::"
    if [ "$step_status" -ne 0 ]; then
        echo "::error::$title failed ($step_status)"
        [ "$status" -ne 0 ] || status="$step_status"
    fi
done
mac_vm_fetch review "$REVIEW" || echo "mac_vm_blue_web.sh: no review to copy out" >&2
mac_vm_release
finished=1
exit "$status"
