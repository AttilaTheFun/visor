#!/bin/bash
# CI's build of the apps, each platform where its tools run:
# - on Linux (GitHub's x86_64 Ubuntu, in Swift's own image with what
#   tools/ci/job_tools.sh adds): the Linux client and blue Visor's Android
#   APK (Google's Android SDK and NDK tools are x86_64);
# - the Apple targets (VISOR_CI_PLATFORM=apple): the iPhone and iPad app,
#   Visor.app, Visor Server and Visor Disk Utility, the Mac's test bundles,
#   then the libraries, the staging server and the command-line server for
#   the Mac. In CI on a Nimbus runner (a Linux container, `visor-ci`: Logan,
#   26 Nov 2026, GitHub's Mac queue the bottleneck), with rules_applecross
#   (.bazelrc's apple_on_linux), Xcode 27.2's SDK archive and the ported
#   tools coming from Nimbus' files (`nimbus job bazel-config`,
#   .github/actions/nimbus_bazel), never on GitHub's own runners: Apple's
#   SDKs may not be redistributed. On a Mac, with its own Xcode, as before:
#   a builder's own, and the default there.
# A proposal's and a release's apps (alpha-apple, release-apple) are built
# with rules_applecross's Swift, not Xcode's, since 0.62.1 aborted at launch
# (docs/DEVELOPMENT.md, "Release builds"): on Linux that is apple_on_linux's
# own; on a Mac, --config=apple_cross_mac.
# Bazel's settings (its caches, the downloads, BuildBuddy's remote cache
# where the job has its key; on a Nimbus runner, Nimbus' cache and files)
# are written before this runs (.github/actions/bazel_cache,
# tools/ci/ci_bazel.sh; .github/actions/nimbus_bazel). Run with
# `bazel run //tools/ci:container_build` too.
#
#   [VISOR_CI_PLATFORM=apple|linux] tools/ci/container_build.sh [<bazel build args>…]
#
# With no arguments, the platform's every app (above): VISOR_CI_PLATFORM's,
# else the machine's (a Mac's apple, Linux's linux). With arguments,
# those, and with VISOR_CI_PACKAGE (a folder in this checkout, emptied
# first) the targets' files copied there, found by cquery with the build's
# own options, for CI to sign and publish: an .ipa, a Mac app's .zip, an
# .apk (its unsigned sibling beside it). Flags as --name=value: every
# argument that doesn't start with "-" is taken for a target.
set -euo pipefail
ROOT="${BUILD_WORKSPACE_DIRECTORY:-$(cd "$(dirname "$0")/../.." && pwd)}"
me="container_build"

case "$(uname -s)" in
    Darwin) platform=apple ;;
    Linux) platform=linux ;;
    *) echo "$me: builds on Linux or a Mac, not $(uname -s)" >&2; exit 2 ;;
esac
# The Apple targets on Linux: rules_applecross's, which only a builder with
# Apple's SDK archive has (a Nimbus runner: apple_on_linux, from Nimbus'
# bazelrc). Not on a Mac's own Linux targets: a Mac builds Apple's.
case "${VISOR_CI_PLATFORM:-}" in
    "") ;;
    apple) platform=apple ;;
    linux)
        [ "$platform" = linux ] || { echo "$me: VISOR_CI_PLATFORM=linux on a Mac: the Linux apps build on Linux" >&2; exit 2; }
        ;;
    *) echo "$me: VISOR_CI_PLATFORM is apple or linux, not $VISOR_CI_PLATFORM" >&2; exit 2 ;;
esac

full=0
if [ $# -eq 0 ]; then
    full=1
    if [ "$platform" = apple ]; then
        set -- --macos_cpus=arm64 --ios_multi_cpus=sim_arm64 \
            //applications/visor_ios \
            //applications/visor_mac \
            //applications/visor_menubar \
            //applications/visor_disk_utility \
            //tests/visor_server_tests \
            //tests/visor_client_tests \
            //tests/visor_ui_tests \
            //tests/visor_ssh_tests
    else
        set -- //applications/visor_client_linux \
            //applications/visor_android:visor_android_apk
    fi
fi

package=""
if [ -n "${VISOR_CI_PACKAGE:-}" ]; then
    # `bazel run` starts this in its runfiles: a relative folder is the
    # checkout's.
    case "$VISOR_CI_PACKAGE" in /*) ;; *) VISOR_CI_PACKAGE="$ROOT/$VISOR_CI_PACKAGE" ;; esac
    mkdir -p "$VISOR_CI_PACKAGE"
    package="$(cd "$VISOR_CI_PACKAGE" && pwd)"
    case "$package/" in
        "$ROOT"/*) ;;
        *) echo "$me: VISOR_CI_PACKAGE must be a folder in this checkout ($ROOT)" >&2; exit 1 ;;
    esac
    rm -rf "${package:?}"/*
fi

cd "$ROOT"
echo "::group::The apps ($platform)"
apps=0
bazel build --keep_going "$@" || apps=$?
echo "::endgroup::"
if [ -n "$package" ] && [ $apps -eq 0 ]; then
    # The files of the targets, by cquery with the build options, from the
    # execution root (no bazel-out link in the checkout: ci_bazel.sh).
    options=()
    query=""
    for argument in "$@"; do
        case "$argument" in -*) options+=("$argument") ;; *) query="${query:+$query + }$argument" ;; esac
    done
    root_out="$(bazel info ${options[@]+"${options[@]}"} execution_root)"
    files="$(bazel cquery ${options[@]+"${options[@]}"} "$query" --output=files 2> /dev/null)"
    # -R: a folder (a web site) too.
    for file in $files; do cp -RL "$root_out/$file" "$package/"; done
    # Writable: Bazel's outputs are read-only, and a folder copied so kept
    # the next checkout from removing it.
    chmod -R u+w "$package"
    ls -l "$package"
fi
[ "$full" = 1 ] && [ "$platform" = apple ] || exit $apps
echo "::group::The Mac: libraries, staging server, command-line server"
mac=0
bazel build --keep_going --platforms=@apple_support//platforms:macos_arm64 \
    //libraries/... //tools/staging_server //applications/visor_server_mac:visor-server || mac=$?
echo "::endgroup::"
[ $apps -ne 0 ] && exit $apps
exit $mac
