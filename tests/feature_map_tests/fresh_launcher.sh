#!/bin/bash
# Visor's workaround, until Isomer's launchers do these themselves: the
# app's data cleared, then Isomer's launcher for the platform
# (VISOR_LAUNCHER, @isomer//drive/launchers) run with the same arguments and
# environment, and stopped as soon as the test's HeadlessApp.quit() asks. A headless client keeps its settings in memory
# and starts empty every launch; a headful app keeps the computers a test
# added (Add Computer) in its preferences, so the next test's empty client
# would not be one (Launch → Onboarding). Isomer's ios_launcher.sh and
# android_launcher.sh stop the app but keep its data. And quit() first
# leaves a `stop` file beside the picture requests and waits ten seconds
# for the launcher to end before it sends SIGTERM; only Windows' launcher
# looks for the file, so every launch of the others cost ten seconds more
# (isomer 0.52.1: HeadlessApp.quit, drive/launchers/requests.sh): this one
# ends the launcher on seeing it.
#
#   fresh_launcher.sh <the hub's ws:// URL> <the app's name> [KEY=VALUE…]
#
# A test's launch settings come as `visor.<key>=<value>` (VisorLaunch.swift),
# the names a native app reads from its environment, and go on so to the
# iPhone's (SIMCTL_CHILD_visor.<key>), the Mac's, Linux's and Windows'
# launchers; Android's intent extras take the settings' own names
# (VisorServices.kt), so its launcher gets `<key>=<value>`.
#
# From the test's environment: VISOR_LAUNCHER (Isomer's launcher, as the
# test names it: relative to its runfiles' workspace), and the launcher's
# own (ISOMER_SIMULATOR and ISOMER_BUNDLE_ID; ISOMER_ANDROID_PACKAGE, ADB,
# ANDROID_SERIAL; ISOMER_MAC_APP).
set -uo pipefail
launcher="${VISOR_LAUNCHER:?VISOR_LAUNCHER: the launcher of Isomer for the platform}"
# A runfiles path (`../isomer+/drive/launchers/ios_launcher.sh`, Bazel's
# rootpath of another module's file): the runfiles tree's own entry.
case "$launcher" in
    /*) ;;
    ../*) launcher="${TEST_SRCDIR:?}/${launcher#../}" ;;
    *) launcher="${TEST_SRCDIR:?}/${TEST_WORKSPACE:-_main}/$launcher" ;;
esac
platform="$(basename "$launcher")"
if [ "$platform" = ios_launcher.sh ]; then
    udid="${ISOMER_SIMULATOR:?ISOMER_SIMULATOR: a booted simulator}"
    bundle="${ISOMER_BUNDLE_ID:?ISOMER_BUNDLE_ID: the app installed on it}"
    xcrun simctl terminate "$udid" "$bundle" > /dev/null 2>&1 || true
    # Its preferences through cfprefsd (a file removed under it comes
    # back), then its files; the passwords of the computers it kept, with
    # the simulator's keychain.
    xcrun simctl spawn "$udid" defaults delete "$bundle" > /dev/null 2>&1 || true
    data="$(xcrun simctl get_app_container "$udid" "$bundle" data 2> /dev/null || true)"
    if [ -n "$data" ] && [ -d "$data" ]; then
        rm -rf "$data/Documents/"* "$data/Library/Application Support" "$data/Library/Caches" "$data/tmp/"* 2> /dev/null || true
    fi
    xcrun simctl keychain "$udid" reset > /dev/null 2>&1 || true
elif [ "$platform" = android_launcher.sh ]; then
    exec < /dev/null
    "${ADB:-adb}" shell pm clear "${ISOMER_ANDROID_PACKAGE:?ISOMER_ANDROID_PACKAGE: the app}" > /dev/null 2>&1 || true
    # The settings' own names, for the intent's extras.
    arguments=("$1" "$2")
    shift 2
    for pair in "$@"; do
        case "$pair" in
            visor.*=*) arguments+=("${pair#visor.}") ;;
            *) arguments+=("$pair") ;;
        esac
    done
    set -- "${arguments[@]}"
fi
# (The Mac launcher gives the app a home of its own each launch,
# CFFIXED_USER_HOME: nothing kept to clear.)
"$launcher" "$@" &
child=$!
stop() {
    kill -TERM "$child" 2> /dev/null
    wait "$child" 2> /dev/null
    exit 0
}
trap stop TERM INT
while kill -0 "$child" 2> /dev/null; do
    if [ -n "${ISOMER_LAUNCHER_REQUESTS:-}" ] && [ -e "$ISOMER_LAUNCHER_REQUESTS/stop" ]; then stop; fi
    sleep 0.2
done
wait "$child"
