# Sourced by the CI scripts whose steps need a Mac (Xcode's xcresulttool,
# swiftc for CoreGraphics, a server beside the iOS lease's simulator) but
# run in a Linux container (the visor-jit runners): a slot of Shireworks'
# primary Mac VM (`shireworks.sh lease mac`: a macOS user of its own there,
# ready in seconds), renewed while the script runs and released however it
# ends. A slot has no SSH: its commands go through `shireworks.sh run`, which
# hands them their arguments as they are, and its files one at a time
# through put and get, their paths relative to its user's home.
#
#   . "$ROOT/tools/ci/mac_slot.sh"
#   mac_slot_lease                       # the slot, its renewer started
#   mac_slot_upload <file> <path>        # a file, to the slot's <path>
#   mac_slot_exec <command> <args…>      # a command there; its status
#   mac_slot_download <path> <file>      # a file, from the slot's <path>
#   mac_slot_release                     # given back now (else on exit)
#
# The script that sources it gives ROOT (the checkout, for
# tools/ci/shireworks.sh) and work (a folder of its own), and calls
# mac_slot_release from its EXIT trap.
slot=""
slot_renewer=""

mac_slot_lease() {
    sh "$ROOT/tools/ci/shireworks.sh" lease mac --minutes=60 > "$work/slot"
    slot="$(. "$work/slot"; printf '%s' "$SHIREWORKS_ID")"
    [ -n "$slot" ] || { echo "mac_slot: no slot came" >&2; return 1; }
    echo "Slot $slot"
    (
        trap 'kill $! 2> /dev/null; exit 0' TERM
        # Only while the script runs: one killed past its traps (a cancel
        # that ends in SIGKILL) leaves this loop, which must not keep its
        # slot past the hour. $$ is the script, in this subshell too.
        while kill -0 "$$" 2> /dev/null; do
            sleep 600 &
            wait $!
            kill -0 "$$" 2> /dev/null || break
            sh "$ROOT/tools/ci/shireworks.sh" renew "$slot" --minutes=60 > /dev/null || true
        done
    ) &
    slot_renewer=$!
}

mac_slot_upload() { sh "$ROOT/tools/ci/shireworks.sh" put "$slot" "$1" "$2" > /dev/null; }
mac_slot_download() { sh "$ROOT/tools/ci/shireworks.sh" get "$slot" "$1" "$2" > /dev/null; }
mac_slot_exec() { sh "$ROOT/tools/ci/shireworks.sh" run "$slot" -- "$@"; }

mac_slot_release() {
    if [ -n "$slot_renewer" ]; then kill "$slot_renewer" 2> /dev/null || true; wait "$slot_renewer" 2> /dev/null || true; slot_renewer=""; fi
    [ -n "$slot" ] || slot="$(. "$work/slot" 2> /dev/null; printf '%s' "${SHIREWORKS_ID:-}")"
    if [ -n "$slot" ]; then
        sh "$ROOT/tools/ci/shireworks.sh" release "$slot" || echo "mac_slot: slot $slot was not released: shireworks.sh release $slot" >&2
        slot=""
        rm -f "$work/slot"
    fi
}
