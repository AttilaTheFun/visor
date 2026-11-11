# One Runner, several Visor Servers (design)

Status: planned for 0.45. Decided on 31 October 2026, and revised the same
day: Visor embeds Apple's Containerization framework and is one
self-contained Mac app (a dmg, and one day the Mac App Store); the Runner is
the only thing clients talk to, passing each on to its server, and every
server's MCP proxy. Revised again on 1 November with Logan's points: a
container shares nothing with the Mac; the Runner is also GitHub's forward
proxy (gh_mcp retired) and the push proxy; it holds named Claude accounts a
server can be switched between; and its menu runs the Mac's server, a
container server, or both, each with its pairing code. And that evening,
Logan's layout of the apps (The app, below): one Visor.app on the Mac and
the iPhone, `com.LoganShire.Visor`. On the Mac it is a menu bar app whose
window is Visor's macOS client, with the Runner and the servers inside it as
processes of their own. There are no beta bundle ids: a build says its
variant in its Info.plist.

Today one Mac runs one Visor Server, inside the menu bar app. From 0.44 to
0.49 a session could run its agent in a Linux container of its own (0.44's
container hosts; removed in 0.50), but the server stayed outside: the
container saw the session's folder and nothing else, so what the server
keeps — the pictures a client attaches, for one — was out of the agent's
reach.

This design makes each container a server of its own. One Mac runs any mix:
two sessions on the Mac's own server, five in one container's server, one in
another's, all driven by one app, Visor.app.

## A container shares nothing with the Mac

Logan (1 November): "I ultimately don't want the co-tenant container to
share *anything* with the host mac if possible. That means the agents
should clone their own copies of the repos inside the containers, not mount
them from the host. The longer term vision is I might want to legitimately
run these containers with the agents in the cloud and they need to be fully
portable / self contained."

- **No bind mounts.** Each session's projects are cloned inside the
  container, on its home volume, by its agent.
- **What crosses is network, through the Runner:** the MCP servers (the
  Runner's MCP proxy), GitHub (its forward proxy), pushes (its push proxy),
  and Bazel's remote cache, read-only, at a port the Runner proxies with the
  read token added. No token or key is written into the container but the
  agents' own sign-ins.
- **Visor's own tools** (`send_message`, `list_sessions`, `read_messages`,
  `message_status`, `approve`) are the container's server's own MCP,
  served to its agents directly, never through the Runner. Messages to
  other computers go through clients, as today.
- So a container server could as well run in the cloud: it needs the
  Runner's proxies at an address, nothing of the Mac's disk.

## The app

Logan (1 November): Visor.app is the Visor Runner and Visor for macOS in one.

- **On the Mac**, Visor.app (`com.LoganShire.Visor`) is a menu bar app
  whose window is Visor's macOS client.
  - The menu shows its state, Copy Visor Connection Code (one per server it
    runs), Settings… and Quit, like every menu bar server of Logan's.
  - The window is the client: this Mac's servers through the Runner, other
    computers as now.
  - The Runner, the Mac's Visor Server and the container servers run in
    processes of their own (The parts), each a wrapped, notarized
    executable in the bundle. So an update replaces them one at a time,
    quitting the app ends no server, and the app reconnects when it opens
    again; agents work on throughout under their hosts.
- **On the iPhone (and iPad)**, the same bundle id: a client only, built
  from the same Swift libraries.
- **One bundle id per app, no beta ids.** Versions are MAJOR.MINOR.BUILD.
  The variant is a key of the Info.plist, `BuildVariant`: `Alpha`
  (internal), `Beta` (TestFlight, later) or `Production` (the App Store).
  Applications Server releases the highest BUILD of a MAJOR.MINOR whose
  variant is Production.
- **The app group** the apps share with Applications (Reviews too), for
  UpdateKit: never in the source, but stamped in by CI's distribution builds
  from the repository's secrets (tools/signing).
- **Today's apps fold into it:**
  - Visor Server.app (applications/visor_menubar, `com.LoganShire.VisorServer.macOS`)
    and Visor for macOS (applications/visor_macos,
    `com.LoganShire.VisorClient.macOS`) become Visor.app. Its data folder
    stays where it is. Its own places: `com.LoganShire.Visor.server` and
    `com.LoganShire.Visor` in the keychain, `Application Support/
    com.LoganShire.Visor/Server` and `/Client`. In 0.46 its first launch
    copied the old apps' keychain items and caches there (one Always Allow
    per item, which Logan accepted on 4 Nov). 0.47 dropped the copying
    (#210): a Mac that skipped 0.46 starts fresh, its server password set
    and its computers added again.
  - The iPhone app moves from `com.LoganShire.VisorClient.iOS` to
    `com.LoganShire.Visor`. That is a new app on the device: installed
    fresh and paired again. Its push topic changes with it, which the server
    learns when the device registers. Its widget and share extension move
    under the new id.
  - Blue Visor's iPhone app (`com.LoganShire.VisorIsomer`) is gone (4 Nov
    2026): blue is the web and Android, and not part of this.

## The parts

- **Visor Server**: `visor-server`, one Swift binary for macOS and Linux
  with no window of its own (the server library, as now). It runs the
  agents as processes it starts and stops, listens on one port in plain
  HTTP, and is configured with the MCP servers its agents may use: their
  URLs, ports included. HTTPS, the LAN, the tailnet and loopback are the
  Runner's concern, not its.
  - On the Mac it runs the native sessions: agents as the user, signed in
    as they are on the Mac.
  - In a container it runs that container's sessions. Its agents, their
    transcripts and attachments, and the agents' hosts are all inside the
    container, so an attached picture is where the agent reads it.
- **Visor Runner**: the part of Visor.app that runs the servers, and the
  processes it keeps, every one inside the bundle and registered from it
  (SMAppService), nothing installed outside it. It runs Visor Servers, natively and in
  containers, and proxies their MCP requests:
  - starts, updates and stops the Mac's Visor Server (a launchd job of its
    own, so updating either leaves the other running);
  - makes, starts, stops and removes each container server's container
    with Apple's Containerization, and starts the server in it;
  - is the only thing clients talk to: it listens for each server's
    clients (on loopback, the LAN and VPNs as set) and passes their
    connections on to the server;
  - is every server's MCP proxy: the servers' MCP URLs point at it, and it
    adds the secret headers;
  - is GitHub's forward proxy for every server's agents, and the push proxy
    for every server with no APNs key of its own (below);
  - moves sessions between servers;
  - holds the credentials and gives each server what it needs.

  Visor.app's menu lists every server it runs, the Mac's and each
  container's, each with Copy Visor Connection Code. It can be set to run
  the Mac's server, a container server, or both.

  Its processes, each a helper in `Contents/Helpers`:
  - **the app itself**: the menu, Settings and the codes, and the window
    (Visor's macOS client). Quitting it leaves everything below running;
  - **the Runner's agent**, a LaunchAgent: it keeps the container servers
    (picks them up, asks after them, makes again one whose network is
    lost), runs the reverse proxies and the MCP proxy, so that quitting or
    updating the menu bar app leaves clients and agents served. The app
    writes what should be (a server's folder, stopped or not) and the agent
    makes it so;
  - **a helper per container**, a launchd job that runs that container's
    VM (Containerization runs a VM in the process that starts it): booted,
    taking commands on a socket, stopped on TERM. A container outlives the
    agent and the app;
  - **the network's owner**, one long-lived process for the network all of
    Visor's containers are on (192.168.131.0/24, apart from Shireworks' and
    `container`'s), so that no container's going takes its neighbours'
    network with it.

  What runs the containers (the helper, the network, an image pulled and
  unpacked, the kernel and init filesystem) is a Swift package of its own,
  shared with Shireworks, behind the Runner's `ContainerBackend`.

## Credentials

- **Native sessions:** Claude, Codex and OpenRouter as they sign in on the
  Mac, each in its own way; OpenRouter's key from the Mac's environment.
- **In containers:**
  - Codex: a sign-in of the container's own, made once in it (`codex
    login --device-auth`), never a copy of the Mac's, and never the Mac's
    `~/.codex` mounted.
  - Claude: a Claude account of the Runner's (below), written into each
    container server's agents' environment (`agents/claude.env`).
  - OpenRouter: an API key set in the Runner, given the same way.
- **Claude accounts:** the Runner keeps named Claude accounts (each an
  OAuth token), and each server, the Mac's or a container's, is set to one.
  Switching a server to another restarts its agents with that token, and
  their conversations resume: a container's server gets it in its
  `claude.env`, the Mac's agents as `CLAUDE_CODE_OAUTH_TOKEN` in their
  environment. A one-time import reads them from the environment Logan's
  shell sets (`LOGAN_SHIRE_CLAUDE_CODE_OAUTH_TOKEN`, the main account;
  `LOGAN_SHIRE_CLAUDE_CLAUDE_CODE_OAUTH_TOKEN`, the second;
  `LOGAN_SHIRE_OPEN_ROUTER_API_KEY`); the Runner never reads them there
  again.
- **MCP servers' secret headers:** kept by the Runner, added by its proxy.
  No server, native or in a container, holds them.
- **GitHub:** a GitHub App key the Runner holds, behind its forward proxy
  (below). No agent holds a GitHub token.
- **APNs:** the key pushes are signed with, held by the Runner, behind its
  push proxy (below). A server in a container holds none.
- **Where the Runner keeps secrets:** in the keychain for notarized builds
  (alpha, production), and in its data folder for debug builds, chosen by a
  Bazel config (`--config=notarized`, tools/secrets).

## Reaching the servers

- The Runner is the only thing clients talk to. For each server it listens
  at that server's port, on loopback always and on the LAN and VPNs as
  set, and passes each connection on to the server, the bytes both ways
  as they come (HTTP, the WebSocket).
- The servers listen in plain HTTP where only the Runner reaches them:
  the Mac's on loopback; a container's at its address on Visor's network
  for containers, which only the Mac reaches.
- To a client, each server is a computer of its own, at the Runner's
  address and that server's port: clients are as they are now. The Runner
  shows each server's connection code, which leads with that address.
- Clients already keep several computers, so a Mac with three servers is
  three computers in the sidebar.
- Later, the Runner takes on what the servers do for clients themselves
  now: HTTPS (its identity), pairing and passwords, passing the signed-in
  client on to the server in a header, and a token per server so that
  nothing else on the Mac can talk to a server directly.

## MCP servers

- The MCP servers (GitHub's, Shireworks', …) are set in the Runner: each a
  name, a URL and headers, a secret one's value kept by the Runner.
- The Runner listens for its servers' MCP requests and passes each on to
  the endpoint, adding the secret headers, and the answer back as it comes
  (JSON or SSE).
- Each server is configured with the Runner's URLs (its `PUT /api/mcp`),
  `…/mcp/<name>`, with a token of its own that the Runner checks:
  - the Mac's server: the Runner on loopback;
  - a container's server: the Runner as the container reaches the Mac,
    through the container network's gateway (or a port mapped to the
    Runner's from inside, where `container` can).
- So no secret header enters a server, and a server works the same
  natively and in a container.
- The proxies run in the Runner's agent, so quitting or updating the menu
  bar app leaves them serving. While the agent itself is down (updating),
  servers and agents run on; clients can't reach them, and MCP calls fail,
  until it is back.

## GitHub, through the Runner

Logan (1 November): "we retire gh mcp, have the runner hold a github app key
and be configured with the rules for what agents should be allowed to do and
it's a true forward proxy like Charles so the agents think they're talking
to github.com but it passes through the visor proxy. The visor runner
configures the container / server and tells it to trust its certificates."

- The Runner is an HTTP proxy (`CONNECT`) that every server's agents are
  set to use (`HTTPS_PROXY`). It opens TLS for GitHub's own names alone
  (`github.com`, `api.github.com`, `uploads.github.com`) with a certificate
  authority of its own, name-constrained to them; everything else passes
  through untouched.
- A container trusts that authority because the Runner set it up to; the
  Mac's agents are given it by their environment (`SSL_CERT_FILE`,
  `NODE_EXTRA_CA_CERTS`, `GIT_SSL_CAINFO`), never by the login keychain.
- A request to GitHub goes on with the App's token for the repository, if
  the Runner's rules allow it: the repositories agents may use, the refs
  they may not move (the default branch, tags), the writes they may make
  (pull requests, comments, pushes to their branches, merges once checks
  pass and the code owners are satisfied). The rules are data in the
  Runner's settings, not code. A refusal says why, as GitHub's errors do.
- `git` and `gh` work unchanged, so agents clone, fetch and push as
  anywhere else. gh_mcp, and its tools, go.

## Pushes, through the Runner

A server with no APNs key of its own (one in a container, or on Linux) is
set to the Runner's push proxy (`PUT /api/push-proxy`, docs/protocol.md). It
sends each push as it would send it to APNs, unsigned, to the Runner, which
signs it with the key it holds and sends it on; APNs's answer comes back,
so the server forgets a device APNs says is gone.

## A container server

Each has a folder of the Runner's, `<Runner data>/container-servers/<id>/`:

- **`server.json`:** what it is, written by the Runner and never secret:

```json
{
  "id": "<uuid>",
  "name": "Builds",
  "image": "ghcr.io/attilathefun/visor:0.45.3",
  "cpus": 6,
  "memoryBytes": 17179869184,
  "diskBytes": 137438953472,
  "listen": {"port": 7440, "lan": true, "vpn": true},
  "setup": "",
  "stopped": false
}
```

- **`state.json`:** what the Runner last found (below).
- **Its secrets** (the server's password, its MCP token, the sign-ins): the
  Runner's, kept as all its secrets are.

What the Runner does with its container backend:

- **Makes it:** two volumes, its home (`/root`) and Bazel's output
  (`/var/cache/bazel`), then the container from the image with the
  volumes, its limits and a label naming the container server; no folder of
  the Mac's. The container's main process only waits (and reaps what it
  adopts: the image's `tini`).
- **Fronts it:** listens at the clients' port (`listen`) and passes each
  connection on to the server at the container's address, for as long as
  the server runs.
- **Keeps it up:** a front set with `--start <command>` (`front set
  co-tenant --port 7440 --to 192.168.131.3:7433 --start "container exec -d
  visor-co-tenant visor-server start"`) is watched: every half minute the
  Runner asks whether the server answers, and when it hasn't twice running
  it runs the command, at most every two minutes (ServerWatch). The mini's
  co-tenant died on 7 Nov with nothing to start it again until someone
  noticed.
- **Sets it up:** runs the setup script in it (below), before the server
  first starts and again after an upgrade or a change to the script.
- **Starts the server in it:** sets its password (`visor-server password`,
  on standard input), writes the agents' sign-ins, then starts
  `visor-server start` detached (an exec not tied to the exec's stream),
  its `--address` the Mac's address for it, so its codes lead with that.
  Then sets its MCP servers, its GitHub proxy and its push proxy to the
  Runner's.
- **Picks it up:** when the Runner starts, it lists the containers it made
  (by label), starts any stopped one that isn't marked stopped, starts the
  server in any that isn't answering, and gives credentials and MCP
  settings again where they changed.
- **Upgrades it:** the container made again from the image `server.json`
  now names, its volumes kept, so its sessions are as they were and their
  agents resume.
- **Stops it:** its VM stopped; its volumes are kept, and Start starts it
  again.
- **Removes it:** the container, and its volumes with it, and with them its
  sessions; its folder and secrets go too.

### The server inside

- **Its disks:** its home holds the server's data
  (`~/.local/share/visor`: sessions, attachments), the projects its agents
  cloned, the agents' own transcripts (`~/.claude`, `~/.codex`,
  `~/.openrouter`), which a resumed session reads, and their sign-ins. Kept
  until it is removed.
- **Its agents' sign-ins:** Claude's `CLAUDE_CODE_OAUTH_TOKEN` in its
  `agents/claude.env` (in the server's data), OpenRouter's
  `OPENROUTER_API_KEY` in `agents/openrouter.env`, Codex's `auth.json` at
  `~/.codex/auth.json`.

### Its setup

What the agents find in a container beyond the image is prepared by a
setup script, run in it as root by the Runner:

- **The default:** the Runner's own script, versioned with it: the agent
  environment Visor's agents expect (their tools' settings, git's identity
  for the agents, the folders they write to).
- **A custom one:** Settings can name a script of the person's own, for
  one container server or all of them (`setup`, a path on the Mac; empty
  for the default), to make the agents' environment their own. It runs
  after the default.
- **When:** after the container is made, before its server first starts;
  again when it is made anew (an upgrade, a lost network) or the script
  changes (its hash is kept in `state.json`). What it printed, and
  whether it failed, are in `state.json` for Settings; a failed setup
  leaves the server unstarted, saying why.

### Health

These checks are the Runner's, not Shireworks': Shireworks' own leased
containers are short leases and need nothing special.

- While it runs, the Runner asks each container server every 30 seconds
  (`GET /api/hello`) and writes what it found to `state.json`, which
  Settings shows.
- When a server doesn't answer, the Runner checks the container's network.
  The network is lost when the container's address is on no network the
  Mac has (its network was made again under a running container, as when
  the builder restarts), or when nothing resolves or HTTPS reaches nothing
  from inside it. Then the container is made again with its volumes kept,
  so its sessions are as they were. A server that has merely stopped is
  started again.

## Container images

Logan (4 November): Visor brings its own Linux programs into whatever image
a container is made from, so any image can be used; its own image is only
the default.

- **Visor's programs, mounted.** Visor.app carries `visor-server` and
  `visor-agent-host` built for Linux (arm64, the Swift runtime linked in,
  so they need nothing of the image's), in `Contents/Resources/Linux`,
  signed with the app. Every container Visor makes, a container server's or
  a session's, has that folder read-only at `/opt/visor/bin`, and Visor
  runs its own from there, never an image's: the server in a container is
  always the app's version, and no image is made again for a Visor release.
- **Visor's MCP tools, in Swift.** `visor-agent-host mcp` is the MCP server
  every agent is given (its tools, `approve`, and the MCP servers the
  computer passes on), in place of a Node script: an image needs no Node,
  and neither does the Mac.
- **What an image needs:** Linux on arm64, a shell, git, ssh and tmux, and
  the agents' own command-line tools (`claude`, `codex`, `openrouter`) on
  its path, at whatever versions it carries. Visor checks for them when it
  makes a container and says which are missing.
- **The default:** `ghcr.io/attilathefun/visor:<version>`, published with
  each release, and `:latest`: Ubuntu, git, ssh, tmux, ripgrep, Python,
  Claude Code, Codex and openrouter (and Visor's two programs, for anyone
  running it on its own). Visor uses its own version's.
- **Another image:** Settings names any image, from any registry: one of
  the person's own, or their company's with its own build tools (a private
  registry, ECR say, with a sign-in that Visor runs before it pulls, as
  `aws ecr get-login-password` gives one for 12 hours).
- **The build image:** `visor-build`, the default with the Swift
  toolchain, Bazel, clang, the libraries Isomer's Linux apps link, NSS for
  headless Chromium, and x86_64 glibc for Android's tools: for CI and for
  sessions that build. It is published to Shireworks' own registry (Isomer's
  too), which Logan's CI pulls from, not to ghcr.
- **What is kept:** a container server's home and Bazel's output are
  volumes (above); a session's container in today's model keeps its
  agent's home in a volume of its own too, beside the logs it already
  writes on the Mac. A container is made again from another image with
  its volumes, when the setting or the app's version changes it, once its
  sessions aren't mid-turn: their agents resume where they were.
- **Order:** the MCP tools in Swift; the Linux programs in Visor.app and
  mounted; the default image published as `visor`; the home volume and
  remaking a container for a new image; Settings' image and its sign-in;
  `visor-build` on Shireworks once its registry is there.

## Shireworks

The Runner calls nothing of Shireworks' for its containers. Shireworks, on
the same Mac, sees their VMs among the Mac's processes and counts their
memory against its budget for what it lends.

## The App Sandbox

The Mac App Store asks for it, so the Runner is made with it in mind, and
these are checked early rather than assumed:

- the network for containers from a sandboxed process (vmnet may need an
  entitlement Apple grants on request; Virtualization's own NAT doesn't);
- a project folder seen in a container through a security-scoped bookmark;
- native sessions run the user's own `claude` and `codex`, which a sandbox
  forbids: a build for the store may be containers only.

## Moving sessions

- Between any two servers: the Mac's and a container's, or two containers'.
- Visor's Migrate… already moves a session between servers. The client
  carries the conversation's files and the projects across, and the other
  server resumes the session; the original is left until the new one works.
- A container sees no folder of the Mac's, so a move into one always takes
  the project with it: the client copies it in, or the agent clones it
  there from GitHub. A move out of one does the same the other way.
- A container whose Mac shares folders with it (the co-tenant, which
  mounts the mini's ~/Developer at /Users/logan/Developer) takes a session
  only in one of them (`HostDetails.sharedFolders`, from the writable
  virtiofs and 9p mounts): a path in one stays where it is, and a session
  whose folder is in none is refused, rather than landing on the
  container's own disk, where nothing else sees it (Logan, 8 Nov 2026).

## Phases

1. **One container server, end to end, from the Runner.**
   - The Linux `visor-server` in Visor's agent image.
   - The Runner makes, starts, picks up, upgrades, stops and removes
     container servers with `container`; their ports published; their
     health checked; their sign-ins given.
   - The Runner's MCP proxy, which the container servers are configured
     with (visor #169), and its push proxy (#178, #179).
   - The Runner's client proxy, in place of the forwarder the mini's
     co-tenant has now (socat).
   - GitHub's forward proxy and its rules; gh_mcp retired.
2. **One Visor.app** (The app).
   - The menu bar app and the macOS client in one bundle,
     `com.LoganShire.Visor`, with its menu (state, Copy Visor Connection
     Code, Settings…, Quit). The Runner's agent is in Contents/Helpers.
   - The iPhone app on the same id, its widget and share extension with it.
   - `BuildVariant` in every Info.plist, and the beta ids gone, once
     Applications Server takes the variant from the plist.
   - Provisioning profiles made again for the new id and the app group.
3. **The Runner's side in Settings.**
   - Container servers made and removed, started and stopped; the Mac's
     server, a container server, or both.
   - Claude accounts, each server set to one and switched between them;
     the import from the environment; the OpenRouter key.
   - Copy Visor Connection Code for each server, in the menu.
4. **The Mac's server apart from the Runner.**
   - `visor-server` runs as a launchd job that Visor.app installs,
     updates and stops, and keeps the app's data folder, so
     sessions, pairings and codes carry over.
   - Its MCP servers are the Runner's too.
   - The Runner's settings and menu read and change it through its local
     API.
5. **Moving sessions.**
   - Moving between servers from the Runner.
   - Today's agent-in-a-container sessions (0.44) moved onto container
     servers; then that way of running, and 0.44's container hosts, are
     retired (done in 0.50: a session saved in one runs on its computer).

## Where it stands (3 November)

- **Phase 1:** the Runner's proxies are in. Its MCP proxy (#169), push
  proxy (#178, #179) and client proxy (#180, in place of the socat
  forwarder) serve the mini's co-tenant, the first container server, which
  is still made by hand: Visor's agent image with `visor-server` in it
  (#151), its sessions marked as a container's (#170), its pairing code
  listing the front's paths (#171). The Runner making container servers
  itself (#158) waits on the container runtime package taken out of
  Shireworks, which doesn't exist yet. GitHub's forward proxy isn't started.
- **Phase 2:** begun. Visor.app is a target (applications/visor_mac,
  #187, #188). The iPhone app is `com.LoganShire.Visor`, with
  `BuildVariant` in its Info.plist and the app group (#189, #190), and its
  Alphas go to Applications Server (#196). The Mac still ships Visor
  Server.app and the Mac client: switching to Visor.app costs one
  login-keychain prompt per item the old apps made (each is ACL'd to the
  app that made it), which Logan hasn't decided on yet.
- **Phase 5's groundwork:** sessions are backed up to a folder and
  restored from one (#200), each half of a move; a move survives a dropped
  piece (#203).
- Logan (1 November): "Don't move yet until everything is working fine
  with the visor session in the co-tenant container."

## Sessions running today

- Sessions in Shireworks containers (0.43) run on the Mac from 0.44 on, with
  a notice. Sessions in 0.44's containers run on their computer from 0.50
  on, which has no Move into a Container.
- Once phase 1 is out, such a session moves to a container server with
  Migrate…. The old one is kept until the new one has answered.
- A server is updated only when its sessions aren't mid-turn.
