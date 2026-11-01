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

Today one Mac runs one Visor Server, inside the menu bar app. A session can
run its agent in a Linux container (0.44's container hosts,
docs/container-host.md), but the server stays outside: the container sees
the session's folder and nothing else, so what the server keeps — the
pictures a client attaches, for one — is out of the agent's reach.

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
- **The app group** `group.com.LoganShire.Applications`, which Logan's apps
  share (Reviews too).
- **Today's apps fold into it:**
  - Visor Server.app (applications/visor_menubar, `com.LoganShire.VisorServer.macOS`)
    and Visor for macOS (applications/visor_macos,
    `com.LoganShire.VisorClient.macOS`) become Visor.app. Its data folder
    and its keychain items stay where they are, so sessions, pairings and
    the server's password carry over.
  - The iPhone app moves from `com.LoganShire.VisorClient.iOS` to
    `com.LoganShire.Visor`. That is a new app on the device: installed
    fresh and paired again. Its push topic changes with it, which the server
    learns when the device registers. Its widget and share extension move
    under the new id.
  - Blue Visor (`com.LoganShire.VisorIsomer`) is Isomer's, and not part of this.

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
    Visor's containers are on (192.168.131.0/24, apart from OS Server's and
    `container`'s), so that no container's going takes its neighbours'
    network with it.

  What runs the containers (the helper, the network, an image pulled and
  unpacked, the kernel and init filesystem) is a Swift package of its own,
  shared with OS Server, behind the Runner's `ContainerBackend`.

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

- The MCP servers (GitHub's, OS Server's, …) are set in the Runner: each a
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
  "image": "ghcr.io/attilathefun/visor-agent:0.45.3",
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

These checks are the Runner's, not OS Server's: OS Server's own leased
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

## OS Server

The Runner calls nothing of OS Server's for its containers. OS Server, on
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
     servers; then that way of running, and 0.44's container hosts
     (docs/container-host.md), are retired.

## Where it stands (1 November)

The mini's co-tenant is the first container server, set up by hand: Visor's
agent image with `visor-server` in it (visor #151), its server's port
forwarded by a socat LaunchAgent, its MCP servers set to the Runner's MCP
proxy (`visor-runner-agent`, from #169, running on the mini). Its sessions
are marked as a container's (#170), and its pairing code lists the
forwarder's addresses (#171's front paths). Logan: "Don't move yet until
everything is working fine with the visor session in the co-tenant
container."

## Sessions running today

- Sessions in OS Server containers (0.43) run on the Mac from 0.44 on, with
  a notice. Move into a Container then puts them in a 0.44 container.
- Once phase 1 is out, such a session moves to a container server with
  Migrate…. The old one is kept until the new one has answered.
- A server is updated only when its sessions aren't mid-turn.
