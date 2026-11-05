#!/bin/bash
# Visor on Android's part of the proof, from a Linux container (CI's
# visor-jit): blue Visor's APK built where it runs (tools/ci/container_build.sh),
# installed on an Android lease's emulator (OS Server holds its status bar
# still), and each of the fixture's screens (snapshots.py's SCREENS) opened
# with the intent snapshots.py's Android kind sends and pictured through
# the lease (`oss machine screenshot`). Each is compared with the same
# screen in the base's own proof (tools/ci/base_proof_screens.sh): version
# over version (Logan, 5 Nov 2026). A screen the base's proof hasn't got is
# new, and changed.
#
#   tools/ci/android_lease_proof.sh --image <agent image> --proof <dir> [--base <revision>]
#
# Adds to the proof in <dir> (tools/ci/ios_lease_proof.sh's, as Reviews reads
# it), each screen named android-<screen>:
#   screens/android-<screen>.png  each screen at this commit
#   before/android-<screen>.png   each that differs, as the base had it
#   diffs/android-<screen>.png    each that differs, its changed pixels red
#                                 (tools/isomer/snapshots/pngdiff.py)
#   proof.json                    its screens appended (made if it isn't there)
# The script fails when a step fails or no screen comes back.
#
# The lease is the script's alone: renewed while it runs, released however
# it ends (a kill nothing can trap leaves it its hour at most).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
me="$(basename "$0")"
OSS="/Applications/OS Server.app/Contents/Helpers/oss"
[ -x "$OSS" ] || OSS="$(command -v oss)"
# snapshots.py's SCREENS, and its package and settle.
SCREENS="sessions chat inspector models search connect goal earlier question new-session commands"
PACKAGE="com.loganshire.visor"
SETTLE="${VISOR_SNAPSHOT_SETTLE:-8}"

usage() { echo "usage: tools/ci/android_lease_proof.sh --image <agent image> --proof <dir> [--base <revision>]" >&2; exit 2; }
image=""
proof=""
base="HEAD"
while [ $# -gt 0 ]; do
    case "$1" in
        --image) image="${2:?--image takes the agent image}"; shift 2 ;;
        --proof) proof="${2:?--proof takes a folder}"; shift 2 ;;
        --base) base="${2:?--base takes a revision}"; shift 2 ;;
        *) usage ;;
    esac
done
[ -n "$image" ] && [ -n "$proof" ] || usage
commit="$(git -C "$ROOT" rev-parse HEAD)"
base_commit="$(git -C "$ROOT" rev-parse --verify "$base^{commit}")" || { echo "$me: no revision $base to compare with" >&2; exit 1; }
ref="${PROOF_REF:-${GITHUB_REF:-refs/heads/$(git -C "$ROOT" branch --show-current)}}"

work="$(mktemp -d)"
chmod 700 "$work"
built="$ROOT/.ci/android-proof-build"
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
    [ -z "${built:-}" ] || { chmod -R u+w "$built" 2> /dev/null || true; rm -rf "$built"; }
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

# The base's own proof, if GitHub keeps one: its android- screens are what
# these are compared with.
base_proof="null"
if run_id="$("$ROOT/tools/ci/base_proof_screens.sh" "$base_commit" "$work/base-proof")"; then
    base_proof="$run_id"
    echo "Compared with the proof of $base (run $run_id)"
else
    mkdir -p "$work/base-proof/screens"
    echo "No proof of $base kept: every Android screen is new"
fi

echo "::group::The APK, built on Linux"
(cd "$ROOT" && VISOR_CI_PACKAGE="$built" run tools/ci/container_build.sh "$image" \
    --compilation_mode=opt //applications/visor_android:visor_android_apk)
apk="$(ls "$built"/*.apk 2> /dev/null | grep -v '_unsigned\.apk$' | head -1)"
[ -n "$apk" ] || { echo "$me: the build left no signed .apk" >&2; exit 1; }
echo "::endgroup::"

echo "::group::An Android lease"
run "$OSS" machine lease android --minutes=60 --wait --exports > "$work/lease"
lease="$(. "$work/lease"; printf '%s' "$OSS_ID")"
echo "Leased $lease"
# Renewed every ten minutes; told to stop, it stops its sleep too.
(
    trap 'kill $! 2> /dev/null; exit 0' TERM
    while kill -0 "$$" 2> /dev/null; do
        sleep 600 &
        wait $!
        kill -0 "$$" 2> /dev/null || break
        "$OSS" machine renew "$lease" --minutes=60 > /dev/null || true
    done
) &
renewer=$!
adb() { "$OSS" machine adb "$lease" "$@"; }
adb shell cmd uimode night no
run adb install -r "$apk"
echo "::endgroup::"

echo "::group::The screens"
mkdir -p "$work/screens" "$proof/screens" "$proof/before" "$proof/diffs"
for screen in $SCREENS; do
    adb shell am start -S -n "$PACKAGE/.MainActivity" --es fixture snapshot --es fixture.screen "$screen" > /dev/null
    sleep "$SETTLE"
    run "$OSS" machine screenshot "$lease" "$work/screens/$screen.png" > /dev/null
    [ -s "$work/screens/$screen.png" ] || { echo "$me: no picture of $screen" >&2; exit 1; }
    echo "$screen"
done
adb shell am force-stop "$PACKAGE"
echo "::endgroup::"
release

# Each compared with the base's (tools/isomer/snapshots/pngdiff.py), and the
# proof's files and proof.json made or added to.
python3 -I - "$ROOT/tools/isomer/snapshots" "$work/screens" "$work/base-proof/screens" "$proof" \
    "$commit" "$ref" "${GITHUB_RUN_ID:-}" "$base_commit" "$base_proof" $SCREENS <<'PY'
import json, os, shutil, sys
tools, screens, base, proof, commit, ref, run, base_commit, base_proof, *names = sys.argv[1:]
sys.path.insert(0, tools)
import pngdiff

entries, summary = [], []
for screen in names:
    name = f"android-{screen}"
    capture = os.path.join(screens, f"{screen}.png")
    shutil.copy(capture, os.path.join(proof, "screens", f"{name}.png"))
    kept = os.path.join(base, f"{name}.png")
    if os.path.exists(kept):
        diff = os.path.join(proof, "diffs", f"{name}.png")
        pixels = pngdiff.compare(kept, capture, diff)
        if pixels:
            shutil.copy(kept, os.path.join(proof, "before", f"{name}.png"))
        else:
            os.remove(diff)
    else:
        # New: it differs everywhere, as a screen the base hasn't got does.
        width, height, _ = pngdiff.read_png(capture)
        pixels = width * height
    entries.append({"name": name, "changed": pixels > 0, "changedPixels": pixels})
    summary.append(f"| {name} | {'new' if not os.path.exists(kept) else (f'{pixels} pixels changed' if pixels else 'unchanged')} |")

path = os.path.join(proof, "proof.json")
if os.path.exists(path):
    document = json.load(open(path))
else:
    document = {"commit": commit, "ref": ref, "kind": os.environ.get("PROOF_KIND", "full"), "run": int(run) if run else None,
                "base": {"commit": base_commit, "proof": None if base_proof == "null" else int(base_proof)},
                "screens": []}
document["screens"] += entries
with open(path, "w") as f:
    json.dump(document, f, indent=2)
    f.write("\n")
step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
if step_summary:
    with open(step_summary, "a") as f:
        f.write(f"### Proof on an Android lease of {commit[:7]}\n\n| Screen | Against the base, {base_commit[:7]} |\n| --- | --- |\n")
        f.write("\n".join(summary) + "\n")
print("\n".join(summary))
PY

finished=1
