#!/bin/bash
# Visor's build and tests for the Mac and the iPhone, in a macOS VM leased
# from OS Server (xcode-27.0: Xcode 27.0 and its iOS simulator). Every
# target compiles in the Swift 6 mode with warnings as errors
# (tools/swift), so building is a check of its own:
#   - macos: the libraries, the staging server, the container host and the
#     apps' own code for the Mac;
#   - ios: the views and the phone app's code for the iPhone's simulator
#     (the app bundles need a signing team and are not built here);
#   - test: the libraries' tests.
#
#   tools/ci/mac_vm_tests.sh
#
# The VM (tools/ci/mac_vm.sh) is the script's alone, released however it
# ends. The script fails as the first of them that fails, after all ran.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tools/ci/mac_vm.sh"
mac_vm_start visor-ci

mac_vm_steps << 'STEPS'
    macos)
        cd visor && bazel build \
            //libraries/... \
            //tools/staging_server \
            //applications/visor_container_host:visor-container-host \
            //applications/visor_macos:macos_lib \
            //applications/visor_menubar:menubar_lib
        ;;
    ios)
        cd visor && bazel build --platforms=@apple_support//platforms:ios_sim_arm64 \
            //libraries/visor_ui \
            //applications/visor_ios:ios_lib \
            //applications/visor_ios:widget_lib
        ;;
    test)
        cd visor && bazel test --test_output=errors \
            //tests/visor_server_tests \
            //tests/visor_container_host_tests \
            //tests/visor_runner_tests \
            //tests/visor_client_tests \
            //tests/visor_ui_tests \
            //tests/visor_ssh_tests \
            //tests/message_cache_tests \
            //tests/claude_transcript_tests
        ;;
STEPS

echo "::group::A macOS VM (xcode-27.0)"
mac_vm_lease
mac_vm_copy_tree
echo "::endgroup::"

status=0
for step in macos ios test; do
    case "$step" in
        macos) title="Build (macOS)" ;;
        ios) title="Build (iOS)" ;;
        test) title="Test" ;;
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
mac_vm_release
finished=1
exit "$status"
