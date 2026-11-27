#!/bin/bash
# What a CI job's Linux container needs beyond its image, installed when
# missing (as isomer's tools/ci/job_tools.sh): Swift's own image (by digest,
# on GitHub's x86_64 Ubuntu: Google's Android SDK and NDK tools are x86_64,
# and GitHub's arm runners have no Rosetta to run them) has Swift and clang,
# and is given Bazel (Bazelisk, pinned by SHA-256, honouring
# .bazelversion), git, Python, zip, zstd and the rest the scripts call, and
# what the Linux client links, as Visor's agent image has it
# (tools/containers/visor-agent/Dockerfile): SDL2 and SDL2_ttf, GL and EGL,
# GTK 3 and WebKitGTK, curl, SQLite, lld. Its C and C++ compiled with clang,
# as in that image (CC and CXX, for the job's later steps). As root, or by
# sudo.
#
#   tools/ci/job_tools.sh
set -euo pipefail
root_do() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
BAZELISK_VERSION=v1.30.0
case "$(uname -m)" in
    x86_64) bazelisk=bazelisk-linux-amd64 sha=a248ae2b2b62b5baebb748f6fba7203bff1a27e5d01b55399a8406744cb539e8 ;;
    aarch64) bazelisk=bazelisk-linux-arm64 sha=b2bcc040c213b44586b121bda6d983c35df121b917c3a7a66fb16f2fa0df1a4f ;;
    *) echo "job_tools: no Bazelisk pinned for $(uname -m)" >&2; exit 1 ;;
esac

# Each command, by the package that has it.
wanted=(git:git curl:curl python3:python3 unzip:unzip zip:zip zstd:zstd xz:xz-utils openssl:openssl
        file:file gzip:gzip sha256sum:coreutils sudo:sudo clang:clang ld.lld:lld)
packages=(ca-certificates)
for pair in "${wanted[@]}"; do
    command -v "${pair%%:*}" > /dev/null || packages+=("${pair#*:}")
done
# The Linux client's libraries (Isomer's linux/libraries/swift_ui), by pkg-config.
if ! { command -v pkg-config > /dev/null && pkg-config --exists sdl2 SDL2_ttf gl egl gtk+-3.0 webkit2gtk-4.1 libcurl sqlite3; }; then
    packages+=(pkg-config libsdl2-dev libsdl2-ttf-dev libgl-dev libegl-dev libglvnd-dev libgtk-3-dev
               libwebkit2gtk-4.1-dev libcurl4-openssl-dev libsqlite3-dev libnss3)
fi
# Asked again, after a fresh index, when a mirror answers 404 for a package
# the index named a moment before: Ubuntu's security pocket replaces a
# package while a job installs it (libtiff, 26 Nov 2026: the release run's
# linux job ended at exit 100). Three tries: 20 s, then 40 s between them.
if [ ${#packages[@]} -gt 1 ]; then
    for try in 1 2 3; do
        root_do apt-get update -qq > /dev/null
        if root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${packages[@]}" > /dev/null; then
            break
        fi
        [ "$try" = 3 ] && { echo "job_tools: the packages couldn't be installed after three tries" >&2; exit 1; }
        echo "job_tools: apt-get install failed (try $try): the index again in $((try * 20)) s" >&2
        sleep $((try * 20))
    done
fi
if ! command -v bazel > /dev/null; then
    work="$(mktemp -d)"
    curl -fsSL --retry 3 -o "$work/bazel" "https://github.com/bazelbuild/bazelisk/releases/download/$BAZELISK_VERSION/$bazelisk"
    echo "$sha  $work/bazel" | sha256sum -c --quiet - || { echo "job_tools: Bazelisk isn't the pinned $sha" >&2; exit 1; }
    root_do install -m 755 "$work/bazel" /usr/local/bin/bazel
    rm -rf "$work"
fi
# clang for C and C++, in this step and the job's next ones.
if [ -z "${CC:-}" ] && [ -n "${GITHUB_ENV:-}" ]; then
    printf 'CC=clang\nCXX=clang++\n' >> "$GITHUB_ENV"
fi
# The checkout belongs to the runner's user, not the container's.
git config --global --add safe.directory "${GITHUB_WORKSPACE:-$PWD}"
# Bazel's git fetches of github.com with the job's token (GitHub's
# anonymous limit is by address).
"$(dirname "$0")/git_auth.sh"
echo "job_tools: $(bazel --version 2> /dev/null || echo bazel), $(swift --version 2>&1 | head -1), $(git --version), $(uname -m)"
# The room Bazel has: its tree and its caches (the x86_64 runner's second
# disk at /mnt, where the job mounts it).
df -h / /mnt 2> /dev/null || df -h /
