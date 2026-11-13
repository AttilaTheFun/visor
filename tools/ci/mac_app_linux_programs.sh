#!/bin/bash
# Seals Visor's own Linux programs into a Mac app's .zip, as
# tools/release_mac.sh puts them in the app it signs: in
# Contents/Resources/Linux, visor-server and visor-agent-host (a link to
# it, kept a link), the programs a Visor server mounts read-only into the
# containers it makes. The tar is
# tools/ci/linux_programs.sh's (CI's linux-programs job). The entries are
# appended to the .zip as it is, with their Unix modes; nothing Bazel built
# is unpacked or packed again. Applications Server, which the .zip is
# published to, then signs the app around them (tools/ci/publish_from_ci.sh).
#
#   tools/ci/mac_app_linux_programs.sh <Mac app .zip> <linux-programs .tar>
#
# Fails if the tar isn't the two programs, or the app has them already.
set -euo pipefail
[ $# -eq 2 ] || { echo "usage: tools/ci/mac_app_linux_programs.sh <Mac app .zip> <linux-programs .tar>" >&2; exit 2; }
python3 -I - "$1" "$2" <<'PY'
import stat, sys, tarfile, zipfile

app_zip, programs = sys.argv[1:3]

def fail(message):
    sys.exit(f"mac_app_linux_programs: {message}")

with tarfile.open(programs) as tar:
    members = {member.name.removeprefix("./"): member for member in tar.getmembers()}
    server, host = members.get("visor-server"), members.get("visor-agent-host")
    if server is None or not server.isfile() or not server.mode & 0o111:
        fail(f"{programs} has no visor-server program")
    if host is None or not host.issym() or host.linkname != "visor-server":
        fail(f"{programs}'s visor-agent-host is not a link to visor-server")
    server_bytes = tar.extractfile(server).read()

with zipfile.ZipFile(app_zip) as archive:
    names = archive.namelist()
apps = {name.split("/", 1)[0] for name in names if name.split("/", 1)[0].endswith(".app")}
if len(apps) != 1:
    fail(f"{app_zip} holds {len(apps)} apps, not one")
folder = f"{apps.pop()}/Contents/Resources/Linux/"
if any(name.startswith(folder) for name in names):
    fail(f"{app_zip} has {folder} already")

def entry(name, mode):
    info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
    info.create_system = 3  # Unix, so the mode below is read.
    info.external_attr = mode << 16
    return info

with zipfile.ZipFile(app_zip, "a") as archive:
    directory = entry(folder, stat.S_IFDIR | 0o755)
    directory.external_attr |= 0x10  # MS-DOS directory bit, as zip writes it.
    archive.writestr(directory, b"")
    archive.writestr(entry(folder + "visor-server", stat.S_IFREG | 0o755), server_bytes,
                     compress_type=zipfile.ZIP_DEFLATED)
    # A link is stored as its target, uncompressed.
    archive.writestr(entry(folder + "visor-agent-host", stat.S_IFLNK | 0o777), b"visor-server",
                     compress_type=zipfile.ZIP_STORED)
print(f"{folder}visor-server and visor-agent-host -> visor-server, into {app_zip}")
PY
