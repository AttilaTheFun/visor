#!/bin/bash
# The tests that need a Mac, built on Linux for an Apple silicon Mac, in the
# checkout (tools/ci/mac_vm_tests.sh runs it in the job's own container):
# the .xctest bundles under tests/ (macos_unit_test: the server's Apple
# side, the client, its views, SSH), each rules_apple's .zip of its bundle
# at its package's path (what the Mac's `xcrun xctest` runs, and what OS
# Server's Mac test slot will take), and tests.txt naming them, in one
# archive, for a macOS VM to run without Bazel or the tree. A bundle is
# whole: what its tests need is in its Resources (the agent host the
# server's tests run), and its run paths reach the installed Xcode's
# (rules_applecross).
#
#   tools/ci/build_mac_tests.sh <archive.tar.gz> [bazel options…]
#
# Bazel's log goes to standard error.
set -euo pipefail
archive="${1:?usage: tools/ci/build_mac_tests.sh <archive.tar.gz> [bazel options…]}"
shift
targets="$(bazel query 'kind(macos_unit_test, //tests/...)' 2> /dev/null)"
[ -n "$targets" ] || { echo "build_mac_tests.sh: no macos_unit_test under //tests" >&2; exit 1; }
# shellcheck disable=SC2086 # one target a word
bazel build --keep_going "$@" --macos_cpus=arm64 $targets
root="$(bazel info "$@" execution_root)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
# Each test's bundle: the .zip among its files (rules_apple's test rule
# gives its bundle's archive with its runner).
bazel cquery "$@" --macos_cpus=arm64 "set($targets)" --output=starlark \
    --starlark:expr='str(target.label) + " " + " ".join([f.path for f in target.files.to_list() if f.path.endswith(".zip")])' \
    2> /dev/null > "$stage/bundles"
mkdir "$stage/tests"
while read -r label path rest; do
    [ -n "$path" ] || { echo "build_mac_tests.sh: no bundle .zip for $label" >&2; exit 1; }
    name="${label#@@//}"
    name="${name#//}"
    name="${name/://}"
    mkdir -p "$stage/tests/$(dirname "$name")"
    cp -L "$root/$path" "$stage/tests/$name.zip"
    echo "$name" >> "$stage/tests/tests.txt"
done < "$stage/bundles"
tar -czf "$archive" -C "$stage/tests" .
cat "$stage/tests/tests.txt" >&2
