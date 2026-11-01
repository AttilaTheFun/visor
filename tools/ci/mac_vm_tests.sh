#!/bin/bash
# Visor's tests that need a Mac, in a macOS VM leased from OS Server
# (xcode_27_2: Xcode 27.2 and its iOS simulator): the server's Apple side,
# the client, its views and SSH, each an .xctest bundle (macos_unit_test,
# which builds on Linux too). The builds are the container job's
# (tools/ci/container_build.sh: every app, and the Mac's libraries, built on
# Linux), and the tests with nothing of Apple's in them run on Linux
# (tools/ci/linux_tests.sh).
#
#   tools/ci/mac_vm_tests.sh
#
# The VM (tools/ci/mac_vm.sh) is the script's alone, released however it
# ends.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/tools/ci/mac_vm.sh"
mac_vm_start visor-ci

mac_vm_steps << 'STEPS'
    test)
        cd visor && bazel test --test_output=errors \
            //tests/visor_server_tests \
            //tests/visor_client_tests \
            //tests/visor_ui_tests \
            //tests/visor_ssh_tests
        ;;
STEPS

echo "::group::A macOS VM (xcode_27_2)"
mac_vm_lease
mac_vm_copy_tree
echo "::endgroup::"

echo "::group::Test"
status=0
run in_vm test || status=$?
echo "::endgroup::"
[ "$status" -eq 0 ] || echo "::error::Test failed ($status)"
mac_vm_release
finished=1
exit "$status"
