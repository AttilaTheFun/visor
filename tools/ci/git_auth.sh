#!/bin/bash
# Bazel's git fetches of github.com authenticated with the job's own token,
# in a CI job (GitHub's runners alone: nothing without GITHUB_ACTIONS).
# rules_swift_package_manager fetches the Swift packages with Bazel's
# git_worker, anonymously, and GitHub limits anonymous git over HTTPS by
# address, which its hosted Macs share: a release run's proof-ios
# (45973126217) ended at 403s for swift-certificates, grpc-swift-nio-transport
# and isomer.
#
#   tools/ci/git_auth.sh
#
# The token: GH_TOKEN or GITHUB_TOKEN when the step has one, else the one
# actions/checkout keeps in the checkout's git config for the job (a fork's
# pull request's is read-only, which is all a fetch needs). Its header goes
# in a git config of the job's own in RUNNER_TEMP (emptied at the job's
# start and end; mode 600), which includes ~/.gitconfig (job_tools.sh's
# safe.directory). ~/.bazelrc hands that file to repository rules alone
# (--repo_env=GIT_CONFIG_GLOBAL; Bazel's git_worker passes it through), so
# only Bazel's git reads it: the checkout's own git keeps checkout's header
# alone (GitHub answers two Authorization headers with 400), and the job's
# other git commands are as they were. Tried once with `git ls-remote`: a
# token GitHub refuses (401) leaves the fetches anonymous, with a warning,
# rather than failing every one. The token is never traced nor echoed.
#
# Run by tools/ci/job_tools.sh (the Linux jobs), tools/ci/ci_bazel.sh setup
# (every Bazel job) and the proofs' scripts
# (tools/ci/proof_ios.sh, tools/ci/proof_android.sh); again is harmless.
# tools/ci/linux_tests.sh hands the same file to SwiftPM's git
# (GIT_CONFIG_GLOBAL), in its unpacked tree, which is no git repository.
set -euo pipefail
set +x
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
me="git_auth"
if [ "${GITHUB_ACTIONS:-}" != true ]; then
    echo "$me: not a GitHub Actions job: git left as it is"
    exit 0
fi
# Only where the job asks (`VISOR_GIT_AUTH: "1"` in its env): the jobs whose
# token reads alone, and that hold no signing environment. Never alpha-apple
# or release-apple (contents: write), alpha or release (the environment
# `release`), whose Bazel runs third-party Package.swift manifests in
# repository rules, which could read the file (Manager's review of #573).
if [ "${VISOR_GIT_AUTH:-}" != 1 ]; then
    echo "$me: this job doesn't ask for it (VISOR_GIT_AUTH): github.com's git fetches stay anonymous"
    exit 0
fi
dir="${RUNNER_TEMP:?$me: no RUNNER_TEMP}/visor-git"
config="$dir/config"
line="common --repo_env=GIT_CONFIG_GLOBAL=$config"

token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -n "$token" ]; then
    header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
else
    # actions/checkout's: the checkout belongs to the runner's user, not a
    # container's, hence safe.directory.
    header="$(git -c safe.directory='*' -C "$ROOT" config --get http.https://github.com/.extraheader 2> /dev/null || true)"
fi
unset token
if [ -z "$header" ]; then
    echo "$me: no token (GH_TOKEN, GITHUB_TOKEN or the checkout's): github.com's git fetches stay anonymous"
    exit 0
fi

(umask 077 && mkdir -p "$dir")
chmod 700 "$dir"
(umask 077 && : > "$config")
chmod 600 "$config"
{
    printf '[include]\n\tpath = %s\n' "$HOME/.gitconfig"
    printf '[http "https://github.com/"]\n\textraheader = %s\n' "$header"
} >> "$config"
unset header

# Once, outside any repository (a checkout's own header would make two).
if ! (cd "$dir" && GIT_CEILING_DIRECTORIES="$dir" GIT_CONFIG_GLOBAL="$config" GIT_TERMINAL_PROMPT=0 \
        git ls-remote https://github.com/AttilaTheFun/visor.git HEAD > /dev/null 2>&1); then
    rm -f "$config"
    echo "::warning::$me: GitHub refused the job's token for git: github.com's git fetches stay anonymous"
    exit 0
fi
touch "$HOME/.bazelrc"
grep -qxF -- "$line" "$HOME/.bazelrc" || echo "$line" >> "$HOME/.bazelrc"
echo "$me: Bazel's git fetches of github.com authenticated with the job's token ($config, through ~/.bazelrc)"
