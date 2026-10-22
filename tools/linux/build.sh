#!/bin/bash
# Builds the iOS app for the simulator on Linux, in rules_applecross's build
# container (see README.md), from a clone of REF (default main) in a VM volume.
# Writes .linux/visor_ios.ipa.
#
#   RULES_APPLECROSS=~/Developer/rules_applecross tools/linux/build.sh [--local] [REF]
set -euo pipefail

AC="${RULES_APPLECROSS:?set RULES_APPLECROSS to a rules_applecross checkout}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
mode=(--commit "$(git -C "$AC" rev-parse HEAD)")
if [ "${1:-}" = --local ]; then mode=(--local); shift; fi
REF="${1:-main}"
mkdir -p "$ROOT/.linux"

podman volume exists visor-src || podman volume create visor-src >/dev/null
export RULES_APPLECROSS_VOLUMES="visor-src:/src" RULES_APPLECROSS_WORKDIR=/src
"$AC/tools/linux_vm/run.sh" bash -euc "
  rm -rf /src/visor
  git clone -q https://github.com/AttilaTheFun/visor.git /src/visor
  cd /src/visor
  git checkout -q '$REF'
  git log --oneline -1
  RULES_APPLECROSS='$AC' '$HERE/integrate.sh' ${mode[*]}
  bazel build --ios_multi_cpus=sim_arm64 //applications/visor_ios:visor_ios
  cp -fL bazel-bin/applications/visor_ios/visor_ios.ipa '$ROOT/.linux/visor_ios.ipa'
"
shasum -a 256 "$ROOT/.linux/visor_ios.ipa"
