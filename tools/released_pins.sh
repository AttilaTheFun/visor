#!/bin/sh
# Whether every dependency is pinned to a released version: a SwiftPM
# package by version (exact:, from:, a range), not a revision or a branch;
# a Bazel module from the registry, not a git, archive or local override.
# A branch may pin a revision while what it needs is in development; a
# release may not. CI runs this on main's commits, which releases are of,
# and Reviews holds a release until it passes.
cd "$(dirname "$0")/.." || exit 1
status=0
# One exception: isomer by the revision of a release's tag (`revision:
# "v0.44.2"`). Its own dependencies (swift-foundation, swift-syntax) are by
# revision and branch, so SwiftPM refuses to take it by version; the tag is
# a released version all the same (isomer's README, "Upgrading isomer").
for manifest in $(git ls-files 'Package.swift' '*/Package.swift'); do
  if awk '
    /\.package\(/ { url = "" }
    /url:[[:space:]]*"/ { url = $0 }
    /\.package\([[:space:]]*path:/ { print FILENAME ":" FNR ": " $0; bad = 1; next }
    /branch:[[:space:]]*"/ { print FILENAME ":" FNR ": " $0; bad = 1; next }
    /revision:[[:space:]]*"/ {
      if (url ~ /AttilaTheFun\/isomer(\.git)?"/ && $0 ~ /revision:[[:space:]]*"v[0-9]+\.[0-9]+\.[0-9]+"/) next
      print FILENAME ":" FNR ": " $0; bad = 1
    }
    END { exit bad ? 0 : 1 }' "$manifest"; then
    echo "$manifest: a package pinned to a revision or branch, not a released version" >&2
    status=1
  fi
done
for module in $(git ls-files 'MODULE.bazel' '*/MODULE.bazel'); do
  if grep -n -E '^[[:space:]]*(git_override|archive_override|local_path_override)\(' "$module"; then
    echo "$module: a module from git, an archive or a folder, not a registry release" >&2
    status=1
  fi
done
[ "$status" = 0 ] && echo "Every dependency is pinned to a released version."
exit "$status"
