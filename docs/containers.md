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
its status in the API and Settings), and **PR 3, the driver link and the
Linux agent-wrapper** (Visor's driver carried in on a socket of its own,
relay-client's loopback forward to it, agent-wrapper in Visor's Linux
programs, and `ContainerEngine.startWrapper`), and **step 4's server half,
the container runner** (sessions placed in it, Move to Container and Move
Back, a new session there, their agents started again across restarts:
"Placing sessions", below), and **its clients' half** (Migrate… as one menu of
these places, and the placement shown on each session).

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
visor-agent-host as links to it, and agent-wrapper) is copied to `tools/<visor version>/` on
the Containers volume, to be mounted read-only at `/opt/visor/bin`. A share
of the app bundle itself would go stale when the app is updated in place.
`ToolsFolder` copies it under **the link rule**, checked on the app's folder
and again on the copy:

- each entry is a regular executable, or a relative link whose target has
  no `/` and is a regular executable in the same folder;
- a dangling, absolute or escaping link, a link to a link, a file that
  isn't executable, or anything else, is refused, and so is a folder
  missing visor-server, relay-client, visor-agent-host or agent-wrapper.

**agent-wrapper** is agent_protocol's (the version Package.resolved pins,
0.5.0), a static program of its own (about 70 MB stripped) beside
visor-server, not a name of it: agent_protocol 0.5.0 makes it only an
executable (its `AgentWrapper` module is no library product, and its main is
top-level code), so visor-server can't run it by a name as it runs
relay-client. tools/linux_programs.sh builds it as a product of Visor's
package (`swift build --product agent-wrapper`, the same static SDK and
flags, the dependencies' build shared), strips it, checks it's static and
that it runs (`--help`: 0.5.0 has no `--help` or `--version`, so it answers
its usage and status 2); tools/ci/linux_programs.sh puts it in the tar,
and tools/ci/mac_app_linux_programs.sh and tools/release_mac.sh seal it
into the app. When agent_protocol exports its wrapper's main, it can become
a link to visor-server too (the link rule takes either).

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
  /run/agent-proxy/relay.sock --forward 7434=/run/visor/driver.sock --
  <a shell that waits>`, as root, with
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
  to signal and wait on. `startWrapper(session:)` runs a session's
  agent-wrapper so (below).

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

### The driver link

Visor's driver (agent_protocol's `AgentDriver`, gRPC on 127.0.0.1:7434 in
the server agent) is carried in on **a socket of its own**, not through
agent-proxy:

- On the Mac, a `UnixBridge` (HostRelay's other half: the same accept
  loop, splice and connection cap) listens on `run/driver.sock` beside the
  relay's socket, and joins each connection to the driver's port with
  **no PROXY header**: the agents' JWTs (`AGENT_TOKEN`, shown as
  `authorization: Bearer` on every call) say who they are, as on the Mac.
- It's carried into the guest at `/run/visor/driver.sock`, and started and
  stopped with the relay.
- In the guest, relay-client's `--forward 7434=/run/visor/driver.sock`
  (`LoopbackForward`) listens on **127.0.0.1:7434** and joins each
  connection to that socket. Loopback is what relay-client's nat chain never
  redirects (`ContainerNetwork.excluded`, 127.0.0.0/8, which the chain's
  `ip daddr 127.0.0.0/8 return` and the redirect listener's own refusal are
  both made from, and `ContainerNetwork.isRedirected` tests), so these
  connections never reach agent-proxy.
- So **`AGENT_DRIVER_URL=http://127.0.0.1:7434`** inside, the same as on the
  Mac, with no `*.agent.internal` name, and it **works with agent-proxy's
  relay down** (`//tools/e2e/container` checks it with agent-proxy
  stopped). A driver that doesn't answer closes the guest's connection,
  and the wrapper dials again (1 s, doubling to 30 s).

### A session's agent-wrapper

`ContainerEngine.startWrapper(session: ContainerSession)` execs
`/opt/visor/bin/agent-wrapper` in the session's working folder, its output
to `sessions/logs/<session>.log`, with the environment a runner gives it
(agent_protocol's README; Shireworks' `AgentRunner.environment` and
`ExecAgentHost`), over the image's:

| Variable | Value |
| --- | --- |
| `AGENT_ID` | `<agent uuid>@<dispatcher URL>` |
| `AGENT_JOB` | The job's JSON (WrapperOptions' keys: `agent`, `dispatcherURL`, `title`, `prompt`, `labels`, `driverURL`, and `harness`, `model`, `effort`, `workingDirectory`, `resumeSessionID`, `skipPermissions` only when set). Never the token. |
| `AGENT_DRIVER_URL` | `http://127.0.0.1:7434` |
| `AGENT_DISPATCHER_URL` | Whom it reports Started, Completed and Failed to, when it has one |
| `AGENT_RUNNER` | `visor-sessions` unless the session says |
| `AGENT_TOKEN` | The agent's JWT, there alone (the wrapper unsets it once read and keeps it from the harness) |
| `AGENT_SESSIONS_DIR` | `/Volumes/Sessions` (a job with no folder works in `<it>/Claude/<agent>`) |
| `AGENT_SOURCES_DIR` | Where a resumed session's sources are cloned, when given |
| `AGENT_WRAPPER_CLAUDE` | Only for a stand-in (a test's): the harness is the image's `claude`, on its PATH (`/usr/local/bin/claude`, npm's Claude Code) |
| `TMPDIR` | `/tmp`: the wrapper's MCP socket (`agent-mcp-*/mcp.sock`, which it hands its harness as `AGENT_MCP_SOCKET` for `agent-wrapper mcp`) on the guest's own disk, not on Sessions' share |
| `HOME` | `/root` (the image sets none; processes run as root, and the image's `IS_SANDBOX=1` lets Claude Code bypass its prompts as root) |

The session's own variables (a sign-in, `CLAUDE_CONFIG_DIR`) go in too, but
never over the `AGENT_*` contract. The wrapper is passed
`--skip-permissions` unless the job says it asks (`skipPermissions` false:
its prompts then go to the driver as `mcp__visor__approve`), as Shireworks'
container runner does. Its working folder, when it's under Sessions or the
checkouts' folder, is made on the Mac first (the guest sees it at the same
path); otherwise the exec starts in the image's folder and the wrapper makes
its own. The container runner, below, is what starts it for a session.

### Its status

`GET /api/container` (an admin's, as every REST route is) answers its state
(`off`, `starting`, `running`, `no-egress`, `stopped`), whether it's on and
whether this server can run it, its CPUs, memory and idle minutes, the
image's digest, the processes in it, the relay port, what the egress check
said, the latest errors, and, when it was stopped on purpose (Stop, or
turned off), why it's `held` stopped. `POST /api/container/start`, `/stop`
and `/restart` (stopped and started again, taking a new image if one is
pinned: what an image's update needs while sessions are in it) answer the
same after. A server without the engine (Linux, the app's own server)
answers `off`, saying why. Settings › Sessions Container shows it, with
Start, Stop and Check Again.

## Placing sessions (the container runner)

A session is **on this Mac** or **in this Mac's Sessions container**; another
Mac is another server, reached by Migrate…. `SessionInfo.placement` says
which (`host`, `container`, or `runner` for one a dispatcher's runner
claimed, deprecated), from a 0.64 server. The runner is the server's
(VisorServer+ContainerRunner, ContainerRunner): Visor starts each session's
agent in the container itself, so nothing claims a job, and the dispatcher's
queue isn't used. The driven-session code a runner's agent had is the same:
its process is the wrapper's stream (DrivenProcess: rows, mail as `@@from`
turns, approvals, interrupts), its MCP is Visor's own tools alone, and a
move back is a hand-back (agent_protocol 0.5.0's `ReturnConversation`, the
intake's containment and caps).

- **Move to Container** (`POST /api/sessions/<id>/moveToContainer`):
  refused while the container can't take sessions (off, no egress), for a
  session that's archived, mid-turn, not Claude Code's, has no conversation
  yet, or works in a repository outside the container's folders with work
  not pushed. Otherwise its agent here is ended and one is started in the
  container on the same conversation (the driver's `Conversation` sends it
  down). A session working under a folder the container shares (Sessions,
  the checkouts' folder) keeps its folder; any other works in
  `<Sessions>/Claude/<agent>`, the repositories it worked in cloned there.
  Its prompts are skipped (the container is its sandbox), and asked again
  once it's back. One whose agent can't start there comes straight back,
  saying why. Answered once its agent has started.
- **A new session in the container** (`POST /api/container/sessions {title,
  model, effort, text}`): a Claude Code session in a folder of its own,
  `<Sessions>/Claude/<id>`, its first message `text`.
- **Its agent:** `agent-wrapper` exec'd by the engine (startWrapper, with
  VisorContainerRunner's `ContainerSession(agent:)`), a new agent id each
  time, with a token of its own (a JWT for `visor.runner-agent` naming the
  session and the agent, refreshed over its stream) that the driver checks
  on every call (DrivenAgentDirectory: the runner's agents, else the
  dispatcher's), its conversation (`resumeSessionID`: the one its wrapper
  last said, kept with the session's move), and `CLAUDE_CONFIG_DIR`
  `<Sessions>/.claude`: what it says survives the container, and the host
  reads it.
- **Its end**, unless it was let go (Stop Agent, Restart Agent, Move Back,
  archived or removed), starts its next agent there: the container
  restarted under it (a crash, `/restart` for an image's update) or its
  wrapper ended. Three quick ends in a row (within a minute of starting)
  stop it instead, and so does a container held stopped or unable to take
  it, each saying why; Start Agent tries again. An agent let go that hasn't
  ended within 10 seconds (30 after a hand-back) is sent TERM, then KILL.
- **Migrating it to another computer** is refused while it's in the
  container (`POST /api/migration/offer` answers 409: move it back first),
  as the offer reads this Mac's Claude folder and would leave its turns
  there behind.
- **Move Back** hands its conversation back into this Mac's Claude folder,
  under the folder it comes back to, and it carries on from it here. A
  session whose agent isn't running there (stopped) has one started to hand
  back. Nothing returned in time, it carries on from where it was before it
  moved, saying so.
- **A server's start** (its update, a crash) takes the container down with
  it: once the engine is given, each session placed there whose agent ran
  has its next agent started, on its latest conversation, and one whose turn
  was cut short is told to pick it up, as a host session is. The sessions
  placed there keep it from its idle stop, and start it with the server
  (`placedInContainer`).

**In the clients** (visor_ui's MigratePlaces, from a session's context
menu): **Migrate…** asks where the session goes, saying where it is, and
offers each place but that one: its computer ("‹computer›": Move Back),
that computer's Sessions container ("‹computer›'s Container": Move to
Container, offered while `GET /api/container` says it takes sessions,
asked on connecting and after each move), then any other computer
connected now that migrates (the Migrate sheet, as before). It's a button
and an alert, not a menu within the context menu, which only Apple's
SwiftUI draws. Move to a Runner (the dispatcher's) is no longer
offered. A session's row marks where it runs: a box, "In the Sessions
container", for one placed there (SessionPlaceMark, from
`SessionInfo.placement`).

**Its token in the agent's environment** (agent_protocol#17): the wrapper
reads `AGENT_TOKEN` and unsets it, and keeps it from its harness's
environment, but `/proc/<wrapper>/environ` still shows the environment the
process began with, and the harness runs as the same user (root, in the
container), so it can read the token there. The token is the session's
alone, for an hour, and only for the driver (never the REST side), so it
lets the agent act as its own session and nothing more; still, it's a
credential its harness shouldn't hold. The fix is agent_protocol#17's: the
token handed over on a descriptor (`AGENT_TOKEN_FD`) or in a 0600 file the
wrapper deletes once read, with `hidepid=2` or a uid of the harness's own
as a defence beside it. Visor adopts it once #17 lands in a release.

## Still open

- **Where the sessions' checkouts live** (case sensitivity). Both Macs'
  Sessions volumes are case-insensitive today, and virtiofs passes that to
  Linux, where `Foo.h` and `foo.h` are two files. Proposed: a third,
  case-sensitive APFS volume for checkouts (`/Volumes/Work`, never erased),
  made by Visor Disk Utility and mounted at the same path. The engine
  doesn't decide it: `container.checkouts` names a folder to share at its
  own path, and none is shared unless it's set.

## What's next

- **New Session in the container** in the clients (the server's `POST
  /api/container/sessions` is there).
- **agent_protocol#17:** the token handed over on a descriptor, above.

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
  another token); the driver link (carried in beside the relay, the
  guest's bytes reaching a fake driver with nothing before them, with no
  agent-proxy there, and closed when no driver answers) and
  `startWrapper`'s argv, environment, folder and log; a stop on purpose
  held and a restart not, and the container runner's agent exec'd
  (VisorContainerRunner: its conversation, folder, repositories and Claude
  folder).
  `//tests/visor_agent_proxy_tests:relay_client_tests`: `--forward`'s
  loopback listener joined to a Unix socket, what `--forward` takes, and
  loopback never redirected (`isRedirected`, the mask, the rule's order);
  and, where namespaces can be made, a forward inside relay-client's
  network that the relay never hears of. `//tests/visor_server_tests`: `/api/container` (an
  admin's; off without an engine; restart) and the relay port given when
  it's turned on (never 7499); and the container runner
  (ContainerRunnerTests, over gRPC as the wrappers reach the driver, with a
  container that runs no VM), the pilot's seven checks among them: its MCP
  Visor's own tools; mail both ways; approvals answered from Visor; an
  interrupt; a server's start starting its agent again on its latest
  conversation; the move and its token's enforcement (its own token in, no
  other, no job); and Move Back with its conversation handed back. And its
  lifecycle: an end started again, three quick ends stopping it, a container
  held stopped, a restart under it uncounted, Stop and Start Agent, a move
  refused or coming straight back, a folder of its own outside the shared
  ones, and a new session there.
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
  LAN (only `lo`, and this Mac's addresses and a private one refused); then,
  with agent-proxy stopped, that `relay-client check` fails while
  127.0.0.1:7434 in the guest reaches a stub AgentDriver of its own (on a
  free port, never the real 7434), and that `startWrapper`'s agent-wrapper,
  with a stand-in claude, completes Connect through it (its hello naming
  the agent, protocol 2, its token the bearer), answers the driver's
  message, is stopped by it, and ends 0. Then **a real session**:
  agent-proxy started again, the container booted again with its driver
  link to a Visor server of the run's own (its data and Claude folders in
  /tmp, its secrets in memory, never listening for clients, its driver on a
  free port, its harness unable to start an agent on the Mac), whose
  container runner starts a new session in the container: its agent (the
  stand-in claude) connects with its own token and answers its first
  message, its conversation is on Sessions where the host reads it, a
  restart of the container starts its next agent on the same conversation,
  and Move Back hands the conversation back into the run's Claude folder,
  its agent there ending. Then it stops and deletes everything. It signs a copy of itself ad hoc with the
  virtualization entitlement and runs that. `--linux` is a build's
  `Contents/Resources/Linux` with `relay-client run --forward` and
  agent-wrapper (0.64 or later), or `tools/linux_programs.sh <folder>`'s
  output. `--cache <folder>` keeps the assets (the kernel, the image store,
  the unpacked template) in that folder between runs, so a rerun skips the
  fetch and the template's unpacking (about 4 minutes); each run's root
  filesystem clone, logs and staged programs there are deleted before and
  after it. Without it, everything is in the run's /tmp folder.
