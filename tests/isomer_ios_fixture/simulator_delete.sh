#!/bin/bash
# The runner's clean-up: the simulator it made for this run, gone (each run
# makes its own; none is shared with another session's tests).
xcrun simctl shutdown "$SIMULATOR_UDID" 2>/dev/null || true
xcrun simctl delete "$SIMULATOR_UDID" 2>/dev/null || true
