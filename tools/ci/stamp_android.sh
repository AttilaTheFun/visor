#!/bin/bash
# Stamps a publishing job's checkout with its build's version for the
# Android app, before it is built: the version the Apple apps were given
# (tools/ci/version_from_tags.sh, in the Info.plists) or a release's tag's,
# into applications/visor_android's BUILD: its versionName, and its
# versionCode, MAJOR x 1,000,000 + MINOR x 1,000 + BUILD (AGENTS.md). Never
# committed: each job checks out afresh. As AttilaTheFun/reviews'
# tools/ci/stamp_apps.sh does its Android app's.
#
#   tools/ci/stamp_android.sh <MAJOR.MINOR.BUILD>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
android="$ROOT/applications/visor_android/BUILD.bazel"
version="${1:?usage: tools/ci/stamp_android.sh <MAJOR.MINOR.BUILD>}"
case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "stamp_android: \"$version\" is not MAJOR.MINOR.BUILD" >&2; exit 1 ;;
esac
IFS=. read -r major minor build <<< "$version"
# The parts as numbers (a leading zero isn't octal), each within its place.
major=$((10#$major)) minor=$((10#$minor)) build=$((10#$build))
[ "$minor" -lt 1000 ] && [ "$build" -lt 1000 ] || { echo "stamp_android: $version doesn't fit a versionCode's places" >&2; exit 1; }
code=$((major * 1000000 + minor * 1000 + build))

# The BUILD's one version_code and version_name, as committed; each must be
# there to be stamped.
for key in version_code version_name; do
    [ "$(grep -cE "^ *$key = " "$android")" = 1 ] || { echo "stamp_android: $android has no single $key" >&2; exit 1; }
done
sed -E -e "s/^( *version_code = )[0-9]+,/\1$code,/" -e "s/^( *version_name = )\"[^\"]*\",/\1\"$version\",/" "$android" > "$android.stamped"
mv "$android.stamped" "$android"
grep -qE "^ *version_code = $code,$" "$android" && grep -qE "^ *version_name = \"$version\",$" "$android" \
    || { echo "stamp_android: $android was not stamped" >&2; exit 1; }
echo "stamp_android: Visor for Android is $version (versionCode $code)"
