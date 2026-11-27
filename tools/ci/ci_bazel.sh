#!/bin/bash
# CI's Bazel settings, on GitHub's own runners alone (nothing of Shireworks
# at run time; Logan, 15 Nov 2026): written before a job's first Bazel
# command, as the checkout's .bazelrc.user (which .bazelrc try-imports), so
# every Bazel the job runs reads them, its scripts' alike. As isomer's
# tools/ci/ci_bazel.sh, for Visor's one module.
#
#   tools/ci/ci_bazel.sh setup [<cache>]   # the settings (<cache>: VISOR_BAZEL_CACHE)
#   tools/ci/ci_bazel.sh trim <cache> <GB> # the disk cache cut to <GB>, before it is saved
#
# setup writes:
# - Bazel's disk cache and repository cache in <cache>/disk and
#   <cache>/repository, outside the checkout (Bazel 9 refuses a repository
#   contents cache inside the main repository), which the workflow keeps in
#   GitHub's cache (.github/actions/bazel_cache), when a cache is named;
# - GitHub's downloads tried at GitHub, then at Bazel's mirror, each
#   retried; Maven Central's (the pinned Maven jars: MODULE.bazel)
#   at Google's mirror of it first, then at Maven Central, whose rate limit
#   (HTTP 429) a cold job's downloads met. Here, not in .bazelrc: Bazel
#   reads one --downloader_config, and this file is CI's;
# - no bazel-* convenience links in the checkout
#   (--experimental_convenience_symlinks=ignore: rules_swift_package_manager
#   copies local packages with `cp -RL`, which follows them into Bazel's
#   output tree);
# - Bazel's tree (--output_user_root) in VISOR_BAZEL_ROOT when it is set and
#   can be made: the x86_64 runner's second disk (/mnt), its first being too
#   small for an Android build's;
# - on a Mac, Xcode 27.2 selected where the image has it (the SDK the proof's
#   pictures and the Mac's tests were made with: tools/ci/proof_ios.sh,
#   tools/ci/mac_tests_run.sh), else the image's default;
# - BuildBuddy's remote cache (.bazelrc's --config=buildbuddy), when
#   BUILDBUDDY_API_KEY is set: the config and the key's headers in a file of
#   the job's own in the home folder, outside the checkout (mode 600), which
#   .bazelrc.user imports by its path; the key never on a command line nor
#   in the log, and unset once written. The workflow hands the key to every
#   job, before a merge and after it, and each reads and writes (Logan,
#   2026-11-23: pull requests write the cache, and outside contributors'
#   runs wait for his approval). The cache the signed builds read is
#   reviewed code's alone: runs on main and a release tag's (the Alphas and
#   the release jobs sign what they build) use BuildBuddy's default
#   instance, and every other run (a pull request's, a branch's) its own,
#   `visor-unreviewed`, so a pull request's scripts can't by mistake put a
#   result where a signed build would take it. main's builds (populate at a push
#   to main, populate-apple nightly) and the alpha and release jobs download
#   every output, so the disk cache GitHub's cache keeps (above) stays whole
#   for the runs without a key. Without a key, nothing of BuildBuddy's.
# Never the Apple targets on Linux (.bazelrc's apple_on_linux, which takes
# Xcode's SDK archive): Apple's SDKs may not be redistributed, so CI builds
# them on GitHub's `xcode-27` Macs with their own Xcode.
# It refuses to replace a .bazelrc.user it didn't write (a builder's own).
#
# trim: Bazel collects its disk cache's garbage only when its server is
# idle, which a CI job's seldom is, so the oldest entries (Bazel touches an
# entry each time it is read) are removed until the cache is under <GB>:
# the caches a workflow keeps share GitHub's 10 GB a repository.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MARK="# tools/ci/ci_bazel.sh's: CI's Bazel settings"
fail() { echo "ci_bazel: $*" >&2; exit 1; }

case "${1:-}" in
setup)
    # github.com's git fetches with the job's own token where the job asks
    # (VISOR_GIT_AUTH: the read-only jobs alone; never a signing job's).
    "$ROOT/tools/ci/git_auth.sh"
    cache="${2:-${VISOR_BAZEL_CACHE:-}}"
    mkdir -p "$ROOT/.ci"
    {
        echo 'rewrite (github\.com/.*) $1'
        echo 'rewrite (github\.com/.*) mirror.bazel.build/$1'
        echo 'rewrite repo1\.maven\.org/maven2/(.*) maven-central.storage-download.googleapis.com/maven2/$1'
        echo 'rewrite repo1\.maven\.org/maven2/(.*) repo1.maven.org/maven2/$1'
    } > "$ROOT/.ci/downloader.cfg"
    lines=("$MARK" "common --downloader_config=$ROOT/.ci/downloader.cfg"
           "common --experimental_repository_downloader_retries=5"
           "common --experimental_convenience_symlinks=ignore")
    if [ -n "${VISOR_BAZEL_ROOT:-}" ]; then
        if mkdir -p "$VISOR_BAZEL_ROOT" 2> /dev/null && [ -w "$VISOR_BAZEL_ROOT" ]; then
            lines+=("startup --output_user_root=$VISOR_BAZEL_ROOT")
        else
            echo "::warning::ci_bazel: $VISOR_BAZEL_ROOT can't be made: Bazel's tree stays in its default place"
        fi
    fi
    if [ "$(uname -s)" = Darwin ] && [ -d /Applications/Xcode_27.2.app ]; then
        sudo -n xcode-select -s /Applications/Xcode_27.2.app/Contents/Developer \
            || echo "::warning::ci_bazel: Xcode 27.2 couldn't be selected: $(xcode-select -p)"
        echo "ci_bazel: $(xcodebuild -version | tr '\n' ' ')"
    fi
    # BuildBuddy, with the key: never traced, never echoed.
    if [ -n "${BUILDBUDDY_API_KEY:-}" ]; then
        set +x
        # Whether this run downloads every output, and whether it is
        # reviewed code's, which alone shares the signed builds' instance
        # (above).
        whole=0
        reviewed=0
        case "${GITHUB_EVENT_NAME:-}:${GITHUB_REF:-}" in
            push:refs/heads/main | release:refs/tags/v*) whole=1 reviewed=1 ;;
            workflow_dispatch:refs/heads/main)
                reviewed=1
                case "${GITHUB_JOB:-}" in alpha | alpha-apple) whole=1 ;; esac ;;
        esac
        secret_dir="$HOME/.config/visor-ci"
        (umask 077 && mkdir -p "$secret_dir")
        chmod 700 "$secret_dir"
        secret_rc="$secret_dir/buildbuddy.bazelrc"
        (umask 077 && : > "$secret_rc")
        chmod 600 "$secret_rc"
        {
            echo "common --config=buildbuddy"
            printf 'common --remote_header=x-buildbuddy-api-key=%s\n' "$BUILDBUDDY_API_KEY"
            printf 'common --bes_header=x-buildbuddy-api-key=%s\n' "$BUILDBUDDY_API_KEY"
            if [ $reviewed -eq 0 ]; then echo "common --remote_instance_name=visor-unreviewed"; fi
            if [ $whole -eq 1 ]; then echo "common --remote_download_all"; fi
        } >> "$secret_rc"
        unset BUILDBUDDY_API_KEY
        lines+=("try-import $secret_rc")
        if [ $reviewed -eq 1 ]; then
            echo "ci_bazel: BuildBuddy's remote cache, read and written (${GITHUB_EVENT_NAME:-}, ${GITHUB_REF:-}, ${GITHUB_JOB:-})"
        else
            echo "ci_bazel: BuildBuddy's remote cache, read and written in visor-unreviewed (${GITHUB_EVENT_NAME:-}, ${GITHUB_REF:-}, ${GITHUB_JOB:-})"
        fi
    else
        echo "ci_bazel: no BUILDBUDDY_API_KEY: no remote cache, GitHub's cache alone"
    fi
    if [ -n "$cache" ]; then
        mkdir -p "$cache/disk" "$cache/repository"
        cache="$(cd "$cache" && pwd)"
        case "$cache/" in
            "$ROOT"/*) fail "the cache ($cache) is in the checkout: Bazel 9 refuses a repository contents cache there" ;;
        esac
        lines+=("common --disk_cache=$cache/disk" "common --repository_cache=$cache/repository")
    fi
    rc="$ROOT/.bazelrc.user"
    if [ -e "$rc" ] && ! head -1 "$rc" | grep -qxF "$MARK"; then
        fail "$rc is a builder's own: not replaced"
    fi
    printf '%s\n' "${lines[@]}" > "$rc"
    echo "ci_bazel: Bazel's settings written ($rc):"
    sed 's/^/  /' "$rc"
    ;;
trim)
    cache="${2:?usage: ci_bazel.sh trim <cache> <GB>}"
    gb="${3:?usage: ci_bazel.sh trim <cache> <GB>}"
    [[ "$gb" =~ ^[0-9]+$ ]] || fail "<GB> is a whole number of gigabytes"
    [ -d "$cache/disk" ] || { echo "ci_bazel: no disk cache in $cache"; exit 0; }
    # Every entry's time and size, the newest first; what is past the
    # limit, counted from the newest, goes. python3: find's -printf is
    # GNU's alone, and a Mac's runner trims too.
    python3 -I - "$cache/disk" "$((gb * 1024 * 1024 * 1024))" << 'PY'
import os, sys
root, limit = sys.argv[1], int(sys.argv[2])
entries = []
for folder, _, names in os.walk(root):
    for name in names:
        path = os.path.join(folder, name)
        try:
            stat = os.lstat(path)
        except OSError:
            continue
        entries.append((stat.st_mtime, stat.st_size, path))
entries.sort(reverse=True)
kept = removed = 0
for _, size, path in entries:
    if kept + size <= limit:
        kept += size
    else:
        os.remove(path)
        removed += size
print(f"ci_bazel: the disk cache is {kept / 2**30:.2f} GB ({removed / 2**30:.2f} GB of its oldest entries removed)")
PY
    ;;
*)
    echo "usage: tools/ci/ci_bazel.sh setup [<cache>] | trim <cache> <GB>" >&2
    exit 2
    ;;
esac
