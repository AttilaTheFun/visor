#!/bin/bash
# Builds the Android client OPTIMIZED, installs it on a connected device, and
# compiles it ahead of time there. It does not launch the app.
#
#   tools/isomer/install_android.sh [device serial]
#
# Always `-c opt`: a fastbuild APK is debuggable, so ART runs its Kotlin and
# Compose largely interpreted, and its Swift is unoptimized. On a long
# transcript that's the difference between smooth and choppy scrolling
# (about 2x the main-thread time and 5x the janky frames).
set -euo pipefail
cd "$(dirname "$0")/../.."
SERIAL="${1:-${ANDROID_SERIAL:-}}"
TARGET=//applications/visor_android:visor_android_apk
bazel build -c opt "$TARGET"
APK="$(bazel cquery -c opt --output=files "$TARGET" 2>/dev/null | grep -v unsigned | grep '\.apk$' | head -1)"
ADB="$(find -L "$(bazel info output_base)/external" -maxdepth 4 -path '*androidsdk*platform-tools*' -name adb -type f 2>/dev/null | head -1)"
ADB="${ADB:-adb}"
"$ADB" ${SERIAL:+-s "$SERIAL"} install -r "$APK"
# Compile it ahead of time now. A sideloaded app otherwise runs interpreted
# and JIT-compiled until the phone's idle maintenance gets to it (the Play
# Store does this at install): scrolling a long transcript cost 8% of the
# main thread interpreted against 3% compiled, and a p99 frame 32 against 19 ms.
"$ADB" ${SERIAL:+-s "$SERIAL"} shell cmd package compile -m speed -f com.loganshire.visor >/dev/null
# Not launched: on a person's own phone an agent installs and stops (AGENTS.md).
"$ADB" ${SERIAL:+-s "$SERIAL"} shell dumpsys package com.loganshire.visor | grep -E "versionName|versionCode" || true
echo "installed $APK"
