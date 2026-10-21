#!/bin/bash
# The runner's pre_action: the fresh simulator it made ($SIMULATOR_UDID),
# booted, in the light look, with the status bar red Visor's CI pictures
# (visor's .github/workflows/ci.yml, ios-ui), so blue's pictures and red's
# can be compared pixel for pixel.
set -eu
xcrun simctl boot "$SIMULATOR_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_UDID" -b >/dev/null
xcrun simctl ui "$SIMULATOR_UDID" appearance light
xcrun simctl status_bar "$SIMULATOR_UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
