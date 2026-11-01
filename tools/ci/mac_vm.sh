#!/bin/bash
# A macOS VM leased from OS Server (xcode-27.0: Xcode 27.0 and its iOS
# simulator) for one CI script, which sources this file rather than run it:
# tools/ci/mac_vm_tests.sh (the tests that need a Mac), tools/ci/mac_vm_proof.sh
# (main's proof) and tools/ci/mac_vm_screenshots.sh (the site's pictures). The VM is the script's alone: leased for an hour,
# renewed while it runs, released however it ends (a kill nothing can trap
# leaves it an hour at most). The checkout's tree goes in with the runner's
# bazelisk; Bazel there reads OS Server's cache, as every lease's does.
# As oss's tools/ci/mac_vm.sh, with Visor's folder, node where a script asks
# for it (the VM image has none) and what comes back out.
#
#   ROOT=<the checkout>
#   . "$ROOT/tools/ci/mac_vm.sh"
#   mac_vm_start <key comment>  the script's folder, $work, and the trap that
#                               releases the VM and deletes $work however
#                               the script ends (after on_cleanup, if the
#                               script defines one: its other leases)
#   mac_vm_steps << 'EOF'       the script's steps in the VM: arms of a
#       <step>) … ;;            `case` on the step's name, run by /bin/bash
#   EOF                         (3.2) in ~/ci, the tree in visor/, Bazel
#                               (and node) on the PATH, the step's arguments
#                               in "$@"
#   mac_vm_node                 node too (NODE_VERSION below, checked by its
#                               SHA-256; kept between runs on the runner)
#   mac_vm_lease                the VM leased and reached over SSH
#   mac_vm_copy_tree            the tree, Bazel and the steps copied in
#   in_vm <step> [args…]        one of the steps, in the VM
#   mac_vm_fetch <in ~/ci> <here>  a file or folder of the VM's, copied out
#   vm <command…>               a command in the VM, over SSH
#   run <command…>              a long command, in the background, waited for
#   mac_vm_release              the VM given back now, before the script ends
#
# $OSS is OS Server's command line, $lease the VM's id, $work/key its SSH
# key. A script sets finished=1 before its last exit: macOS's bash (3.2)
# runs the EXIT trap with $? 0 when an unset variable stops the script
# (set -eu), so an end before that is a failure, whatever it says.

OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss)"
NODE_VERSION="v22.23.4"
NODE_SHA256="c9e1dbc748b33ed2d14f42445191ecaf14c56259c7a9a26d0042c49ec2b66428"

mac_vm_start() {
    me="$(basename "$0")"
    bazelisk="$(command -v bazelisk)" || { echo "$me: no bazelisk on the PATH to copy in" >&2; exit 1; }
    key_comment="${1:?mac_vm_start takes a comment for the SSH key}"
    work="$(mktemp -d)"
    chmod 700 "$work"
    mkdir "$work/vm"
    lease=""
    renewer=""
    child=""
    finished=""
    trap mac_vm_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# The VM given back now, not left to its hour.
mac_vm_release() {
    if [ -n "$renewer" ]; then
        kill "$renewer" 2> /dev/null || true
        wait "$renewer" 2> /dev/null || true
        renewer=""
    fi
    # A lease asked for as the script was stopped: its id, if it came.
    [ -n "$lease" ] || lease="$(. "$work/lease" 2> /dev/null; printf '%s' "${OSS_ID:-}")"
    if [ -n "$lease" ]; then
        "$OSS" machine release "$lease" || echo "$me: lease $lease was not released: oss machine release $lease" >&2
        lease=""
        rm -f "$work/lease"
    fi
}

mac_vm_cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    [ -z "$child" ] || kill "$child" 2> /dev/null || true
    # The script's own, first: its other leases, its SSH agent.
    ! type on_cleanup > /dev/null 2>&1 || on_cleanup || true
    mac_vm_release
    rm -rf "$work"
    exit "$status"
}

# Long commands run in the background and are waited for, so a signal (the
# runner cancelling the job) reaches the trap at once, not when they end.
run() {
    "$@" &
    child=$!
    local status=0
    wait "$child" || status=$?
    child=""
    return "$status"
}
vm() { "$OSS" machine ssh "$lease" --identity="$work/key" -- "$@"; }
# ssh hands the VM's shell one line, so each argument is quoted for it.
in_vm() { vm bash ci/in_vm.sh "$(printf '%q ' "$@")"; }

mac_vm_steps() {
    {
        cat << 'EOF'
#!/bin/bash
# In the VM, in ~/ci: the tree in visor/, Bazel in bin/, node in node/ where
# the script brought it (tools/ci/mac_vm.sh).
set -uo pipefail
cd ~/ci
# Homebrew last: the layer's.
export PATH="$HOME/ci/bin:$HOME/ci/node/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
step="$1"
shift
case "$step" in
    unpack)
        mkdir -p visor bin && tar -xzf tree.tar.gz -C visor && mv bazel bin/bazel && chmod +x bin/bazel || exit
        if [ -f node.tar.gz ]; then mkdir -p node && tar -xzf node.tar.gz -C node --strip-components 1 && node --version || exit; fi
        xcodebuild -version | head -1
        xcrun simctl list runtimes | grep -i '^ios'
        ;;
EOF
        cat
        cat << 'EOF'
    *)
        echo "in_vm.sh: no step $step" >&2
        exit 2
        ;;
esac
EOF
    } > "$work/vm/in_vm.sh"
}

mac_vm_lease() {
    # A key of the run's own for the VM's SSH, gone with the run.
    ssh-keygen -q -t ed25519 -N '' -C "$key_comment" -f "$work/key"
    run "$OSS" machine lease macos --config=xcode-27.0 --minutes=60 --wait --key="$work/key.pub" --exports > "$work/lease"
    lease="$(. "$work/lease"; printf '%s' "$OSS_ID")"
    echo "Leased $lease"
    # Renewed every ten minutes; told to stop, it stops its sleep too.
    (
        trap 'kill $! 2> /dev/null; exit 0' TERM
        while :; do
            sleep 600 &
            wait $!
            "$OSS" machine renew "$lease" --minutes=60 > /dev/null || true
        done
    ) &
    renewer=$!
    for _ in $(seq 1 30); do vm true 2> /dev/null && break; sleep 5; done
}

# node for the VM, from nodejs.org, checked, kept on the runner between runs.
mac_vm_node() {
    local cache="${RUNNER_TOOL_CACHE:-$HOME/Library/Caches}/visor-ci"
    local file="$cache/node-$NODE_VERSION-darwin-arm64.tar.gz"
    mkdir -p "$cache"
    if ! echo "$NODE_SHA256  $file" | shasum -a 256 -c - > /dev/null 2>&1; then
        curl -fsSL -o "$file.part" "https://nodejs.org/dist/$NODE_VERSION/node-$NODE_VERSION-darwin-arm64.tar.gz"
        echo "$NODE_SHA256  $file.part" | shasum -a 256 -c - > /dev/null
        mv "$file.part" "$file"
    fi
    cp "$file" "$work/vm/node.tar.gz"
}

# A file or folder of the VM's (under ~/ci), copied out to <here>; scp makes
# a folder there (one already there would get it inside).
mac_vm_fetch() { run "$OSS" machine download "$lease" --identity="$work/key" "ci/$1" "$2"; }

# The checkout's tracked files as they stand, Bazel, and the steps, into
# ~/ci there. As they stand: the committed tree with what the job changed
# since its checkout (the Version step's stamped Info.plists, never
# committed), by `git stash create`, which makes them a commit without
# touching the checkout or its stash (and makes none when nothing
# changed: HEAD's tree then). Untracked files stay behind.
mac_vm_copy_tree() {
    [ -f "$work/vm/in_vm.sh" ] || mac_vm_steps < /dev/null
    local tree
    tree="$(git -C "$ROOT" -c user.name=CI -c user.email=ci@localhost stash create)"
    git -C "$ROOT" archive --format=tar.gz -o "$work/vm/tree.tar.gz" "${tree:-HEAD}"
    cp "$(readlink -f "$bazelisk")" "$work/vm/bazel"
    run "$OSS" machine upload "$lease" --identity="$work/key" "$work/vm" ci
    run in_vm unpack
}
