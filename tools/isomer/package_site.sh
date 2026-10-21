#!/bin/bash
# Packages the web client as visor-isomer-site.tar.gz, the asset a GitHub
# release carries and .github/workflows/pages.yml puts up beside the site, at
# https://attilathefun.github.io/visor/app/. NOT run by any build or test:
# publishing is deliberate.
#
#   tools/isomer/package_site.sh [--out <file>]
#
# Builds the site with -c opt (a fastbuild wasm overflows Safari's JS stack),
# tests it with the end-to-end test (tools/isomer/e2e/run.py <site>: the client
# against the stand-in server, on all three roads), and writes the archive:
# the site at its root, with a .nojekyll. Then:
#   gh release upload <tag> visor-isomer-site.tar.gz
# before the release is published, or run pages.yml by hand after.
set -euo pipefail
OUT="$PWD/visor-isomer-site.tar.gz"
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2;;
        *) echo "usage: package_site.sh [--out <file>]" >&2; exit 2;;
    esac
done
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT";; esac
cd "$(dirname "$0")/../.."
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
bazel build -c opt //applications/visor_web:visor_web_site
SITE="$(bazel cquery -c opt --output=files //applications/visor_web:visor_web_site 2>/dev/null | head -1)"
cp -RL "$SITE"/. "$WORK"/
chmod -R u+w "$WORK"
touch "$WORK/.nojekyll"
python3 tools/isomer/e2e/run.py "$WORK"
tar -czf "$OUT" -C "$WORK" .
echo "wrote $OUT ($(du -h "$OUT" | cut -f1)), built on $(git rev-parse --short HEAD)"
