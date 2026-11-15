#!/bin/bash
# Visor for Android's release-built APK signed with its private release key
# (Logan, 2026-11-15: signing is hermetic, in CI's own container, with the
# key from Shireworks' secret service, pinned), by tools/ci/android_sign.sh
# (copied from AttilaTheFun/shireworks) with the repository's own pinned
# tools: Isomer's hermetic JDK (@hermetic_jdk) and
# @android_build_tools' apksigner.jar, built here, never the image's.
#
#   tools/ci/sign_android.sh --pin <sha256> <in.apk> <out.apk>
#
# <in.apk> is //applications/visor_android:visor_android_apk as CI built it
# (zipaligned, signed by its build with Isomer's debug key, which is
# replaced). The key's secrets (android-visor-keystore and
# android-visor-password) are released only to the jobs
# .github/shireworks-secrets.json grants them to: alpha and
# release-android. --pin is the release certificate's SHA-256, from the
# workflow.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "sign_android: $*" >&2; exit 1; }

pin=""
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --pin) pin="${2:?--pin takes the SHA-256 of the certificate}"; shift 2 ;;
    -*) fail "unknown option $1" ;;
    *) files+=("$1"); shift ;;
  esac
done
[ -n "$pin" ] && [ ${#files[@]} -eq 2 ] || fail "usage: tools/ci/sign_android.sh --pin <sha256> <in.apk> <out.apk>"

cd "$ROOT"
tools=(@hermetic_jdk//:Contents/Home/bin/java @android_build_tools//:lib/apksigner.jar)
bazel build "${tools[@]}"
# Each tool's file in its repository, as Bazel fetched it (the JDK whole,
# so its java runs with its own lib/).
base="$(bazel info output_base)"
path() { bazel cquery "$1" --output=files 2> /dev/null | sed -n '1p'; }
java="$base/$(path "${tools[0]}")"
apksigner="$base/$(path "${tools[1]}")"
[ -x "$java" ] || fail "no java at $java"
[ -f "$apksigner" ] || fail "no apksigner.jar at $apksigner"

exec "$ROOT/tools/ci/android_sign.sh" --app visor --pin "$pin" \
  --java "$java" --apksigner "$apksigner" "${files[0]}" "${files[1]}"
