#!/bin/bash
# Visor's proof, in a macOS VM leased from OS Server (xcode-27.0: Xcode 27.0
# and its iOS simulator): the phone app's fixture screens (the iOS probe's
# testFixtureScreens, in portrait and on its side) and, for a full proof, its
# UI cases; each screen compared with the picture kept for it at the base
# (CI: the commit before, so a change that takes new pictures shows as a
# change; else this commit).
#
#   tools/ci/mac_vm_proof.sh --proof <dir> [--kind quick|full] [--base <revision>]
#
# The proof, in <dir>, as Reviews reads it from the run's `proof` artifact:
#   screens/<name>.png  each fixture screen at this commit ("chat",
#                       "chat-landscape", …)
#   diffs/<name>.png    each that differs from its kept picture at the base
#                       (tests/proof/ios, tests/proof/ios-landscape),
#                       its changed pixels red (tools/ci/snapshot_diff.swift,
#                       built here)
#   proof.json          {"commit", "ref", "kind", "run", "base": {"commit"},
#                        "screens": [{"name", "changed", "changedPixels"}]}
#   logs/               what the probe said, each run
# The script fails as the probe does (a full proof's UI cases too), or when
# no screen comes back.
#
#   PROOF_REF  the ref the proof is of (default: GITHUB_REF, else the branch)
#
# The VM is the script's alone: leased for two hours, renewed while it runs,
# released however it ends (a kill nothing can trap leaves it two hours at
# most). The committed tree goes in (git archive HEAD), with the runner's
# bazelisk; Bazel there reads OS Server's cache, as every lease's does. The
# simulator builds need no signing team.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

usage() { echo "usage: tools/ci/mac_vm_proof.sh --proof <dir> [--kind quick|full] [--base <revision>]" >&2; exit 2; }
proof=""
kind="quick"
base="HEAD"
while [ $# -gt 0 ]; do
    case "$1" in
        --proof) proof="${2:?--proof takes a folder}"; shift 2 ;;
        --kind) kind="${2:?--kind takes quick or full}"; shift 2 ;;
        --base) base="${2:?--base takes a revision}"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$proof" ] || usage
case "$kind" in quick | full) ;; *) usage ;; esac

commit="$(git -C "$ROOT" rev-parse HEAD)"
base_commit="$(git -C "$ROOT" rev-parse --verify "$base^{commit}")" || { echo "mac_vm_proof.sh: no revision $base to compare with" >&2; exit 1; }
ref="${PROOF_REF:-${GITHUB_REF:-refs/heads/$(git -C "$ROOT" branch --show-current)}}"
OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss)"
bazelisk="$(command -v bazelisk)" || { echo "mac_vm_proof.sh: no bazelisk on the PATH to copy in" >&2; exit 1; }

work="$(mktemp -d)"
chmod 700 "$work"
lease=""
renewer=""
child=""

# The VM given back now, not left to its hours.
release() {
    if [ -n "$renewer" ]; then
        kill "$renewer" 2> /dev/null || true
        wait "$renewer" 2> /dev/null || true
        renewer=""
    fi
    # A lease asked for as the script was stopped: its id, if it came.
    [ -n "$lease" ] || lease="$(. "$work/lease" 2> /dev/null; printf '%s' "${OSS_ID:-}")"
    if [ -n "$lease" ]; then
        "$OSS" machine release "$lease" || echo "mac_vm_proof.sh: lease $lease was not released: oss machine release $lease" >&2
        lease=""
        rm -f "$work/lease"
    fi
}
# macOS's bash (3.2) runs this with $? 0 when an unset variable stops the
# script (set -eu): an end before the last line is a failure, whatever it says.
finished=""
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    [ -z "$child" ] || kill "$child" 2> /dev/null || true
    release
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

# The diff tool first: nothing leased if it doesn't build. And the pictures
# kept at the base, what the screens are compared with.
xcrun swiftc -O -o "$work/snapshot_diff" "$ROOT/tools/ci/snapshot_diff.swift"
mkdir "$work/base"
git -C "$ROOT" archive "$base_commit" tests/proof | tar -x -C "$work/base"

echo "::group::A macOS VM (xcode-27.0)"
# A key of the run's own for the VM's SSH, gone with the run.
ssh-keygen -q -t ed25519 -N '' -C visor-ci -f "$work/key"
run "$OSS" machine lease macos --config=xcode-27.0 --minutes=120 --wait --key="$work/key.pub" --exports > "$work/lease"
lease="$(. "$work/lease"; printf '%s' "$OSS_ID")"
echo "Leased $lease"
# Renewed every ten minutes; told to stop, it stops its sleep too.
(
    trap 'kill $! 2> /dev/null; exit 0' TERM
    while :; do
        sleep 600 &
        wait $!
        "$OSS" machine renew "$lease" --minutes=120 > /dev/null || true
    done
) &
renewer=$!
for _ in $(seq 1 30); do vm true 2> /dev/null && break; sleep 5; done

# The tree as committed, Bazel, and what the VM runs, into ~/ci there.
mkdir "$work/vm"
git -C "$ROOT" archive --format=tar.gz -o "$work/vm/tree.tar.gz" HEAD
cp "$(readlink -f "$bazelisk")" "$work/vm/bazel"
cat > "$work/vm/in_vm.sh" << 'EOF'
#!/bin/bash
# In the VM, in ~/ci: the tree in src/, Bazel in bin/.
set -uo pipefail
cd ~/ci
export PATH="$HOME/ci/bin:/usr/bin:/bin:/usr/sbin:/sbin"
case "$1" in
    unpack)
        mkdir -p src bin logs && tar -xzf tree.tar.gz -C src && mv bazel bin/bazel && chmod +x bin/bazel || exit
        xcodebuild -version | head -1
        xcrun simctl list runtimes | grep -i '^ios'
        # The simulator the probe runs on, as tools/proof.sh makes it: new,
        # the status bar held still, no keyboard predictions (what they say
        # is learned, and comes in late).
        runtime="$(xcrun simctl list runtimes | grep -o 'com.apple.CoreSimulator.SimRuntime.iOS-27-0' | head -1)"
        sim="$(xcrun simctl create "BAZEL_TEST_iPhone 17_27.0" "iPhone 17" "$runtime")" || exit
        xcrun simctl boot "$sim" && xcrun simctl bootstatus "$sim" > /dev/null || exit
        xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
            --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100 || exit
        xcrun simctl spawn "$sim" defaults write com.apple.Preferences KeyboardPrediction -bool NO
        ;;
    screens)
        # $2: portrait or landscape. The pictures into out/<orientation>.
        cases=VisorProbe/testFixtureScreens
        [ "$2" = landscape ] && cases=VisorProbe/testFixtureScreensLandscape
        rm -rf /private/tmp/visor_probe
        (cd src && VISOR_UI_CASES="$cases" VISOR_PROBE_ORIENTATION="$2" tools/ios_ui_tests.sh) > "logs/screens-$2.log" 2>&1
        status=$?
        mkdir -p "out/$2" && cp /private/tmp/visor_probe/fixture-*.png "out/$2/" 2> /dev/null
        tail -3 "logs/screens-$2.log"
        exit "$status"
        ;;
    tests)
        (cd src && tools/ios_ui_tests.sh) > logs/ui-tests.log 2>&1
        status=$?
        tail -3 logs/ui-tests.log
        exit "$status"
        ;;
esac
EOF
run "$OSS" machine upload "$lease" --identity="$work/key" "$work/vm" ci
run vm bash ci/in_vm.sh unpack
echo "::endgroup::"

status=0
for orientation in portrait landscape; do
    echo "::group::The fixture's screens ($orientation)"
    run vm bash ci/in_vm.sh screens "$orientation" || status=1
    echo "::endgroup::"
done
if [ "$kind" = full ]; then
    echo "::group::The UI cases"
    run vm bash ci/in_vm.sh tests || status=1
    echo "::endgroup::"
fi
# scp makes the folders (ones already here would get them inside).
run "$OSS" machine download "$lease" --identity="$work/key" ci/out "$work/out" || mkdir -p "$work/out"
mkdir -p "$proof"
run "$OSS" machine download "$lease" --identity="$work/key" ci/logs "$proof/logs" || true
release

# The proof, from the pictures and the ones kept at the base.
json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
mkdir -p "$proof/screens" "$proof/diffs"
screens=""
summary=""
for orientation in portrait landscape; do
    kept="$work/base/tests/proof/ios"
    suffix=""
    [ "$orientation" = portrait ] || { kept="$work/base/tests/proof/ios-landscape"; suffix="-landscape"; }
    for picture in "$work/out/$orientation"/fixture-*.png; do
        [ -e "$picture" ] || continue
        screen="$(basename "$picture" .png)"
        screen="${screen#fixture-}"
        name="$screen$suffix"
        cp "$picture" "$proof/screens/$name.png"
        pixels="$("$work/snapshot_diff" "$kept/$screen.png" "$picture" "$proof/diffs/$name.png")"
        changed=false
        [ "$pixels" -eq 0 ] || changed=true
        screens="$screens${screens:+,}
    {\"name\": \"$(json "$name")\", \"changed\": $changed, \"changedPixels\": $pixels}"
        summary="$summary| $name | $([ "$changed" = true ] && echo "$pixels pixels changed" || echo unchanged) |
"
    done
done
cat > "$proof/proof.json" << EOF
{
  "commit": "$commit",
  "ref": "$(json "$ref")",
  "kind": "$kind",
  "run": ${GITHUB_RUN_ID:-null},
  "base": {"commit": "$base_commit"},
  "screens": [$screens
  ]
}
EOF
cat "$proof/proof.json"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '### Proof (%s) of %s\n\n| Screen | Against its picture kept at %s |\n| --- | --- |\n%s' "$kind" "${commit:0:7}" "${base_commit:0:7}" "$summary" >> "$GITHUB_STEP_SUMMARY"
fi

if [ -z "$screens" ]; then
    echo "mac_vm_proof.sh: no screens came back" >&2
    [ "$status" -ne 0 ] || status=1
fi
finished=1
exit "$status"
