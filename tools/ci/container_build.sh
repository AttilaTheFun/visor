#!/bin/bash
# CI's build of the apps in a Linux container (the Apple apps, the Linux
# client and blue Visor's Android APK, arm64): the job's own (CI's
# visor-jit, a container OS Server makes for each job, side by side with the
# others), or, run on a Mac, one leased from that Mac's OS Server (`oss
# machine run container --inside`) of the agent image named. The Apple apps take Xcode 27.2's SDK
# archive and rules_applecross's ported tools from the same OS Server's
# files (by SHA-256, with its cache's read token) through a downloader
# config written here, and its Bazel reads that server's cache: no host is
# named in the repository. Run with `bazel run //tools/ci:container_build`.
#
#   bazel run //tools/ci:container_build -- <image> [<bazel build args>…]
#
#   OSS_FILES_HOST   the name the container reaches this Mac's OS Server by
#                    (default: this Mac's tailnet name, from Tailscale)
#   VISOR_CI_VOLUME  Bazel's tree, kept between builds (default: visor-ci;
#                    `:keep`, so OS Server keeps it when the lease ends, and
#                    a cancelled run's SIGTERM releases the lease at once).
#                    One build at a time uses it (OS Server holds a lease
#                    whose volume another has until it is free).
#   VISOR_CI_PACKAGE a folder in this checkout (a relative path is taken
#                    from the checkout): the built targets' files (an .ipa,
#                    a test bundle's .zip, a web site's folder) copied into
#                    it, as Bazel's tree is the container's (CI's alpha,
#                    adhoc and release take the iPhone app so,
#                    tools/ci/ios_lease_proof.sh the app and its probe).
#                    Emptied first. Its build arguments are told apart by
#                    their dash: an option with a value takes it after `=`
#                    (`--compilation_mode=opt`, not `-c opt`, whose `opt`
#                    would be read as a target).
#
# With no build arguments (CI's run) it builds every app (the iPhone's for
# the simulator, the Mac's, the Linux client, blue Visor's Android APK) and
# the Mac's test bundles (run on a Mac: the test job),
# then, for the Mac, the libraries, the staging server and the command-line
# server: every target compiles in the Swift 6 mode with warnings as errors
# (tools/swift), so building is a check of its own.
set -euo pipefail
ROOT="${BUILD_WORKSPACE_DIRECTORY:-$(cd "$(dirname "$0")/../.." && pwd)}"
IMAGE="${1:?the agent image, ghcr.io/attilathefun/visor-agent:<version>}"
shift
VOLUME="${VISOR_CI_VOLUME:-visor-ci}"
SDK_SHA256="b1583e60f9fd35881b5a948ce71627079877f1ced7ea231e14d3c342dd389668"

# Already in a Linux container (CI's visor-jit: OS Server's cache in its
# ~/.bazelrc and its read token in ~/.netrc): built here, in the job's own
# container and image, and IMAGE goes unused. On a Mac: in a container of
# IMAGE leased from its OS Server.
here=""
[ "$(uname -s)" = Linux ] && here=1

host="${OSS_FILES_HOST:-}"
if [ -n "$here" ]; then
    # The job's own OS Server, the first of OSS_SERVERS, by name.
    if [ -z "$host" ]; then
        host="${OSS_SERVERS:-}"
        host="${host%%[ ,]*}"
        host="${host#*://}"
        host="${host%%[:/]*}"
    fi
    [ -n "$host" ] || { echo "container_build: no host for OS Server's files (OSS_SERVERS): set OSS_FILES_HOST" >&2; exit 1; }
else
    # The command line inside OS Server, or on the path.
    OSS="/Applications/OS Server.app/Contents/Helpers/oss"
    [ -x "$OSS" ] || OSS="$(command -v oss)"
    APP="$(cd "$(dirname "$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$OSS")")/../.." && pwd)"

    # `--inside` came in OS Server 0.12.0. An older oss takes it for an
    # option it doesn't know and runs the build on this Mac instead:
    # refused here.
    version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0)"
    if ! python3 -c 'import sys; v = [int(x) for x in sys.argv[1].split(".")[:3]] + [0, 0]; sys.exit(0 if v[:3] >= [0, 12, 0] else 1)' "$version"; then
        echo "container_build: needs OS Server 0.12.0 or later on this Mac (oss machine run --inside); it has $version" >&2
        exit 1
    fi
    if [ -z "$host" ]; then
        host="$(/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
    fi
fi

# MODULE.bazel's placeholders, to this Mac's OS Server.
mkdir -p "$ROOT/.ci"
cat > "$ROOT/.ci/downloader.cfg" <<EOF
rewrite apple-sdks\.invalid/.* http://$host:7490/files/sha256/$SDK_SHA256
rewrite ported-tools\.invalid/sha256/(.*) http://$host:7490/files/sha256/\$1
EOF

# In the container: the apps, then (CI's run) the Mac's own targets, each
# build reading the cache (--cache writes the container's ~/.bazelrc).
steps='
root=$1 full=$2 package=$3; shift 3
cd "$root"
flags="--keep_going --config=apple_on_linux --downloader_config=$root/.ci/downloader.cfg"
echo "::group::The apps"
bazel build $flags "$@"
apps=$?
echo "::endgroup::"
if [ -n "$package" ] && [ $apps -eq 0 ]; then
    # The files of the targets, by cquery with the build options, from
    # the execution root (the bazel-out link names a path in here).
    options=""
    query=""
    for argument in "$@"; do
        case "$argument" in -*) options="$options $argument" ;; *) query="${query:+$query + }$argument" ;; esac
    done
    root_out="$(bazel info $flags $options execution_root)" || exit
    files="$(bazel cquery $flags $options "$query" --output=files 2> /dev/null)" || exit
    # -R: a folder (a web site) too.
    for file in $files; do cp -RL "$root_out/$file" "$package/" || exit; done
    # Writable, by the runner too: Bazel'"'"'s outputs are read-only, and a
    # folder copied so (a web site) kept the next checkout from removing it.
    chmod -R a+rwX "$package" || exit
    ls -l "$package"
fi
[ "$full" = 1 ] || exit $apps
echo "::group::The Mac: libraries, staging server, command-line server, Runner agent"
bazel build $flags --platforms=@apple_support//platforms:macos_arm64 \
    //libraries/... //tools/staging_server //applications/visor_server_mac:visor-server \
    //applications/visor_runner_agent:visor-runner-agent
mac=$?
echo "::endgroup::"
[ $apps -ne 0 ] && exit $apps
exit $mac
'

full=0
if [ $# -eq 0 ]; then
    full=1
    set -- --macos_cpus=arm64 --ios_multi_cpus=sim_arm64 \
        //applications/visor_ios \
        //applications/visor_macos \
        //applications/visor_mac \
        //applications/visor_menubar \
        //applications/visor_client_linux \
        //applications/visor_android:visor_android_apk \
        //tests/visor_server_tests \
        //tests/visor_client_tests \
        //tests/visor_ui_tests \
        //tests/visor_ssh_tests
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
        *) echo "container_build: VISOR_CI_PACKAGE must be a folder in this checkout ($ROOT)" >&2; exit 1 ;;
    esac
    rm -rf "${package:?}"/*
    chmod 777 "$package"
fi

cd "$ROOT"
if [ -n "$here" ]; then
    # And how much memory it took (tools/ci/memory_watch.sh).
    . "$ROOT/tools/ci/memory_watch.sh"
    memory_watch_start
    status=0
    bash -c "$steps" container_build "$ROOT" "$full" "$package" "$@" || status=$?
    memory_watch_report "container_build"
    exit "$status"
fi
exec "$OSS" machine run container --image="$IMAGE" --rosetta --cpus=6 --memory=12 \
    --mount="$ROOT:$ROOT" --volume="$VOLUME:/var/cache/bazel:128:keep" \
    --inside --cache="$host" -- \
    bash -c "$steps" container_build "$ROOT" "$full" "$package" "$@"
