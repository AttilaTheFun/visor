#!/bin/bash
# Checks, before a Mac app's .zip is published, that what Applications Server
# signs it from is there: the server signs each piece of code again with the
# entitlements its signature already carries (`codesign -d --entitlements`),
# so an app built unsigned would lose them (the microphone, Visor.app's).
# rules_apple signs the app ad hoc with its entitlements, on Linux too (the
# cross toolchain's codesign); this says so or fails. The app's executable
# (its CFBundleExecutable) must have a code signature (LC_CODE_SIGNATURE)
# holding each entitlement named, and every program in Contents/Helpers a
# signature of its own.
#
#   tools/ci/mac_app_signed.sh <Mac app .zip> [<entitlement>…]
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: tools/ci/mac_app_signed.sh <Mac app .zip> [<entitlement>…]" >&2; exit 2; }
python3 -I - "$@" <<'PY'
import plistlib, struct, sys, zipfile

app_zip, wanted = sys.argv[1], sys.argv[2:]

def fail(message):
    sys.exit(f"mac_app_signed: {message}")

def signature(data, name):
    """The bytes of a Mach-O's code signature, or None. A universal binary's
    first slice (Visor's Mac builds are arm64 alone)."""
    if data[:4] in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
        offset, = struct.unpack(">I", data[16:20])  # fat_arch[0].offset
        data = data[offset:]
    if data[:4] != b"\xcf\xfa\xed\xfe":  # MH_MAGIC_64, little-endian
        fail(f"{name} is not a 64-bit Mach-O")
    ncmds, = struct.unpack("<I", data[16:20])
    at = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack("<II", data[at:at + 8])
        if cmd == 0x1D:  # LC_CODE_SIGNATURE: a linkedit_data_command
            dataoff, datasize = struct.unpack("<II", data[at + 8:at + 16])
            return data[dataoff:dataoff + datasize]
        at += size
    return None

with zipfile.ZipFile(app_zip) as archive:
    names = archive.namelist()
    apps = {name.split("/", 1)[0] for name in names if name.split("/", 1)[0].endswith(".app")}
    if len(apps) != 1:
        fail(f"{app_zip} holds {len(apps)} apps, not one")
    app = apps.pop()
    info = plistlib.loads(archive.read(f"{app}/Contents/Info.plist"))
    executable = f"{app}/Contents/MacOS/{info['CFBundleExecutable']}"
    signed = signature(archive.read(executable), executable)
    if signed is None:
        fail(f"{executable} has no code signature")
    for entitlement in wanted:
        if f"<key>{entitlement}</key>".encode() not in signed:
            fail(f"{executable}'s signature doesn't carry {entitlement}")
    helpers = [name for name in names if name.startswith(f"{app}/Contents/Helpers/") and not name.endswith("/")]
    for helper in helpers:
        if signature(archive.read(helper), helper) is None:
            fail(f"{helper} has no code signature")
print(f"{executable}: signed, with {', '.join(wanted) or 'no entitlement asked for'}; "
      f"{len(helpers)} helper{'s' if len(helpers) != 1 else ''} signed")
PY
