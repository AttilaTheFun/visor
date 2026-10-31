# One Runner, several Visor Servers (design)

Status: planned for 0.45. Decided on 31 October 2026, and revised the same
day: the Runner makes each container itself with Apple's `container`, with no
process of its own per container; it is the only thing clients talk to,
passing each on to its server, and every server's MCP proxy.

Today one Mac runs one Visor Server, inside the menu bar app. A session can
run its agent in a Linux container (0.44's container hosts,
docs/container-host.md), but the server stays outside: the container sees
the session's folder and nothing else, so what the server keeps — the
pictures a client attaches, for one — is out of the agent's reach.

This design makes each container a server of its own. One Mac runs any mix:
two sessions on the Mac's own server, five in one container's server, one in
another's, all driven by one menu bar app.

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
- **Visor Runner**: the Mac menu bar app. It runs Visor Servers, natively
  and in containers, and proxies their MCP requests:
  - starts, updates and stops the Mac's Visor Server (a launchd job of its
    own, so updating either leaves the other running);
  - makes, starts, stops and removes each container server's container
    with Apple's `container` command line, and starts the server in it;
  - is the only thing clients talk to: it listens for each server's
    clients (on loopback, the LAN and VPNs as set) and passes their
    connections on to the server;
  - is every server's MCP proxy: the servers' MCP URLs point at it, and it
    adds the secret headers;
  - moves sessions between servers;
  - holds the credentials and gives each server what it needs.

  No process stands between the Runner and a container: a container and the
  server in it run on their own, and the Runner, started again, finds them
  and picks them up.

## Credentials

- **Native sessions:** Claude, Codex and OpenRouter as they sign in on the
  Mac, each in its own way; OpenRouter's key from the Mac's environment.
- **In containers:**
  - Codex: the Mac's sign-in file, copied in. Codex has no token to pass
    instead. If it gets one, it is passed as Claude's is.
  - Claude: an OAuth token set in the Runner, written into each container
    server's agents' environment.
  - OpenRouter: an API key set in the Runner, given the same way.
- **MCP servers' secret headers:** kept by the Runner, added by its proxy.
  No server, native or in a container, holds them.
- **Where the Runner keeps secrets:** in the keychain for notarized builds
  (alpha, production), and in its data folder for debug builds, chosen by a
  Bazel config (`--config=notarized`, tools/secrets).

## Reaching the servers

- The Runner is the only thing clients talk to. For each server it listens
  at that server's port, on loopback always and on the LAN and VPNs as
  set, and passes each connection on to the server, the bytes both ways
  as they come (HTTP, the WebSocket).
- The servers listen in plain HTTP where only the Runner reaches them:
  the Mac's on loopback; a container's on its own port, which `container`
  publishes to a port of the Mac's loopback (`--publish 127.0.0.1:…`).
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
- While the Runner is not running (quit, or updating), servers and agents
  run on; clients can't reach them, and their MCP calls fail, until it is
  back. Whether the proxies run in a background agent of the Runner's (a
  LaunchAgent the menu bar app installs and talks to), so that they outlive
  the app, is open; the Runner's logic is a library either way.

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
  "mounts": [{"source": "/Users/me/Developer", "destination": "/Users/me/Developer"}],
  "listen": {"port": 7440, "lan": true, "vpn": true},
  "loopbackPort": 17440,
  "stopped": false
}
```

- **`state.json`:** what the Runner last found (below).
- **Its secrets** (the server's password, its MCP token, the sign-ins): the
  Runner's, kept as all its secrets are.

What the Runner does with Apple's `container`:

- **Makes it:** two volumes, its home (`/root`) and Bazel's output
  (`/var/cache/bazel`), then the container from the image with the mounts,
  the volumes, its limits, its server's port published to the Mac's
  loopback at `loopbackPort` (by default the clients' port plus 10000), and
  a label naming the container server. The container's main process only
  waits.
- **Fronts it:** listens at the clients' port (`listen`) and passes each
  connection on to `loopbackPort`, for as long as the server runs.
- **Starts the server in it:** sets its password (`visor-server password`,
  on standard input), writes the agents' sign-ins, then starts
  `visor-server start` detached (an exec not tied to the exec's stream),
  its `--address` the Mac's address for it, so its codes lead with that.
  Then sets its MCP servers to the Runner's.
- **Picks it up:** when the Runner starts, it lists the containers it made
  (by label), starts any stopped one that isn't marked stopped, starts the
  server in any that isn't answering, and gives credentials and MCP
  settings again where they changed.
- **Upgrades it:** the container made again from the image `server.json`
  now names, its volumes kept, so its sessions are as they were and their
  agents resume.
- **Stops it:** `container stop`; its volumes are kept, and Start starts it
  again.
- **Removes it:** the container, and its volumes with it, and with them its
  sessions; its folder and secrets go too.

### The server inside

- **Its disks:** its home holds the server's data
  (`~/.local/share/visor`: sessions, attachments), the agents' own
  transcripts (`~/.claude`, `~/.codex`, `~/.openrouter`), which a resumed
  session reads, and their sign-ins. Kept until it is removed.
- **Its agents' sign-ins:** Claude's `CLAUDE_CODE_OAUTH_TOKEN` in its
  `agents/claude.env` (in the server's data), OpenRouter's
  `OPENROUTER_API_KEY` in `agents/openrouter.env`, Codex's `auth.json` at
  `~/.codex/auth.json`.

### Health

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
the same Mac, watches the Mac's containers (`container list`, `stats`) and
counts their memory against its budget for what it lends.

## Moving sessions

- Between any two servers: the Mac's and a container's, or two containers'.
- Visor's Migrate… already moves a session between servers. The client
  carries the conversation's files and the projects across, and the other
  server resumes the session; the original is left until the new one works.
- The Runner adds a move of its own for servers that see the same folder (a
  container mounts the Mac's folders at their own paths). It carries the
  conversation and leaves the project where it is.

## Phases

1. **One container server, end to end, from the Runner.**
   - The Linux `visor-server` in Visor's agent image.
   - The Runner makes, starts, picks up, upgrades, stops and removes
     container servers with `container`; their ports published; their
     health checked; their sign-ins given.
   - The Runner's MCP proxy, which the container servers are configured
     with.
2. **The Runner's side in Settings.**
   - Container servers made and removed, started and stopped.
   - The Claude token and OpenRouter key set there.
   - A code for each server.
3. **The Mac's server apart from the Runner.**
   - `visor-server` runs as a launchd job that the menu bar app installs,
     updates and stops, and keeps the menu bar app's data folder, so
     sessions, pairings and codes carry over.
   - Its MCP servers are the Runner's too.
   - The Runner's settings and menu read and change it through its local
     API.
4. **Moving sessions.**
   - Moving between servers from the Runner.
   - Today's agent-in-a-container sessions (0.44) moved onto container
     servers; then that way of running, and 0.44's container hosts
     (docs/container-host.md), are retired.

## Sessions running today

- Sessions in OS Server containers (0.43) run on the Mac from 0.44 on, with
  a notice. Move into a Container then puts them in a 0.44 container.
- Once phase 1 is out, such a session moves to a container server with
  Migrate…. The old one is kept until the new one has answered.
- A server is updated only when its sessions aren't mid-turn.
