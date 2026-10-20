#!/bin/sh
# Whether every dependency is pinned to a released version: a SwiftPM
# package by version (exact:, from:, a range), not a revision or a branch;
# a Bazel module from the registry, not a git, archive or local override.
# A branch may pin a revision while what it needs is in development; a
# release may not. CI runs this on main's commits, which releases are of,
# and Reviews holds a release until it passes.
cd "$(dirname "$0")/.." || exit 1
status=0
for manifest in $(git ls-files 'Package.swift' '*/Package.swift'); do
  if grep -n -E '(revision|branch):[[:space:]]*"|\.package\([[:space:]]*path:' "$manifest"; then
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
