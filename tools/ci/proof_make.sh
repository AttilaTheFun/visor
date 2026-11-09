#!/bin/bash
# The proof (ci.yml's verify), as Reviews reads it: AttilaTheFun/reviews'
# docs/PROOF_FORMAT.md, format 2. CI only makes it; Reviews compares it with
# the prior release's, item by item, by id (Logan, 8 Nov 2026). Nothing here
# compares, and nothing needs a Mac: it runs in a container.
#
#   tools/ci/proof_make.sh <parts> <out> [<version>]
#
# <parts> holds a folder for each platform's part (tools/ci/proof_ios.sh's,
# proof_mac.sh's and proof_android.sh's: screens/<platform>-<screen>.png),
# named for it (ios, mac, android; or part-ios and so on, as the workflow's
# artifacts download). Out comes <out>/proof.zip: proof.json at its top and
# each screen at screens/<id>.png. Each screen is an item, its id stable from
# release to release (rename a fixture screen only on purpose):
#   ios-<screen>.png            ios/phone/<screen>
#   ios-<screen>-landscape.png  ios/phone-landscape/<screen>
#   mac-<screen>.png            macos/window/<screen>
#   android-<screen>.png        android/phone/<screen>
# <version> is what it is a proof of: the build's (alpha sets it as it
# attaches the proof: tools/ci/proof_version.sh), else the committed line.
#
# Fails when no screen came, or a name makes no id.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ $# -ge 2 ] || { echo "usage: tools/ci/proof_make.sh <parts> <out> [<version>]" >&2; exit 2; }
parts="$(cd "$1" && pwd)"
mkdir -p "$2"
out="$(cd "$2" && pwd)"
version="${3:-$(sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$ROOT/applications/visor_ios/Info.plist")}"
commit="$(git -C "$ROOT" rev-parse HEAD)"

python3 -I - "$parts" "$out" "$version" "$commit" "${GITHUB_REPOSITORY:-AttilaTheFun/visor}" "${GITHUB_RUN_ID:-}" << 'PY'
import datetime, hashlib, json, os, re, struct, sys, zipfile
parts, out, version, commit, repository, run = sys.argv[1:7]
forms = {"ios": ("ios", "phone", "an iPhone"), "mac": ("macos", "window", "the Mac"), "android": ("android", "phone", "Android")}
order = ["ios", "mac", "android"]
valid = re.compile(r"^[a-z0-9][a-z0-9.-]*$")

def size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        sys.exit(f"proof_make: {path} is not a PNG")
    return struct.unpack(">II", head[16:24])

items, files = [], []
folders = {name[len("part-"):] if name.startswith("part-") else name: os.path.join(parts, name)
           for name in os.listdir(parts) if os.path.isdir(os.path.join(parts, name))}
for platform in [p for p in order if p in folders] + sorted(p for p in folders if p not in order):
    if platform not in forms:
        sys.exit(f"proof_make: no ids for a part named {platform}")
    system, form, words = forms[platform]
    screens = os.path.join(folders[platform], "screens")
    for name in sorted(os.listdir(screens)) if os.path.isdir(screens) else []:
        if not name.endswith(".png"):
            continue
        stem = name[:-4]
        if not stem.startswith(platform + "-"):
            sys.exit(f"proof_make: {platform}'s {name} isn't named {platform}-<screen>.png")
        screen, place, landscape = stem[len(platform) + 1:], form, ""
        if platform == "ios" and screen.endswith("-landscape"):
            screen, place, landscape = screen[:-len("-landscape")], form + "-landscape", ", on its side"
        if not valid.match(screen):
            sys.exit(f"proof_make: {name} makes no id (lowercase letters, digits, - and . only)")
        item_id = f"{system}/{place}/{screen}"
        path = os.path.join(screens, name)
        with open(path, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()
        width, height = size(path)
        file = f"screens/{item_id}.png"
        items.append({"id": item_id, "kind": "screen", "title": f"{screen.replace('-', ' ').capitalize()} on {words}{landscape}",
                      "file": file, "sha256": digest, "width": width, "height": height})
        files.append((path, file))
if not items:
    sys.exit("proof_make: no screens came back from the platforms")
# Shown in this order: by platform, the upright screens before those on
# their side, then by name.
rank = {system: index for index, system in enumerate(forms[p][0] for p in order)}
paired = sorted(zip(items, files), key=lambda pair: (rank.get(pair[0]["id"].split("/")[0], 99), pair[0]["id"].split("/")[1], pair[0]["id"]))
items, files = [pair[0] for pair in paired], [pair[1] for pair in paired]
ids = [item["id"] for item in items]
duplicates = sorted({i for i in ids if ids.count(i) > 1})
if duplicates:
    sys.exit("proof_make: two screens make the same id: " + ", ".join(duplicates))

document = {"format": 2, "app": "Visor", "version": version, "repository": repository, "commit": commit,
            "run": int(run) if run else None,
            "made": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "items": items}
with zipfile.ZipFile(os.path.join(out, "proof.zip"), "w", zipfile.ZIP_STORED) as archive:
    archive.writestr("proof.json", json.dumps(document, indent=2) + "\n")
    for path, file in files:
        archive.write(path, file)
print(f"proof.zip: {len(items)} screens of {commit[:7]} ({version}): " + ", ".join(ids))
summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    lines = [f"### Proof of {commit[:7]} ({version}), format 2", "",
             "Reviews compares it with the prior release's, item by item.", "", "| Item | Size |", "| --- | --- |"]
    lines += [f"| {item['id']} | {item['width']}×{item['height']} |" for item in items]
    with open(summary, "a") as f:
        f.write("\n".join(lines) + "\n")
PY
