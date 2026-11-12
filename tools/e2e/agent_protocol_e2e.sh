#!/bin/bash
# agent_protocol end to end, in one step, from your own terminal (a Mac
# with `sw`, `gh` and python3). It leases a macOS VM and, through
# Shireworks' half, a Linux container. Then it runs one native agent
# (Visor's runner) and one container agent (Shireworks' runner, reaching
# Visor only through MultiPass), each answering two messages, and keeps
# screenshots of Visor's window and the logs. Then it releases everything.
# The Claude token is asked for without echo. It goes only into the two
# agents' environments over ssh's standard input: no file, no log, no image.
#
#   tools/e2e/agent_protocol_e2e.sh [--dry-run] [--visor-run <id>] [--out <folder>]
#
#   --dry-run          the echo harness and a dummy token: no model, no token asked for
#   --visor-run        the visor CI run whose apps-mac artifact is Visor.app (the
#                      latest unexpired one from main unless given)
#   --out              where the proof goes (./agent-protocol-e2e-<time> unless given)
#
# The container half is Shireworks' tools/e2e/relay_container.sh, from your
# shireworks checkout (SHIREWORKS_CHECKOUT, ~/Developer/shireworks unless set).
#
# It never touches this Mac beyond a temporary folder (removed at the end)
# and the proof folder. Every lease is released however it ends.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SW="${SW:-sw}"
dry_run=0 visor_run="" out=""
relay_container="${SHIREWORKS_CHECKOUT:-$HOME/Developer/shireworks}/tools/e2e/relay_container.sh"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --visor-run) visor_run="${2:?}"; shift ;;
        --out) out="${2:?}"; shift ;;
        *) echo "usage: $0 [--dry-run] [--visor-run <id>] [--out <folder>]" >&2; exit 2 ;;
    esac
    shift
done
for tool in "$SW" gh python3; do
    command -v "$tool" > /dev/null || { echo "agent_protocol_e2e: $tool isn't on PATH" >&2; exit 2; }
done
[ -f "$relay_container" ] || { echo "agent_protocol_e2e: no $relay_container (Shireworks' container half): set SHIREWORKS_CHECKOUT, or pull shireworks" >&2; exit 2; }
say() { echo "agent_protocol_e2e: $*"; }
out="${out:-$PWD/agent-protocol-e2e-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$out"

if [ "$dry_run" = 1 ]; then
    harness=echo
    token="dry-run-not-a-token"
else
    harness=claude
    read -rsp "Claude token for the test agents (from \`claude setup-token\`): " token
    echo
    [ -n "$token" ] || { echo "agent_protocol_e2e: no token" >&2; exit 2; }
fi
# Visor's own password in the VM: throwaway, made here, never shown.
password="$(python3 -I -c 'import secrets; print(secrets.token_urlsafe(18))')"

work="$(mktemp -d)"
vm="" container=""
finish() {
    status=$?
    set +e
    if [ -n "$container" ] && [ -n "$vm" ]; then
        say "the container half's cleanup"
        bash "$relay_container" down "$vm" "$container"
    fi
    if [ -n "$vm" ]; then
        say "releasing the VM $vm"
        "$SW" machine release "$vm"
    fi
    rm -rf "$work"
    unset token password
    if [ "$status" = 0 ]; then say "PASSED. The proof is in $out"; else say "FAILED ($status). What was kept is in $out"; fi
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT TERM

say "Visor.app: the apps-mac artifact of visor's CI"
if [ -z "$visor_run" ]; then
    visor_run="$(gh api 'repos/AttilaTheFun/visor/actions/artifacts?name=apps-mac&per_page=30' \
        --jq '[.artifacts[] | select(.expired == false and .workflow_run.head_branch == "main")][0].workflow_run.id')"
    [ -n "$visor_run" ] && [ "$visor_run" != null ] \
        || { echo "agent_protocol_e2e: no unexpired apps-mac from main: dispatch CI's \`run: verify\` on main first" >&2; exit 1; }
fi
gh run download "$visor_run" -R AttilaTheFun/visor -n apps-mac -D "$work/visor"
say "MultiPass's source (main)"
gh api repos/AttilaTheFun/multipass/tarball/main > "$work/multipass.tar.gz"

say "leasing a macOS VM (xcode_27_2, 120 minutes)"
exports="$("$SW" machine lease macos --config=xcode_27_2 --minutes=120 --label="agent_protocol e2e" --exports)"
eval "$exports"
vm="${SHIREWORKS_ID:-${OSS_ID:-}}"
[ -n "$vm" ] || { echo "agent_protocol_e2e: the lease named no id" >&2; exit 1; }
say "VM $vm"
vm_ssh() { "$SW" machine ssh "$vm" -- "$@"; }

vm_ssh "rm -rf /tmp/e2e && mkdir -p /tmp/e2e"
for file in "$work/visor/visor_mac.zip" "$work/multipass.tar.gz" "$HERE/vm_setup.sh" "$HERE/vm_agents.py" "$HERE/window.js"; do
    "$SW" machine upload "$vm" "$file" "/tmp/e2e/$(basename "$file")"
done
say "setting the VM up: Visor.app, MultiPass$( [ "$harness" = claude ] && echo ", Claude Code")"
printf '%s\n%s\n' "$token" "$password" | vm_ssh "bash /tmp/e2e/vm_setup.sh $harness"

window_frame() { # Visor's window: x y width height (the VM's screen is 1:1)
    vm_ssh 'sudo launchctl asuser $(id -u) sudo -u $(id -un) osascript -l JavaScript /tmp/e2e/window.js'
}
shot() { # shot <name>: the screen, then Visor's window cut from it
    local name="$1" x y width height
    "$SW" machine screenshot "$vm" "$work/screen.png"
    read -r x y width height <<< "$(window_frame)" || true
    if [ -n "${height:-}" ] && python3 -I "$HERE/pngcrop.py" "$work/screen.png" "$out/$name.png" "$x" "$y" "$width" "$height" > /dev/null 2>&1; then
        :
    else
        cp "$work/screen.png" "$out/$name.png"
    fi
}
select_row() { # select_row <n>: the nth session in Visor's sidebar (newest first), shown
    local x y width height
    read -r x y width height <<< "$(window_frame)" || true
    [ -n "${height:-}" ] && "$SW" machine tap "$vm" $(( x + 110 )) $(( y + 135 + 60 * $1 )) > /dev/null || true
}

say "the native agent"
vm_ssh "python3 -I /tmp/e2e/vm_agents.py run native 240" | tee "$out/native.json"
native="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["session"])' < "$out/native.json")"

say "the container half (Shireworks' relay_container.sh): Shireworks.app and its runner, the container, MultiPass's relay"
printf '%s\n' "$token" | bash "$relay_container" up "$vm" --harness="$harness" | tee "$work/relay_container.out"
unset token
container="$(tail -1 "$work/relay_container.out" | sed -n 's/^container=//p')"
[ -n "$container" ] || { echo "agent_protocol_e2e: the container half named no container" >&2; exit 1; }

say "the container agent"
vm_ssh "python3 -I /tmp/e2e/vm_agents.py run container 300" | tee "$out/container.json"
container="$(python3 -I -c 'import json,sys; print(json.load(sys.stdin)["session"])' < "$out/container.json")"

say "screenshots"
select_row 0; sleep 2; shot container-agent
select_row 1; sleep 2; shot native-agent

say "ending both agents"
vm_ssh "python3 -I /tmp/e2e/vm_agents.py stop $container; python3 -I /tmp/e2e/vm_agents.py stop $native"
sleep 5
say "the logs"
vm_ssh "sudo log show --last 60m --style compact --predicate 'subsystem == \"com.LoganShire.Visor\"' \
    | grep -E 'agent_protocol|dispatcher|driver|driven|native runner|stopping|lapsed'" > "$out/visor-server.log" || true
vm_ssh "grep -E 'relay|dial-in|listens' ~/mp/agent.log" > "$out/multipass-agent.log" || true
grep -q "$container.* completed" "$out/visor-server.log" && grep -q "$native.* completed" "$out/visor-server.log" \
    || { echo "agent_protocol_e2e: the dispatcher didn't log both agents completed" >&2; exit 1; }
grep -q "dial-in to loopback port 7434" "$out/multipass-agent.log" \
    || { echo "agent_protocol_e2e: MultiPass logged no dial-in: the container didn't come through it" >&2; exit 1; }
