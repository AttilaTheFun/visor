#!/bin/bash
# The runner's create_simulator_action: a simulator of the fixture's own,
# named for this run (isomer-fixture-<time>-<pid>), of the runner's device
# type and iOS version; booted; its UDID the only line on stdout.
#
# Not rules_apple's: its creator names simulators BAZEL_TEST_<device>_<os>
# and reuses one of that name even when the runner says not to (the runner
# sets SIMULATOR_REUSE_SIMULATOR to "" for no, and the creator only asks
# whether it is set), so the fixture shared a simulator with any other
# session's Bazel tests on the Mac and pictured another app's alert.
# simulator_delete.sh removes this one after the run.
set -euo pipefail
ids="$(python3 - "$SIMULATOR_DEVICE_TYPE" "${SIMULATOR_OS_VERSION:-}" <<'PY'
import json, subprocess, sys
device, version = sys.argv[1], sys.argv[2]
listing = json.loads(subprocess.run(["xcrun", "simctl", "list", "-j", "devicetypes", "runtimes"],
                                    check=True, capture_output=True, text=True).stdout)
kind = next(t["identifier"] for t in listing["devicetypes"] if t["name"] == device)
runtimes = [r for r in listing["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
runtime = next((r for r in runtimes if version and r["version"] == version), runtimes[-1])
print(kind, runtime["identifier"])
PY
)"
read -r kind runtime <<< "$ids"
udid="$(xcrun simctl create "isomer-fixture-$(date +%s)-$$" "$kind" "$runtime")"
xcrun simctl boot "$udid" >&2 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >&2
echo "$udid"
