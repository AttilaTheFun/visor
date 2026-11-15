#!/bin/bash
# Visor for Android's release-built APK signed with its private release key
# (Logan, 2026-11-15: signing is hermetic, in CI's own container, with the
# key from Shireworks' secret service, pinned), by tools/ci/android_sign.sh
# (copied from AttilaTheFun/shireworks) with the repository's own pinned
# tools, never the image's: the JDK Visor's Bazel runs Java with
# (rules_java's remotejdk_17, .bazelrc's --java_runtime_version; Isomer's
# @hermetic_jdk is laid out for a Mac alone) and @android_build_tools'
# apksigner.jar.
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
runtime=@rules_java//toolchains:current_java_runtime
jar=@android_build_tools//:lib/apksigner.jar
bazel build "$runtime" "$jar"
# Each tool's file in its repository, as Bazel fetched it (the JDK whole,
# so its java runs with its own lib/).
base="$(bazel info output_base)"
runtime_files="$(bazel cquery "$runtime" --output=files 2> /dev/null)"
jar_files="$(bazel cquery "$jar" --output=files 2> /dev/null)"
java="$base/$(printf '%s\n' "$runtime_files" | sed -n '\#/bin/java$#{p;q;}')"
apksigner="$base/$(printf '%s\n' "$jar_files" | sed -n '1p')"
[ -x "$java" ] || fail "no java at $java"
[ -f "$apksigner" ] || fail "no apksigner.jar at $apksigner"

exec "$ROOT/tools/ci/android_sign.sh" --app visor --pin "$pin" \
  --java "$java" --apksigner "$apksigner" "${files[0]}" "${files[1]}"
