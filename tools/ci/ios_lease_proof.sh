#!/bin/bash
# Visor's proof without a macOS VM: the iPhone app and its probe
# (tests/ios_probe) built in a Linux container leased from this Mac's OS
# Server (tools/ci/container_build.sh, with rules_applecross), and run on an
# iOS lease's simulator (`oss machine xctest`, an iPhone 17 on iOS 27.2, as
# the kept pictures were taken): the phone app's fixture screens (the
# probe's testFixtureScreens, in portrait and on its side) and, for a full
# proof, its UI cases (tools/ios_ui_tests.sh's). The pictures come from the
# runs' result bundles, where the probe attaches every screen it takes, by
# xcresulttool on this Mac; each is compared with the picture kept for it at
# the base (CI: the release before, else the commit before; else this
# commit). As reviews' tools/ci/ios_lease_tests.sh.
#
#   tools/ci/ios_lease_proof.sh --image <agent image> --proof <dir> [--kind quick|full] [--base <revision>]
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
#   logs/               each run's JUnit and result bundle
# The script fails as the probe does (a full proof's UI cases too), or when
# no screen comes back.
#
#   PROOF_REF  the ref the proof is of (default: GITHUB_REF, else the branch)
#
# The lease is the script's alone: renewed while it runs, released however
# it ends (a kill nothing can trap leaves it its hour at most).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
me="$(basename "$0")"
OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss)"
DEVICE="iPhone 17"
# The UI cases a full proof runs: tools/ios_ui_tests.sh's, which need no
# computer (the snapshot fixture).
UI_CASES="$(sed -n 's/^CASES="\${VISOR_UI_CASES:-\(.*\)}"$/\1/p' "$ROOT/tools/ios_ui_tests.sh")"

usage() { echo "usage: tools/ci/ios_lease_proof.sh --image <agent image> --proof <dir> [--kind quick|full] [--base <revision>]" >&2; exit 2; }
image=""
proof=""
kind="quick"
base="HEAD"
while [ $# -gt 0 ]; do
    case "$1" in
        --image) image="${2:?--image takes the agent image}"; shift 2 ;;
        --proof) proof="${2:?--proof takes a folder}"; shift 2 ;;
        --kind) kind="${2:?--kind takes quick or full}"; shift 2 ;;
        --base) base="${2:?--base takes a revision}"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$image" ] && [ -n "$proof" ] || usage
case "$kind" in quick | full) ;; *) usage ;; esac
[ -n "$UI_CASES" ] || { echo "$me: no UI cases in tools/ios_ui_tests.sh" >&2; exit 1; }
xcrun --find xcresulttool > /dev/null 2>&1 || { echo "$me: no xcresulttool on this Mac (Xcode's): the pictures can't be read from the result bundles" >&2; exit 1; }

commit="$(git -C "$ROOT" rev-parse HEAD)"
base_commit="$(git -C "$ROOT" rev-parse --verify "$base^{commit}")" || { echo "$me: no revision $base to compare with" >&2; exit 1; }
ref="${PROOF_REF:-${GITHUB_REF:-refs/heads/$(git -C "$ROOT" branch --show-current)}}"

work="$(mktemp -d)"
chmod 700 "$work"
lease=""
renewer=""
child=""
finished=""
release() {
    if [ -n "$renewer" ]; then kill "$renewer" 2> /dev/null || true; wait "$renewer" 2> /dev/null || true; renewer=""; fi
    # A lease asked for as the script was stopped: its id, if it came.
    [ -n "$lease" ] || lease="$(. "$work/lease" 2> /dev/null; printf '%s' "${OSS_ID:-}")"
    if [ -n "$lease" ]; then
        "$OSS" machine release "$lease" || echo "$me: lease $lease was not released: oss machine release $lease" >&2
        lease=""
        rm -f "$work/lease"
    fi
}
# macOS's bash (3.2) runs this with $? 0 when an unset variable stops the
# script (set -eu): an end before the last line is a failure, whatever it says.
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

# The diff tool first: nothing built or leased if it doesn't build. And the
# pictures kept at the base, what the screens are compared with.
xcrun swiftc -O -o "$work/snapshot_diff" "$ROOT/tools/ci/snapshot_diff.swift"
mkdir "$work/base"
git -C "$ROOT" archive "$base_commit" tests/proof | tar -x -C "$work/base"

echo "::group::The app and its probe, built on Linux"
built="$ROOT/.ci/proof-build"
(cd "$ROOT" && VISOR_CI_PACKAGE="$built" run bazel run //tools/ci:container_build -- "$image" \
    --ios_multi_cpus=sim_arm64 //applications/visor_ios //tests/ios_probe:visor_probe)
for file in "$built/visor_ios.ipa" "$built/visor_probe.zip"; do
    [ -f "$file" ] || { echo "$me: the build left no $(basename "$file")" >&2; exit 1; }
done
echo "::endgroup::"

echo "::group::An iOS lease ($DEVICE)"
run "$OSS" machine lease ios --device="$DEVICE" --minutes=60 --wait --exports > "$work/lease"
lease="$(. "$work/lease"; printf '%s' "$OSS_ID")"
echo "Leased $lease"
# Renewed every ten minutes; told to stop, it stops its sleep too.
(
    trap 'kill $! 2> /dev/null; exit 0' TERM
    # While the script lives: a cancel that kills it (SIGKILL, no trap)
    # leaves no renewer holding the lease for good. $$ is the script's,
    # in this subshell too.
    while kill -0 "$$" 2> /dev/null; do
        sleep 600 &
        wait $!
        kill -0 "$$" 2> /dev/null || break
        "$OSS" machine renew "$lease" --minutes=60 > /dev/null || true
    done
) &
renewer=$!
# The status bar is held still by OS Server; no keyboard suggestions over
# the keys either: what they say is learned and comes in late.
"$OSS" machine simctl "$lease" spawn booted defaults write com.apple.Preferences KeyboardPrediction -bool NO
echo "::endgroup::"

# Each run on the lease, one at a time (a lease runs one), whatever the one
# before did: the fixture's screens in each orientation, then a full
# proof's UI cases.
status=0
mkdir -p "$work/results"
xctest() {
    local name=$1
    shift
    echo "::group::$name"
    run "$OSS" machine xctest "$lease" --tests="$built/visor_probe.zip" --host="$built/visor_ios.ipa" --ui "$@" \
        --junit="$work/results/$name.xml" --result="$work/results/$name.xcresult.zip" || status=1
    echo "::endgroup::"
}
xctest portrait --only-testing=VisorProbe/testFixtureScreens
xctest landscape --only-testing=VisorProbe/testFixtureScreensLandscape
if [ "$kind" = full ]; then
    cases=()
    IFS=, read -r -a names <<< "$UI_CASES"
    for case in "${names[@]}"; do cases+=("--only-testing=$case"); done
    xctest ui-cases "${cases[@]}"
fi
release
mkdir -p "$proof/logs"
cp "$work/results"/* "$proof/logs"/ 2> /dev/null || true

# The pictures: each attachment named fixture-<screen>, exported from its
# orientation's result bundle.
for orientation in portrait landscape; do
    mkdir -p "$work/out/$orientation"
    result="$work/results/$orientation.xcresult.zip"
    [ -f "$result" ] || { echo "$me: the $orientation run left no result bundle" >&2; continue; }
    rm -rf "$work/unzipped" "$work/attachments"
    mkdir "$work/unzipped" "$work/attachments"
    ditto -x -k "$result" "$work/unzipped"
    bundle="$(find "$work/unzipped" -maxdepth 2 -name '*.xcresult' -type d | head -1)"
    xcrun xcresulttool export attachments --path "$bundle" --output-path "$work/attachments" > /dev/null
    python3 - "$work/attachments" "$work/out/$orientation" << 'PY'
import json, os, re, shutil, sys
source, out = sys.argv[1], sys.argv[2]
for test in json.load(open(os.path.join(source, "manifest.json"))):
    for attachment in test.get("attachments", []):
        # The attachment's name as the probe gave it, which xcresulttool
        # suffixes with an index and an identifier.
        name = attachment.get("suggestedHumanReadableName", "")
        name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(?=\.png$)", "", name)
        if name.startswith("fixture-") and name.endswith(".png"):
            shutil.copy(os.path.join(source, attachment["exportedFileName"]), os.path.join(out, name))
PY
done

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
    printf '### Proof (%s, on an iOS lease) of %s\n\n| Screen | Against its picture kept at %s |\n| --- | --- |\n%s' "$kind" "${commit:0:7}" "${base_commit:0:7}" "$summary" >> "$GITHUB_STEP_SUMMARY"
fi

if [ -z "$screens" ]; then
    echo "$me: no screens came back in the result bundles" >&2
    [ "$status" -ne 0 ] || status=1
fi
finished=1
exit "$status"
