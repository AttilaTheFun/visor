#!/bin/bash
# The proof (.github/workflows/proof.yml), from its platforms' pictures, on
# one of GitHub's Macs (the diff tool draws with CoreGraphics): each screen
# compared with the same screen in the base's own proof
# (tools/ci/base_proof_screens.sh), version over version (Logan, 5 Nov
# 2026). The base is the previous release (the newest v* tag before the
# commit), else the commit before.
#
#   tools/ci/proof_compare.sh <parts> <proof> [quick|full]
#
# <parts> holds a folder for each platform's part (tools/ci/proof_ios.sh's,
# proof_mac.sh's and proof_android.sh's: screens/, logs/, device.txt), named
# for it (ios, mac, android; or part-ios and so on, as the workflow's
# artifacts download). The proof, in <proof>, as Reviews reads it
# from the run's `proof` artifact:
#   screens/<name>.png  each screen at this commit, named for its platform
#                       (ios-chat, ios-chat-landscape, mac-chat,
#                       android-chat, …)
#   before/<name>.png   each that differs, as the base had it; none for a
#                       screen the base hasn't got (new, and changed)
#   diffs/<name>.png    each that differs from the base's, its changed
#                       pixels red (tools/ci/snapshot_diff.swift)
#   proof.json          {"commit", "ref", "kind", "run", "base": {"ref",
#                        "commit", "proof": the run whose proof it was, or
#                        null}, "devices": {each platform: what it ran on},
#                        "screens": [{"name", "changed", "changedPixels"}]}
#   logs/<platform>/    each part's logs
#
#   PROOF_BASE  the revision compared with (default: as above)
#   PROOF_REF   the ref the proof is of (default: GITHUB_REF, else the branch)
#
# Fails when no screen came back or one couldn't be compared; a screen
# that changed is what the proof shows, not a failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
me="$(basename "$0")"
usage() { echo "usage: tools/ci/proof_compare.sh <parts> <proof> [quick|full]" >&2; exit 2; }
[ $# -ge 2 ] || usage
parts="$(cd "$1" && pwd)"
mkdir -p "$2"
proof="$(cd "$2" && pwd)"
kind="${3:-full}"
case "$kind" in quick | full) ;; *) usage ;; esac

cd "$ROOT"
commit="$(git rev-parse HEAD)"
ref="${PROOF_REF:-${GITHUB_REF:-refs/heads/$(git branch --show-current)}}"
base="${PROOF_BASE:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD^ 2> /dev/null || echo HEAD^)}"
base_commit="$(git rev-parse --verify "$base^{commit}")" || { echo "$me: no revision $base to compare with" >&2; exit 1; }
base_ref="$base"
[ "$base" != HEAD^ ] || base_ref="the commit before"

work="$(mktemp -d)"
finished=""
# macOS's bash (3.2) runs this with $? 0 when an unset variable stops the
# script (set -eu): an end before the last line is a failure, whatever it says.
cleanup() {
    local status=$?
    [ -n "$finished" ] || [ "$status" -ne 0 ] || status=1
    rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT

base_proof="null"
if base_proof="$(tools/ci/base_proof_screens.sh "$base" "$work/base")"; then
    echo "Compared with the proof of $base_ref (${base_commit:0:7}, run $base_proof)"
else
    base_proof="null"
    mkdir -p "$work/base/screens"
    echo "::warning::No proof of $base_ref (${base_commit:0:7}) kept: every screen is new"
fi

xcrun swiftc -O -o "$work/snapshot_diff" tools/ci/snapshot_diff.swift
mkdir -p "$proof/screens" "$proof/before" "$proof/diffs" "$proof/logs"
status=0
: > "$work/compared.tsv"
for part in "$parts"/*/; do
    platform="$(basename "$part")"
    platform="${platform#part-}"
    [ ! -d "$part/logs" ] || cp -R "$part/logs" "$proof/logs/$platform"
    [ ! -f "$part/device.txt" ] || printf '%s\t%s\n' "$platform" "$(head -1 "$part/device.txt")" >> "$work/devices.tsv"
    for picture in "$part"screens/*.png; do
        [ -f "$picture" ] || continue
        name="$(basename "$picture" .png)"
        cp "$picture" "$proof/screens/$name.png"
        kept="$work/base/screens/$name.png"
        pixels="$("$work/snapshot_diff" "$kept" "$picture" "$work/diff.png")" || { echo "::error::$name couldn't be compared"; status=1; continue; }
        if [ "$pixels" -ne 0 ]; then
            [ ! -f "$work/diff.png" ] || mv "$work/diff.png" "$proof/diffs/$name.png"
            [ ! -f "$kept" ] || cp "$kept" "$proof/before/$name.png"
        fi
        rm -f "$work/diff.png"
        new=false
        [ -f "$kept" ] || new=true
        printf '%s\t%s\t%s\n' "$name" "$pixels" "$new" >> "$work/compared.tsv"
    done
done
touch "$work/devices.tsv"

# The proof's own words: proof.json, and the run's summary.
python3 -I - "$work" "$proof" "$commit" "$ref" "$kind" "${GITHUB_RUN_ID:-}" "$base_ref" "$base_commit" "$base_proof" << 'PY'
import json, os, sys
work, proof, commit, ref, kind, run, base_ref, base_commit, base_proof = sys.argv[1:10]
screens, new = [], set()
with open(os.path.join(work, "compared.tsv")) as file:
    for line in file:
        name, pixels, is_new = line.rstrip("\n").split("\t")
        screens.append({"name": name, "changed": int(pixels) != 0, "changedPixels": int(pixels)})
        if is_new == "true":
            new.add(name)
with open(os.path.join(work, "devices.tsv")) as file:
    devices = dict(line.rstrip("\n").split("\t", 1) for line in file if "\t" in line)
kept = {name[:-4] for name in os.listdir(os.path.join(work, "base", "screens")) if name.endswith(".png")}
gone = sorted(kept - {screen["name"] for screen in screens})
document = {"commit": commit, "ref": ref, "kind": kind, "run": int(run) if run else None,
            "base": {"ref": base_ref, "commit": base_commit, "proof": None if base_proof == "null" else int(base_proof)},
            "devices": devices, "screens": screens}
with open(os.path.join(proof, "proof.json"), "w") as file:
    json.dump(document, file, indent=2)
    file.write("\n")
print(json.dumps(document, indent=2))
summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    platforms = {"ios": "iPhone", "mac": "Mac", "android": "Android"}
    lines = [f"### Proof ({kind}) of {commit[:7]}, against {base_ref} ({base_commit[:7]})", ""]
    for platform, title in platforms.items():
        mine = [screen for screen in screens if screen["name"].startswith(platform + "-")]
        if not mine and platform not in devices:
            continue
        changed = [screen for screen in mine if screen["changed"]]
        lines += [f"**{title}** ({devices.get(platform, 'no device')}): {len(mine)} screens, {len(changed)} changed", ""]
        if mine:
            lines += ["| Screen | Against the base |", "| --- | --- |"]
            for screen in mine:
                words = "new" if screen["name"] in new else (f"{screen['changedPixels']} pixels changed" if screen["changed"] else "unchanged")
                lines.append(f"| {screen['name']} | {words} |")
            lines.append("")
    if gone:
        lines += ["The base had these, which this proof hasn't: " + ", ".join(gone), ""]
    with open(summary, "a") as file:
        file.write("\n".join(lines) + "\n")
PY

[ -s "$work/compared.tsv" ] || { echo "$me: no screens came back from the platforms" >&2; status=1; }
finished=1
exit "$status"
