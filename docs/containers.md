# The Sessions container (from 0.64)

Each Mac's Visor runs one **Sessions container**: a Linux environment for
its sessions, on Apple's [Containerization](https://github.com/apple/containerization)
(each container its own lightweight VM, made by the framework: Visor
supplies a kernel, an init filesystem and an image, and writes no VM code
of its own). It lives in Visor's background server (`Visor --server`), so
quitting or reopening Visor.app leaves it running; an update of the server
restarts it, and its sessions resume from Sessions.

This is being built in steps. What's here now: **PR 1, the assets and
settings** (the Containerization dependency, the virtualization
entitlement, the assets fetched, checked and kept, Visor's Linux programs
staged for it, its settings and Settings' readiness row), and **PR 2, the
engine** (the container booted in the server agent, its relay to
agent-proxy, the egress check, processes exec'd in it, the idle stop, and
its status in the API and Settings). No session is placed in it yet: that's
step 4's.

## Requirements

- **Apple silicon and macOS 26 or later.** Visor itself still needs only
  macOS 15; the container's switch is off, and can't be turned on, unless
  this Mac is macOS 26 or later, Apple silicon, and
  `VZVirtualMachine.isSupported` (Virtualization can make a VM here: a macOS
  VM can't, as macOS doesn't nest).
- **The entitlement:** `com.apple.security.virtualization`, in
  `applications/visor_mac/app.entitlements` and `app.ci.entitlements`. It's
  unrestricted: no provisioning profile grants it, and an ad hoc build opens
  with it.
- **The Containers volume** (`/Volumes/Containers`), made by Visor Disk
  Utility. Without it, Visor refuses with a pointer to Visor Disk Utility.

## The assets

All of them are on the Containers volume, in `Visor/`. All of it can be
thrown away and made again (Visor Disk Utility's Erase Containers):

| Path | What | Pinned by |
| --- | --- | --- |
| `kernel/vmlinux` | The Linux kernel: Kata Containers 3.32.0's arm64 build (`opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug` in [kata-static-3.32.0-arm64.tar.zst](https://github.com/kata-containers/kata-containers/releases/download/3.32.0/kata-static-3.32.0-arm64.tar.zst)), the bytes Shireworks boots | The archive's SHA-256, `8736c054…e4b5` |
| `kernel/vmlinux.json` | What the kernel was taken from, and its own SHA-256 | |
| `store/` | Containerization's image store (`content/`, `state.json`) | |
| `store/initfs/<digest>.ext4` | The init filesystem (vminitd), unpacked from `ghcr.io/apple/containerization/vminit:0.57.0` | Its digest, `sha256:c30d5a14…e656` |
| `templates/<digest>-64.ext4` | Visor's agent image's root filesystem, unpacked once (a sparse 64 GiB ext4 file); each container start will clone it (APFS) | The image's digest |
| `tools/<visor version>/` | Visor's Linux programs, copied out of the app | The link rule, below |

- **Fetched once, checked each time.** `ContainerAssets`
  (`libraries/visor_container`) fetches what isn't there and checks it:
  - the kernel's archive by its SHA-256 before the kernel is taken out of
    it; a kept kernel only while its record names the pinned archive and its
    bytes still hash to what was recorded;
  - each image by digest: it's pulled by digest alone, and refused unless
    the store's image answers to the digest pinned. (An image pushed as one
    manifest, as Visor's agent image is, is kept under an index the store
    makes for it; it's the manifest's digest that's pinned.)
  - Each file is made beside its place and moved there once whole, so a
    file in its place is always whole.
- **The kernel and init filesystem are the build's** (`ContainerPins`, in
  `VisorContainerCore`): the init filesystem must match the Containerization
  version built in, so both change only with a Visor that builds against a
  new Containerization.
- **The agent image** is `ghcr.io/attilathefun/visor-agent`, by digest:
  - the release's, in `Visor.app/Contents/Resources/container.json`;
  - or Settings' (`container.imageDigest` in the server's settings: a digest
    only, `sha256:…`, never a tag).
  - A new image is used only when the container is idle: it's unpacked
    beside the old, and taken at the next idle restart. Anything agents
    installed in the container's root filesystem is lost then; what must
    survive is on Sessions.

### container.json

What a release pins, in `Visor.app/Contents/Resources`:

```json
{
  "containerization" : "0.57.0",
  "image" : "ghcr.io/attilathefun/visor-agent@sha256:092ad178…a152",
  "initfs" : { "digest" : "sha256:c30d5a14…e656", "repository" : "ghcr.io/apple/containerization/vminit", "tag" : "0.57.0" },
  "kernel" : { "member" : "opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug", "sha256" : "8736c054…e4b5", "url" : "https://github.com/kata-containers/…/kata-static-3.32.0-arm64.tar.zst" },
  "version" : 1
}
```

`//tools/container_manifest` writes it, with this commit's kernel and init
filesystem pins and the image given (`--image`), or the image CI builds
Visor's Linux programs in (`--workflow .github/workflows/ci.yml`: the
linux-programs job's `container:`). tools/release_mac.sh runs it for the
app that carries the Linux programs (`VISOR_AGENT_IMAGE` names another
image); tools/ci/mac_app_linux_programs.sh seals a container.json given as
its third argument into the app beside them. A build without one (a build
to run here) has no image pinned unless Settings names one.

### Visor's Linux programs

`Contents/Resources/Linux` (visor-server, with relay-client and
visor-agent-host as links to it) is copied to `tools/<visor version>/` on
the Containers volume, to be mounted read-only at `/opt/visor/bin`. A share
of the app bundle itself would go stale when the app is updated in place.
`ToolsFolder` copies it under **the link rule**, checked on the app's folder
and again on the copy:

- each entry is a regular executable, or a relative link whose target has
  no `/` and is a regular executable in the same folder;
- a dangling, absolute or escaping link, a link to a link, a file that
  isn't executable, or anything else, is refused, and so is a folder
  missing visor-server, relay-client or visor-agent-host.

A relay-client that doesn't resolve inside the mount would leave the
container with no egress: refused, the container will show "no egress"
and refuse session starts.

## Settings

`ServerSettings.container` (`ContainerSettings`), in the server's settings;
none is the defaults, off:

| Key | Default | |
| --- | --- | --- |
| `enabled` | `false` | Whether sessions may be placed in the container. It takes effect only where this Mac can run it. |
| `cpus` | 8, leaving two of this Mac's | At most this Mac's cores. |
| `memoryGiB` | Half of what's free when it starts, at least 4, at most 24 | At most all of this Mac's less 4 GiB. The cap minds that Nimbus will run VMs and containers on the Mini (32 GB) too; set it lower there if need be. Memory the guest frees isn't given back while it runs: the idle stop gives it back. |
| `idleMinutes` | 30 | Minutes with no session in it before it's stopped. |
| `imageDigest` | none | An agent image digest in place of the release's. |
| `checkouts` | none | A folder of this Mac's (an absolute path) shared read-write at the same path, for the checkouts. Still open: see below. |

A value that isn't one (a tag for `imageDigest`, a CPU count of 0) reads as
its default.

**Settings › Sessions Container** has the switch (`PUT /api/settings
{containerEnabled}`), off and disabled unless this Mac can run it, and the
readiness row: macOS 26 or later, Apple silicon, Virtualization, the
Containers volume, and the assets on it (present, or what's missing: the
engine fetches them when it first starts), with the image it would run.

## The engine

`ContainerEngine` (`VisorContainerCore`, over a `ContainerBackend`:
VisorContainer's `ContainerizationMachines` on a Mac, a fake in the tests)
runs in the server agent (`Visor --server`, MacSessionsContainer), not in
the app's own server: the VM lives in that one process, so an update of the
server restarts it, and its sessions resume from Sessions (a turn in
progress interrupted). There's no helper process of its own.

- **One container per Mac,** `visor-sessions`: Containerization's
  `LinuxContainer` with `VZVirtualMachineManager`, the kernel, the init
  filesystem read-only as the VM's `/`, and `sessions/rootfs.ext4` (an APFS
  clone of the image's template) as its root filesystem. The clone is kept
  across starts while the image is the same (what agents installed stays)
  and made again from a new image's template at the next start, which is
  only ever when it's idle. CPUs and memory are the settings' (the VM gets
  Containerization's guest overhead on top).
- **No network interface** (`interfaces = []`). Its only way out is the
  relay, below.
- **Shares** (virtiofs): `/Volumes/Sessions` at the same path, read-write;
  `tools/<version>/` read-only at `/opt/visor/bin`; and the checkouts'
  folder (`container.checkouts`) at its own path where the settings name
  one. Nothing else.
- **Its main process** is `/opt/visor/bin/relay-client run --relay
  /run/agent-proxy/relay.sock -- <a shell that waits>`, as root, with
  Containerization's init (signals forwarded, zombies reaped). Its lines go
  to `sessions/logs/relay-client.log`, the guest's console to
  `sessions/boot.log`.
- **The lifecycle:** it starts on first use (an exec, or Start), and stops
  once nothing has run in it and no session has been placed in it for
  `idleMinutes`. A server's start starts it again if a session is placed in
  it. If its main process ends, it's stopped (with the error said), and its
  next use starts it again. Turned off in Settings, it's stopped.
- **Processes:** `ContainerEngine.exec(ContainerExec)` runs one (its
  arguments, environment over the image's, working folder, and output
  appended to `sessions/logs/<id>.log`), and gives a `ContainerExecution`
  to signal and wait on. Step 4 runs each session's agent-wrapper so.

### Egress: the relay

- `HostRelay` listens on `run/relay.sock` in Visor's data folder (a folder
  of this user's alone; a socket's path must be under 104 bytes), carried
  into the guest at `/run/agent-proxy/relay.sock`
  (`UnixSocketConfiguration(direction: .into)`).
- Each connection on it is a TCP stream to **agent-proxy's relay port** on
  loopback (in the same process: agent-proxy is folded into the server
  agent), begun with the PROXY v2 header naming the container (TLV 0xE1,
  `visor-sessions`) and proving the relay (TLV 0xE2, the relay's token,
  `agent-proxy/relay-token` in the server's secrets, read again each
  minute), then spliced both ways. agent-proxy applies the egress policy,
  the GitHub gate and the egress log.
- **The relay port:** turning the container on gives agent-proxy one when
  it has none (`agentProxy.relayPort`, kept in the settings): 7438 if it's
  free, else the first free of 7440–7498 and 7500–7599. Never Visor's own
  7433, 7434 or 7439 (nor the MCP pass-through's, if it's moved), and never
  7499, Shireworks' relay on the Mini, which may be free only while
  Shireworks is stopped. agent-proxy is started again with it at once.
- **The egress check:** before the boot, the relay-client link check
  (ToolsFolder's rule on the staged copy); after it, `relay-client check`
  run in the guest, which asks agent-proxy's health (`GET /` through the
  relay's socket: nothing resolved, nothing on the internet). Three tries.
  If either fails, or there's no relay port, the container is **no
  egress**: processes (session starts) are refused, and Start (Check Again)
  runs the check again.

### Its status

`GET /api/container` (an admin's, as every REST route is) answers its state
(`off`, `starting`, `running`, `no-egress`, `stopped`), whether it's on and
whether this server can run it, its CPUs, memory and idle minutes, the
image's digest, the processes in it, the relay port, what the egress check
said, and the latest errors. `POST /api/container/start` and `/stop` answer
the same after. A server without the engine (Linux, the app's own server)
answers `off`, saying why. Settings › Sessions Container shows it, with
Start, Stop and Check Again.

## Still open

- **Where the sessions' checkouts live** (case sensitivity). Both Macs'
  Sessions volumes are case-insensitive today, and virtiofs passes that to
  Linux, where `Foo.h` and `foo.h` are two files. Proposed: a third,
  case-sensitive APFS volume for checkouts (`/Volumes/Work`, never erased),
  made by Visor Disk Utility and mounted at the same path. The engine
  doesn't decide it: `container.checkouts` names a folder to share at its
  own path, and none is shared unless it's set.

## What's next

- **PR 3, the driver link and the Linux agent-wrapper:** a dedicated
  `driver.sock` to `127.0.0.1:7434`, carried in at `/run/visor/driver.sock`.
- **Step 4, the container runner:** sessions placed in the container, each
  its agent-wrapper exec'd (`ContainerEngine.exec`), counted as placed for
  the idle stop and the start with the server.

## Testing

- `//tests/visor_container_tests` (in `//tests:linux`, and on a Mac): the
  pins and container.json, the layout, fetching and checking against a
  fake backend, the link rule, and the readiness row; the engine against a
  fake VM backend (the boot spec, the link check and the egress check, no
  egress refusing processes, first use, the idle stop, the start with a
  server, the root filesystem kept or cloned, a crash, turning it off), and
  `HostRelay` against a fake agent-proxy relay (the header's bytes, the
  splice, the token re-read, no agent-proxy) and agent-proxy's own relay
  listener (`relay-client check`'s health answer through it, and not with
  another token). `//tests/visor_server_tests`: `/api/container` (an
  admin's; off without an engine) and the relay port given when it's turned
  on (never 7499).
  `//tests/visor_container_tests:visor_container_mac_tests` (macOS): this
  Mac's readiness and memory, and the Containerization backend's archive
  reading. The settings' decoding is in `//tests/visor_server_tests`.
- `bazel run //tools/e2e/container_assets -- --image <reference by digest>
  --root <folder>` fetches, checks and unpacks everything for real, then
  again to show it's kept. It needs no Virtualization, so it runs in a macOS
  VM lease.
- `bazel run //tools/e2e/container --config=apple_cross_mac -- --linux
  <Linux programs> [--image <reference by digest>]` boots it for real, **on
  bare metal only** (never a macOS VM: it can't nest): on a throwaway data
  folder in /tmp, with agent-proxy's relay listener in its own process on a
  free port, it checks the boot and `relay-client check`, `uname`, a file
  each way through `/Volumes/Sessions/.visor-e2e-container-<id>`, and no
  LAN (only `lo`, and this Mac's addresses and a private one refused), then
  stops and deletes everything. It signs a copy of itself ad hoc with the
  virtualization entitlement and runs that. `--linux` is a build's
  `Contents/Resources/Linux` with `relay-client check`'s health answer
  (0.64 or later).
