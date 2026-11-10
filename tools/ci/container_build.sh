#!/bin/bash
# CI's build of the apps in a Linux container (the Apple apps, the Linux
# client and blue Visor's Android APK, arm64): the job's own (CI's
# visor-jit, a container Shireworks makes for each job, side by side with
# the others). The Apple apps take Xcode 27.2's SDK archive and
# rules_applecross's ported tools from Shireworks' files (by SHA-256, with
# its cache's read token) through a downloader config written here, at the
# address Shireworks' API gives (tools/ci/shireworks.sh files-url), and its
# Bazel reads Shireworks' cache: no host is named in the repository. Run
# with `bazel run //tools/ci:container_build`. Not on a Mac: Shireworks
# runs nothing in a container from one (no mounts, no volumes), so lease a
# container of the agent image and run it there.
#
#   bazel run //tools/ci:container_build -- <image> [<bazel build args>…]
#
# <image> is the agent image the job's runner is (CI says it; unused here).
set -euo pipefail
ROOT="${BUILD_WORKSPACE_DIRECTORY:-$(cd "$(dirname "$0")/../.." && pwd)}"
IMAGE="${1:?the agent image, ghcr.io/attilathefun/visor-agent:<version>}"
shift
SDK_SHA256="b1583e60f9fd35881b5a948ce71627079877f1ced7ea231e14d3c342dd389668"

# In a Linux container (CI's visor-jit: Shireworks' cache in its
# ~/.bazelrc and its read token in ~/.netrc): built here, in the job's own
# container and image.
if [ "$(uname -s)" != Linux ]; then
    echo "container_build: runs in a Linux container (CI's visor-jit, or a Shireworks container lease of the agent image): Shireworks has no way to run it in one from a Mac" >&2
    exit 2
fi
# Shireworks' files, at the address its API gives (tools/ci/shireworks.sh,
# copied from AttilaTheFun/shireworks, with the job's SHIREWORKS_GRANT or
# SHIREWORKS_SERVERS): every file's, by its SHA-256 after this.
files="$(sh "$ROOT/tools/ci/shireworks.sh" files-url "$SDK_SHA256")" \
    || { echo "container_build: Shireworks didn't say where its files are (SHIREWORKS_GRANT or SHIREWORKS_SERVERS)" >&2; exit 1; }
files="${files%"$SDK_SHA256"}"

# MODULE.bazel's placeholders, to Shireworks' files.
mkdir -p "$ROOT/.ci"
cat > "$ROOT/.ci/downloader.cfg" <<EOF
rewrite apple-sdks\.invalid/.* $files$SDK_SHA256
rewrite ported-tools\.invalid/sha256/(.*) $files\$1
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
# And how much memory it took (tools/ci/memory_watch.sh).
. "$ROOT/tools/ci/memory_watch.sh"
memory_watch_start
status=0
bash -c "$steps" container_build "$ROOT" "$full" "$package" "$@" || status=$?
memory_watch_report "container_build"
exit "$status"
