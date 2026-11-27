#!/bin/bash
# CI's steps on a macOS VM leased from Nimbus, for a job on a Nimbus runner
# (`[self-hosted, visor-ci]`, a Linux container): what needs macOS itself
# (the Mac's tests run, the proofs, the launch checks of a signed Mac app,
# the site's pictures) now that no job runs on GitHub's paid `xcode-27`
# runners (Logan, 27 Nov 2026). As Nimbus' own CI does it
# (AttilaTheFun/nimbus, tools/ci/mac_vm.sh): the VM leased with a key of
# the job's own (`nimbus job lease macos --config=xcode_27_2`, which waits
# for room: there are two such VMs, shared, so a run leases one), reached
# over the lease's ssh, renewed every ten minutes, and released when the
# job says or however the one-shot form ends (Nimbus releases it too when
# the runner's container ends). The VM holds nothing the job didn't put
# there: no secret ever goes in (the job's token included), and what comes
# out is unsigned or already signed, never signed there.
#
# A job's steps, one VM for them all (its state in MAC_VM_STATE, default
# $RUNNER_TEMP/mac-vm):
#
#   tools/ci/mac_vm.sh lease [--minutes <n>]   # leased, ssh up, renewed from now on
#   tools/ci/mac_vm.sh tree                    # the checkout as it stands into ~/w
#   tools/ci/mac_vm.sh put <path>…             # files or folders into ~/w, by name
#   tools/ci/mac_vm.sh run [--desktop] [--env <name>]… [--shots <dir>] -- <command>
#   tools/ci/mac_vm.sh get <path> <dir>        # ~/w/<path> into <dir>
#   tools/ci/mac_vm.sh release                 # given back now (a step `if: always()`)
#
# Or one step, leased and released around it:
#
#   tools/ci/mac_vm.sh [--tree] [--put <path>]… [--env <name>]… [--desktop]
#       [--shots <dir>] [--get <path>]… [--out <dir>] [--minutes <n>] -- <command>
#
# tree       `git stash create`'s tree (the committed one with the job's
#            changes, a Version step's stamps among them; untracked files
#            stay behind)
# --env      the runner's <name>=<value> given to the command (a setting,
#            never a secret)
# --desktop  the command in the VM's desktop session (`launchctl asuser`:
#            `open`, windows, Launch Services), as a GitHub Mac runner's
#            steps are
# --shots    while the command runs, each ~/w/<dir>/<name>.want it leaves
#            is answered with ~/w/<dir>/<name>.png: the VM's whole screen
#            from Nimbus' framebuffer (`nimbus job screenshot`), for a
#            command that may not picture the screen itself (Screen
#            Recording, which the VMs aren't given yet: proof_mac.sh's
#            VISOR_PROOF_SHOT=framebuffer)
# --get      (one step) ~/w/<path> into --out (default .), whatever the
#            command's status: logs, parts of the proof, unsigned builds
#
# A command runs in ~/w with `zsh -lc` (the VM's Homebrew, bazelisk among
# it; Xcode 27.2, its iOS simulators; Bazel reads Nimbus' cache, as every
# lease's does), and its status is the step's. A shell wrapper around
# `nimbus job` and ssh, as Nimbus' own: its Swift port belongs in Nimbus'
# `sw` (`nimbus job …`; AGENTS.md: Nimbus-only tooling goes into `sw`), not
# in each repository.
set -euo pipefail
me="$(basename "$0")"
NIMBUS="${NIMBUS:-/opt/nimbus/bin/nimbus}"
STATE="${MAC_VM_STATE:-${RUNNER_TEMP:-/tmp}/mac-vm}"
fail() { echo "$me: $*" >&2; exit 2; }
child=""

# Long commands in the background, waited for, so the runner's cancel
# reaches the trap at once.
run_waited() {
    "$@" &
    child=$!
    local status=0
    wait "$child" || status=$?
    child=""
    return "$status"
}

lease_vm() {
    local minutes="$1"
    [ -x "$NIMBUS" ] || fail "no $NIMBUS: this runs on a Nimbus runner"
    [ ! -s "$STATE/lease" ] || fail "a VM is leased already ($STATE): release it first"
    mkdir -p "$STATE"
    chmod 700 "$STATE"
    echo "::group::A macOS VM (xcode_27_2)"
    ssh-keygen -q -t ed25519 -N '' -C "${GITHUB_REPOSITORY:-ci} ${GITHUB_JOB:-step}" -f "$STATE/key" <<< y > /dev/null
    run_waited "$NIMBUS" job lease macos --config=xcode_27_2 --minutes="$minutes" --key="$STATE/key.pub" \
        --label="${GITHUB_REPOSITORY:-ci} ${GITHUB_JOB:-step}" > "$STATE/lease.new"
    mv "$STATE/lease.new" "$STATE/lease"
    load
    [ -n "$id" ] || { echo "$me: the lease said no id" >&2; exit 1; }
    echo "Leased $id ($user@$host:$port)"
    # Renewed every ten minutes until released; detached, so it outlives
    # this step and none of the job's later ones waits for it.
    (
        trap 'kill $! 2> /dev/null; exit 0' TERM
        while [ -s "$STATE/lease" ]; do
            sleep 600 &
            wait $!
            [ -s "$STATE/lease" ] || break
            "$NIMBUS" job renew "$id" --minutes=60 > /dev/null || true
        done
    ) > /dev/null 2>&1 < /dev/null &
    echo $! > "$STATE/renewer"
    for _ in $(seq 1 60); do vm true 2> /dev/null && break; sleep 5; done
    vm 'sw_vers -productVersion | sed "s/^/macOS /"; xcodebuild -version | head -1; rm -rf ~/w && mkdir ~/w'
    echo "::endgroup::"
}

load() {
    [ -s "$STATE/lease" ] || fail "no VM leased ($STATE): tools/ci/mac_vm.sh lease first"
    # shellcheck disable=SC1091 # the lease's exports
    id="$(. "$STATE/lease"; printf '%s' "${NIMBUS_ID:-}")"
    host="$(. "$STATE/lease"; printf '%s' "${NIMBUS_HOST:-}")"
    port="$(. "$STATE/lease"; printf '%s' "${NIMBUS_SSH_PORT:-}")"
    user="$(. "$STATE/lease"; printf '%s' "${NIMBUS_SSH_USER:-runner}")"
}

release_vm() {
    [ -s "$STATE/lease" ] || return 0
    load
    if [ -s "$STATE/renewer" ]; then kill "$(cat "$STATE/renewer")" 2> /dev/null || true; fi
    "$NIMBUS" job release "$id" || echo "::warning::$me: lease $id wasn't released (Nimbus releases it with the runner)"
    rm -rf "$STATE"
}

vm() {
    ssh -p "$port" -i "$STATE/key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$STATE/known_hosts" -o ServerAliveInterval=30 "$user@$host" "$@"
}

put_tree() {
    local stash
    stash="$(git -c user.name=CI -c user.email=ci@localhost stash create)"
    git archive --format=tar "${stash:-HEAD}" | vm 'tar -xf - -C ~/w'
    echo "into the VM: the checkout, $(git rev-parse --short HEAD)${stash:+, with what the job changed}"
}

put_paths() {
    local path
    for path in "$@"; do
        [ -e "$path" ] || fail "no such file or folder: $path"
        tar -chf - -C "$(dirname "$path")" "$(basename "$path")" | vm 'tar -xf - -C ~/w'
        echo "into the VM: $(basename "$path")"
    done
}

get_path() {
    local path="$1" into="$2"
    mkdir -p "$into"
    if vm "cd ~/w && [ -e $(printf '%q' "$path") ] && tar -chf - $(printf '%q' "$path")" | tar -xf - -C "$into"; then
        echo "out of the VM: $path"
    else
        echo "::warning::$me: no $path in the VM"
    fi
}

# Each <name>.want in ~/w/<dir> answered with the VM's whole screen, as
# <name>.png beside it, until the command ends.
serve_shots() {
    local dir="$1" name
    while true; do
        for name in $(vm "find ~/w/$(printf '%q' "$dir") -maxdepth 1 -name '*.want' -exec basename {} .want \\;" 2> /dev/null || true); do
            [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || continue
            if "$NIMBUS" job screenshot "$id" "$STATE/shot.png" > /dev/null; then
                vm "cat > ~/w/$(printf '%q' "$dir")/$name.png.part && mv ~/w/$(printf '%q' "$dir")/$name.png.part ~/w/$(printf '%q' "$dir")/$name.png && rm -f ~/w/$(printf '%q' "$dir")/$name.want" < "$STATE/shot.png"
            fi
        done
        sleep 2
    done
}

# The command in ~/w, each --env set before it, quoted for the VM's zsh.
run_command() {
    local desktop="$1" shots="$2"
    shift 2
    local -a names=()
    while [ "${1:-}" != -- ]; do names+=("$1"); shift; done
    shift
    local script="" name remote status=0 server=""
    for name in "${names[@]+"${names[@]}"}"; do
        [ -n "${!name+set}" ] || continue
        script+="export $name=$(printf '%q' "${!name}"); "
    done
    script+="cd ~/w && $*"
    if [ -n "$desktop" ]; then
        remote="sudo launchctl asuser \"\$(id -u)\" sudo -u \"\$(id -un)\" zsh -lc $(printf '%q' "$script")"
    else
        remote="zsh -lc $(printf '%q' "$script")"
    fi
    if [ -n "$shots" ]; then
        vm "mkdir -p ~/w/$(printf '%q' "$shots")"
        serve_shots "$shots" &
        server=$!
    fi
    run_waited vm "$remote" || status=$?
    [ -z "$server" ] || { kill "$server" 2> /dev/null || true; wait "$server" 2> /dev/null || true; }
    return "$status"
}

# Options shared by `run` and the one-step form; the rest stays in rest[].
desktop="" shots="" envs=() rest=()
parse_run_options() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --desktop) desktop=1; shift ;;
            --shots) [[ "${2:-}" =~ ^[A-Za-z0-9._/-]+$ ]] || fail "--shots takes a folder in ~/w"; shots="$2"; shift 2 ;;
            --env) [[ "${2:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "--env takes a variable's name"; envs+=("$2"); shift 2 ;;
            --) rest+=("$@"); break ;;
            *) rest+=("$1"); shift ;;
        esac
    done
}

trap '[ -z "$child" ] || kill "$child" 2> /dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

case "${1:-}" in
    lease)
        shift
        minutes=60
        [ "${1:-}" != --minutes ] || { [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || fail "--minutes takes a whole number"; minutes="$2"; }
        lease_vm "$minutes"
        ;;
    tree) load; put_tree ;;
    put) shift; load; put_paths "$@" ;;
    get) [ $# -eq 3 ] || fail "usage: tools/ci/mac_vm.sh get <path> <dir>"; load; get_path "$2" "$3" ;;
    release) release_vm ;;
    run)
        shift
        parse_run_options "$@"
        [ "${rest[0]:-}" = -- ] && [ ${#rest[@]} -gt 1 ] || fail "usage: tools/ci/mac_vm.sh run [--desktop] [--env <name>]… [--shots <dir>] -- <command>"
        load
        run_command "$desktop" "$shots" "${envs[@]+"${envs[@]}"}" "${rest[@]}"
        ;;
    *)
        # One step: leased, run and released.
        tree="" out="." minutes=60 puts=() gets=() args=()
        while [ $# -gt 0 ]; do
            case "$1" in
                --tree) tree=1; shift ;;
                --put) puts+=("${2:?--put takes a path}"); shift 2 ;;
                --get) gets+=("${2:?--get takes a path in ~/w}"); shift 2 ;;
                --out) out="${2:?--out takes a folder}"; shift 2 ;;
                --minutes) [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || fail "--minutes takes a whole number"; minutes="$2"; shift 2 ;;
                --) args+=("$@"); break ;;
                *) args+=("$1"); shift ;;
            esac
        done
        parse_run_options "${args[@]+"${args[@]}"}"
        [ "${rest[0]:-}" = -- ] && [ ${#rest[@]} -gt 1 ] || fail "usage: see the header of tools/ci/mac_vm.sh"
        trap '[ -z "$child" ] || kill "$child" 2> /dev/null || true; release_vm' EXIT
        lease_vm "$minutes"
        [ -z "$tree" ] || put_tree
        put_paths "${puts[@]+"${puts[@]}"}"
        status=0
        run_command "$desktop" "$shots" "${envs[@]+"${envs[@]}"}" "${rest[@]}" || status=$?
        for path in "${gets[@]+"${gets[@]}"}"; do get_path "$path" "$out"; done
        exit "$status"
        ;;
esac
