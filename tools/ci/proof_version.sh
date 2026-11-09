#!/bin/bash
# A proof (tools/ci/proof_make.sh's: proof.zip, or its folder as the run's
# `proof` artifact downloads) as proof.zip saying the version it is a proof
# of: verify makes it before the version is known, and alpha, which asks
# Applications Server for it, sets it as it puts the proof among the
# release's assets (AttilaTheFun/reviews' docs/PROOF_FORMAT.md). The rest,
# files and all, is kept as it was.
#
#   tools/ci/proof_version.sh <proof.zip | proof folder> <version> <out.zip>
set -euo pipefail
[ $# -eq 3 ] || { echo "usage: tools/ci/proof_version.sh <proof.zip | proof folder> <version> <out.zip>" >&2; exit 2; }
python3 -I - "$1" "$2" "$3" << 'PY'
import json, os, sys, zipfile
source, version, target = sys.argv[1:4]
if os.path.isdir(source):
    names = sorted(os.path.relpath(os.path.join(top, name), source) for top, _, files in os.walk(source) for name in files)
    read = lambda name: open(os.path.join(source, name), "rb").read()
else:
    given = zipfile.ZipFile(source)
    names = [entry.filename for entry in given.infolist() if not entry.is_dir()]
    read = given.read
if "proof.json" not in names:
    sys.exit(f"proof_version: {source} has no proof.json at its top")
document = json.loads(read("proof.json"))
if document.get("format") != 2:
    sys.exit(f"proof_version: {source} is not a proof of format 2")
document["version"] = version
with zipfile.ZipFile(target, "w", zipfile.ZIP_STORED) as made:
    made.writestr("proof.json", json.dumps(document, indent=2) + "\n")
    for name in names:
        if name != "proof.json":
            made.writestr(name, read(name))
print(f"proof.zip of {document['commit'][:7]} says {version}")
PY
