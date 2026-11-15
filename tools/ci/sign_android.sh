#!/bin/bash
# Visor for Android's release-built APK signed with its private release key,
# by tools/ci/android_sign.sh (copied from AttilaTheFun/shireworks) with the
# repository's own pinned tools, never the image's: the JDK Visor's Bazel
# runs Java with (rules_java's remotejdk_17, .bazelrc's
# --java_runtime_version; Isomer's @hermetic_jdk is laid out for a Mac
# alone) and @android_build_tools' apksigner.jar.
#
#   tools/ci/sign_android.sh --pin <sha256> <in.apk> <out.apk>
#
# <in.apk> is //applications/visor_android:visor_android_apk as CI built it
# (zipaligned, signed by its build with Isomer's debug key, which is
# replaced). The key comes from the job's environment (Logan, 2026-11-15: a
# public repository signs with keys in its GitHub secrets):
# ANDROID_SIGNING_KEYSTORE (the PKCS12, base64, its alias `visor`) and
# ANDROID_SIGNING_PASSWORD, the secrets of Visor's GitHub environment
# `release` (deployments from main and v* tags alone), given only to the
# step that signs, in the jobs that do: alpha and release-android. --pin is
# the release certificate's SHA-256, from the workflow: a key that isn't
# Visor's signs nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "sign_android: $*" >&2; exit 1; }

pin=""
files=()
while [ $# -gt 0 ]; do
  case "$1" in
    --pin) pin="${2:?--pin takes the SHA-256 of the certificate}"; shift 2 ;;
    -*) fail "unknown option $1" ;;
    # Isomer's APK rule leaves an unsigned sibling beside the APK it
    # signs with the debug key, and ci.yml passes both (`*.apk`): the
    # signed, zip-aligned one is the one re-signed here.
    *_unsigned.apk) shift ;;
    *) files+=("$1"); shift ;;
  esac
done
[ -n "$pin" ] && [ ${#files[@]} -eq 2 ] || fail "usage: tools/ci/sign_android.sh --pin <sha256> <in.apk> <out.apk>"
[ -n "${ANDROID_SIGNING_KEYSTORE:-}" ] && [ -n "${ANDROID_SIGNING_PASSWORD:-}" ] \
  || fail "ANDROID_SIGNING_KEYSTORE and ANDROID_SIGNING_PASSWORD aren't both set: the step that signs takes them from the release environment's secrets"
# Out of the environment while Bazel runs: a Bazel server it starts keeps
# the environment it was started with, for hours. Given back to
# android_sign.sh alone, which reads them once and unsets them.
keystore="$ANDROID_SIGNING_KEYSTORE" password="$ANDROID_SIGNING_PASSWORD"
unset ANDROID_SIGNING_KEYSTORE ANDROID_SIGNING_PASSWORD

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

ANDROID_SIGNING_KEYSTORE="$keystore" ANDROID_SIGNING_PASSWORD="$password" \
  exec "$ROOT/tools/ci/android_sign.sh" --key-from-env --app visor --pin "$pin" \
  --java "$java" --apksigner "$apksigner" "${files[0]}" "${files[1]}"
