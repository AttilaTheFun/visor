#!/bin/bash
# A test runner's create_simulator_action (rules_apple's
# ios_xctestrun_runner): a simulator of the device type and iOS version the
# runner asks for (SIMULATOR_DEVICE_TYPE, SIMULATOR_OS_VERSION), booted; its
# UDID the only line on stdout.
#
# Not rules_apple's creator, which takes the first runtime of the version
# whether or not it runs the device: Xcode 27.2 has two iOS 27.2 runtimes,
# the general one and one for a single newer iPhone
# (iOS-27-2-iPhone19-4), listed first, and that one cannot make an iPhone
# 17 ("Incompatible device"). This one takes a runtime that lists the
# device among the types it runs: of the version asked for, else the newest.
#
# Nor does it reuse a simulator when the runner says not to (rules_apple's
# reuses its BAZEL_TEST_<device>_<os> whatever the runner says: the runner
# sets SIMULATOR_REUSE_SIMULATOR to "" for no, and the creator only asks
# whether it is set). With reuse (the runner's default), the simulator of
# that name on the runtime is reused, or made; without, a new one is made
# under a name of its own (BAZEL_TEST_<device>_<os>-<time>-<pid>), for the
# runner's clean-up to delete.
set -euo pipefail
picked="$(python3 - "$SIMULATOR_DEVICE_TYPE" "${SIMULATOR_OS_VERSION:-}" <<'PY'
import json, subprocess, sys
device, version = sys.argv[1], sys.argv[2]
listing = json.loads(subprocess.run(["xcrun", "simctl", "list", "-j"],
                                    check=True, capture_output=True, text=True).stdout)
kind = next((t["identifier"] for t in listing["devicetypes"] if t["name"] == device), None)
if not kind:
    sys.exit(f"no simulator device type here is named {device}")
runtimes = [r for r in listing["runtimes"]
            if r["platform"] == "iOS" and r["isAvailable"]
            and any(t["identifier"] == kind for t in r.get("supportedDeviceTypes", []))]
if not runtimes:
    sys.exit(f"no iOS runtime here runs an {device}")
runtime = next((r for r in runtimes if version and r["version"] == version), None)
if not runtime:
    runtime = runtimes[-1]
    if version:
        print(f"no iOS {version} runtime here runs an {device}: iOS {runtime['version']}", file=sys.stderr)
name = f"BAZEL_TEST_{device}_{runtime['version']}"
udid = next((d["udid"] for d in listing["devices"].get(runtime["identifier"], []) if d["name"] == name), "-")
print(kind, runtime["identifier"], udid, name)
PY
)"
read -r kind runtime udid name <<< "$picked"
echo "Selected simulator runtime $runtime" >&2
if [ -z "${SIMULATOR_REUSE_SIMULATOR:-}" ]; then
  udid="-"
  name="$name-$(date +%s)-$$"
fi
if [ "$udid" = "-" ]; then
  udid="$(xcrun simctl create "$name" "$kind" "$runtime")"
  echo "Created new simulator '$name' ($udid)" >&2
fi
if ! xcrun simctl list devices booted | grep -qF "$udid"; then
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >&2
  # As rules_apple's creator waits: the tests could still find the
  # simulator not ready just after bootstatus.
  sleep 3
fi
echo "$udid"
