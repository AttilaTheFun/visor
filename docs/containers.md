# The Sessions container (from 0.64)

Each Mac's Visor runs one **Sessions container**: a Linux environment for
its sessions, on Apple's [Containerization](https://github.com/apple/containerization)
(each container its own lightweight VM, made by the framework: Visor
supplies a kernel, an init filesystem and an image, and writes no VM code
of its own). It lives in Visor's background server (`Visor --server`), so
quitting or reopening Visor.app leaves it running; an update of the server
restarts it, and its sessions resume from Sessions.

This is being built in steps. What's here now (**PR 1, the assets and
settings**): the Containerization dependency, the virtualization
entitlement, the assets (fetched, checked, kept), Visor's Linux programs
staged for it, its settings and Settings' readiness row. The container
doesn't boot yet: that's the engine's (PR 2).

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

A value that isn't one (a tag for `imageDigest`, a CPU count of 0) reads as
its default.

**Settings › Sessions Container** has the switch (`PUT /api/settings
{containerEnabled}`), off and disabled unless this Mac can run it, and the
readiness row: macOS 26 or later, Apple silicon, Virtualization, the
Containers volume, and the assets on it (present, or what's missing: the
engine fetches them when it first starts), with the image it would run.

## Still open

- **Where the sessions' checkouts live** (case sensitivity). Both Macs'
  Sessions volumes are case-insensitive today, and virtiofs passes that to
  Linux, where `Foo.h` and `foo.h` are two files. Proposed: a third,
  case-sensitive APFS volume for checkouts (`/Volumes/Work`, never erased),
  made by Visor Disk Utility and mounted at the same path. Nothing in PR 1
  decides it (a TODO in `ContainerLayout`).

## What's next

- **PR 2, the container engine in the server:** a no-network boot from these
  assets (`Kernel`, the init filesystem as `/`, a clone of the template as
  the root filesystem), Sessions over virtiofs at `/Volumes/Sessions`,
  `tools/<version>/` read-only at `/opt/visor/bin`, `HostRelay` carrying
  agent-proxy's relay socket in, the relay-client check after boot, the idle
  stop, and recovery after a crash. Booting is tested on the bare-metal
  MacBook (`//tools/e2e/container`), never in a VM lease.
- **PR 3, the driver link and the Linux agent-wrapper:** a dedicated
  `driver.sock` to `127.0.0.1:7434`, carried in at `/run/visor/driver.sock`.

## Testing

- `//tests/visor_container_tests` (in `//tests:linux`, and on a Mac): the
  pins and container.json, the layout, fetching and checking against a
  fake backend, the link rule, and the readiness row.
  `//tests/visor_container_tests:visor_container_mac_tests` (macOS): this
  Mac's readiness and memory, and the Containerization backend's archive
  reading. The settings' decoding is in `//tests/visor_server_tests`.
- `bazel run //tools/e2e/container_assets -- --image <reference by digest>
  --root <folder>` fetches, checks and unpacks everything for real, then
  again to show it's kept. It needs no Virtualization, so it runs in a macOS
  VM lease.
