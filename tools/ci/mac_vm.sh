#!/bin/bash
# One CI step on a macOS VM leased from Nimbus, for a job on a Nimbus runner
# (`[self-hosted, visor-ci]`, a Linux container): what needs macOS itself
# (the Mac's tests run, the proofs, the launch checks of a signed Mac app,
# the proposal's and the release's Xcode builds) now that no job runs on
# GitHub's paid `xcode-27` runners (Logan, 27 Nov 2026). As Nimbus' own CI
# does it (AttilaTheFun/nimbus, tools/ci/mac_vm.sh): the VM leased with a
# key of the step's own (`nimbus job lease macos --config=xcode_27_2`,
# which waits for room: there are two such VMs, shared), reached over the
# lease's ssh, renewed every ten minutes while the step runs, and released
# however it ends (Nimbus releases it too when the runner's container
# ends). The VM is the step's alone and holds nothing the step didn't put
# there: no secret ever goes in (the job's token included), and what comes
# out is unsigned or already signed, never signed there.
#
#   tools/ci/mac_vm.sh [--tree] [--put <path>]… [--env <name>]… [--desktop]
#       [--get <path>]… [--out <dir>] [--minutes <n>] -- <command>
#
# --tree     the checkout as it stands into ~/w (`git stash create`: the
#            committed tree with the job's changes, a Version step's stamps
#            among them; untracked files stay behind)
# --put      a file or folder of the runner's into ~/w, under its own name
# --env      the runner's <name>=<value> given to the command (a setting,
#            never a secret)
# --desktop  the command in the VM's desktop session (`launchctl asuser`:
#            `open`, windows, Launch Services), as a GitHub Mac runner's
#            steps are
# --get      ~/w/<path> copied back into --out (default: .), whatever the
#            command's status: logs, parts of the proof, unsigned builds
# --minutes  the lease's first stretch (60; renewed while the step runs)
#
# The command runs in ~/w with `zsh -lc` (the VM's Homebrew, bazelisk among
# it; Xcode 27.2, its iOS simulators; Bazel reads Nimbus' cache, as every
# lease's does), and the step's status is its. A shell wrapper around
# `nimbus job` and ssh, as Nimbus' own: the port to Swift is Nimbus' `sw`
# (`nimbus job …`, AGENTS.md: Nimbus-only tooling goes into `sw`), not a
# tool of this repository's.
set -euo pipefail
me="$(basename "$0")"
usage="usage: tools/ci/mac_vm.sh [--tree] [--put <path>]… [--env <name>]… [--desktop] [--get <path>]… [--out <dir>] [--minutes <n>] -- <command>"
fail() { echo "$me: $*" >&2; exit 2; }
NIMBUS="${NIMBUS:-/opt/nimbus/bin/nimbus}"

tree="" desktop="" out="." minutes=60
puts=() gets=() envs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --tree) tree=1; shift ;;
        --desktop) desktop=1; shift ;;
        --put) [ -e "${2:-}" ] || fail "--put: no such file or folder: ${2:-}"; puts+=("$2"); shift 2 ;;
        --get) [ -n "${2:-}" ] || fail "--get takes a path in ~/w"; gets+=("$2"); shift 2 ;;
        --env) [[ "${2:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "--env takes a variable's name"; envs+=("$2"); shift 2 ;;
        --out) out="${2:?--out takes a folder}"; shift 2 ;;
        --minutes) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || fail "--minutes takes a whole number"; minutes="$2"; shift 2 ;;
        --) shift; break ;;
        *) fail "$usage" ;;
    esac
done
[ $# -gt 0 ] || fail "$usage"
command="$*"
[ -x "$NIMBUS" ] || fail "no $NIMBUS: this runs on a Nimbus runner"

work="$(mktemp -d)"
chmod 700 "$work"
lease="" renewer="" child=""
release() {
    if [ -n "$renewer" ]; then kill "$renewer" 2> /dev/null || true; wait "$renewer" 2> /dev/null || true; renewer=""; fi
    if [ -n "$lease" ]; then
        "$NIMBUS" job release "$lease" || echo "::warning::$me: lease $lease wasn't released (Nimbus releases it with the runner)"
        lease=""
    fi
}
cleanup() {
    local status=$?
    [ -z "$child" ] || kill "$child" 2> /dev/null || true
    release
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Long commands in the background, waited for, so the runner's cancel
# reaches the trap at once and the VM goes back.
run() {
    "$@" &
    child=$!
    local status=0
    wait "$child" || status=$?
    child=""
    return "$status"
}

echo "::group::A macOS VM (xcode_27_2)"
ssh-keygen -q -t ed25519 -N '' -C "${GITHUB_REPOSITORY:-ci} ${GITHUB_JOB:-step}" -f "$work/key"
run "$NIMBUS" job lease macos --config=xcode_27_2 --minutes="$minutes" --key="$work/key.pub" \
    --label="${GITHUB_REPOSITORY:-ci} ${GITHUB_JOB:-step}" > "$work/lease"
# shellcheck disable=SC1091 # the lease's exports
lease="$(. "$work/lease"; printf '%s' "${NIMBUS_ID:-}")"
[ -n "$lease" ] || { echo "$me: the lease said no id" >&2; exit 1; }
host="$(. "$work/lease"; printf '%s' "$NIMBUS_HOST")"
port="$(. "$work/lease"; printf '%s' "$NIMBUS_SSH_PORT")"
user="$(. "$work/lease"; printf '%s' "${NIMBUS_SSH_USER:-runner}")"
echo "Leased $lease ($user@$host:$port)"
(
    trap 'kill $! 2> /dev/null; exit 0' TERM
    # While this script runs alone: one killed past its trap leaves the loop.
    while kill -0 "$$" 2> /dev/null; do
        sleep 600 &
        wait $!
        kill -0 "$$" 2> /dev/null || break
        "$NIMBUS" job renew "$lease" --minutes=60 > /dev/null || true
    done
) &
renewer=$!
vm() {
    ssh -p "$port" -i "$work/key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$work/known_hosts" -o ServerAliveInterval=30 "$user@$host" "$@"
}
for _ in $(seq 1 60); do vm true 2> /dev/null && break; sleep 5; done
vm 'sw_vers -productVersion | sed "s/^/macOS /"; xcodebuild -version | head -1; rm -rf ~/w && mkdir ~/w'
echo "::endgroup::"

echo "::group::Into the VM"
if [ -n "$tree" ]; then
    stash="$(git -c user.name=CI -c user.email=ci@localhost stash create)"
    git archive --format=tar "${stash:-HEAD}" | vm 'tar -xf - -C ~/w'
    echo "the checkout, $(git rev-parse --short HEAD)${stash:+, with what the job changed}"
fi
for path in "${puts[@]+"${puts[@]}"}"; do
    tar -chf - -C "$(dirname "$path")" "$(basename "$path")" | vm 'tar -xf - -C ~/w'
    echo "$(basename "$path")"
done
echo "::endgroup::"

# The command, each --env set before it, quoted for the VM's zsh.
script=""
for name in "${envs[@]+"${envs[@]}"}"; do
    [ -n "${!name+set}" ] || continue
    script+="export $name=$(printf '%q' "${!name}"); "
done
script+="cd ~/w && $command"
if [ -n "$desktop" ]; then
    remote="sudo launchctl asuser \"\$(id -u)\" sudo -u \"\$(id -un)\" zsh -lc $(printf '%q' "$script")"
else
    remote="zsh -lc $(printf '%q' "$script")"
fi
status=0
run vm "$remote" || status=$?

if [ ${#gets[@]} -gt 0 ]; then
    echo "::group::Out of the VM"
    mkdir -p "$out"
    for path in "${gets[@]}"; do
        vm "cd ~/w && [ -e $(printf '%q' "$path") ] && tar -chf - $(printf '%q' "$path")" | tar -xf - -C "$out" \
            && echo "$path" || echo "::warning::$me: no $path in the VM"
    done
    echo "::endgroup::"
fi
release
exit "$status"
