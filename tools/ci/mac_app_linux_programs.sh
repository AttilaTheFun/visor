#!/bin/bash
# Seals Visor's own Linux programs into a Mac app's .zip, as
# tools/release_mac.sh puts them in the app it signs: in
# Contents/Resources/Linux, visor-server and visor-agent-host (a link to
# it, kept a link), the programs a Visor server mounts read-only into the
# containers it makes, and relay-client (a link to it too), agent-proxy's
# end in a relayed container (docs/agent-proxy.md), and agent-wrapper
# (agent_protocol's, a program of its own), each Sessions container
# session's agent (docs/containers.md). The tar is
# tools/ci/linux_programs.sh's (CI's linux-programs job). The entries are
# appended to the .zip as it is, with their Unix modes; nothing Bazel built
# is unpacked or packed again. CI's signing job then signs the app around
# them (tools/ci/sign_builds.sh).
#
# Given a third file, the container.json //tools/container_manifest wrote
# (docs/containers.md: the Sessions container's image digest and pins), it
# goes in as Contents/Resources/container.json beside them.
#
#   tools/ci/mac_app_linux_programs.sh <Mac app .zip> <linux-programs .tar> [<container.json>]
#
# Fails if the tar lacks any of the four (or the links aren't links to
# visor-server, or agent-wrapper isn't a program), or the app has them
# already.
set -euo pipefail
[ $# -eq 2 ] || [ $# -eq 3 ] \
  || { echo "usage: tools/ci/mac_app_linux_programs.sh <Mac app .zip> <linux-programs .tar> [<container.json>]" >&2; exit 2; }
python3 -I - "$@" <<'PY'
import json, stat, sys, tarfile, zipfile

app_zip, programs = sys.argv[1:3]
manifest = sys.argv[3] if len(sys.argv) > 3 else None

def fail(message):
    sys.exit(f"mac_app_linux_programs: {message}")

with tarfile.open(programs) as tar:
    members = {member.name.removeprefix("./"): member for member in tar.getmembers()}
    server, host, relay = members.get("visor-server"), members.get("visor-agent-host"), members.get("relay-client")
    if server is None or not server.isfile() or not server.mode & 0o111:
        fail(f"{programs} has no visor-server program")
    if host is None or not host.issym() or host.linkname != "visor-server":
        fail(f"{programs}'s visor-agent-host is not a link to visor-server")
    if relay is None or not relay.issym() or relay.linkname != "visor-server":
        fail(f"{programs}'s relay-client is not a link to visor-server")
    wrapper = members.get("agent-wrapper")
    if wrapper is None or not wrapper.isfile() or not wrapper.mode & 0o111:
        fail(f"{programs} has no agent-wrapper program")
    server_bytes = tar.extractfile(server).read()
    wrapper_bytes = tar.extractfile(wrapper).read()

with zipfile.ZipFile(app_zip) as archive:
    names = archive.namelist()
apps = {name.split("/", 1)[0] for name in names if name.split("/", 1)[0].endswith(".app")}
if len(apps) != 1:
    fail(f"{app_zip} holds {len(apps)} apps, not one")
app = apps.pop()
folder = f"{app}/Contents/Resources/Linux/"
if any(name.startswith(folder) for name in names):
    fail(f"{app_zip} has {folder} already")
manifest_name = f"{app}/Contents/Resources/container.json"
manifest_bytes = None
if manifest is not None:
    if manifest_name in names:
        fail(f"{app_zip} has {manifest_name} already")
    with open(manifest, "rb") as handle:
        manifest_bytes = handle.read()
    if "image" not in json.loads(manifest_bytes):
        fail(f"{manifest} is not a container.json")

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
    archive.writestr(entry(folder + "agent-wrapper", stat.S_IFREG | 0o755), wrapper_bytes,
                     compress_type=zipfile.ZIP_DEFLATED)
    # A link is stored as its target, uncompressed.
    for link in ("visor-agent-host", "relay-client"):
        archive.writestr(entry(folder + link, stat.S_IFLNK | 0o777), b"visor-server",
                         compress_type=zipfile.ZIP_STORED)
    if manifest_bytes is not None:
        archive.writestr(entry(manifest_name, stat.S_IFREG | 0o644), manifest_bytes, compress_type=zipfile.ZIP_DEFLATED)
print(f"{folder}visor-server and agent-wrapper, and visor-agent-host and relay-client -> visor-server, into {app_zip}")
if manifest_bytes is not None:
    print(f"{manifest_name}, into {app_zip}")
PY
