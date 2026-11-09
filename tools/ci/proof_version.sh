#!/bin/bash
# A proof (tools/ci/proof_make.sh's proof.zip) saying the version it is a
# proof of: verify makes it before the version is known, and alpha, which
# asks Applications Server for it, sets it as it puts the proof among the
# release's assets (AttilaTheFun/reviews' docs/PROOF_FORMAT.md). The rest,
# files and all, is kept as it was.
#
#   tools/ci/proof_version.sh <proof.zip> <version> <out.zip>
set -euo pipefail
[ $# -eq 3 ] || { echo "usage: tools/ci/proof_version.sh <proof.zip> <version> <out.zip>" >&2; exit 2; }
python3 -I - "$1" "$2" "$3" << 'PY'
import json, sys, zipfile
source, version, target = sys.argv[1:4]
with zipfile.ZipFile(source) as given:
    document = json.loads(given.read("proof.json"))
    if document.get("format") != 2:
        sys.exit(f"proof_version: {source} is not a proof of format 2")
    document["version"] = version
    with zipfile.ZipFile(target, "w", zipfile.ZIP_STORED) as made:
        made.writestr("proof.json", json.dumps(document, indent=2) + "\n")
        for entry in given.infolist():
            if entry.filename != "proof.json":
                made.writestr(entry, given.read(entry.filename))
print(f"proof.zip of {document['commit'][:7]} says {version}")
PY
