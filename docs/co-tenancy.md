# One Runner, several Visor Servers (design)

Status: planned for 0.45. The decisions below were taken on 31 October 2026.

Today one Mac runs one Visor Server, inside the menu bar app. A session can
run its agent in a Linux container (0.44's container hosts,
docs/container-host.md), but the server stays outside: the container sees
the session's folder and nothing else, so what the server keeps — the
pictures a client attaches, for one — is out of the agent's reach.

This design makes each container a server of its own. One Mac runs any mix:
two sessions on the Mac's own server, five in one container's server, one in
another's, all driven by one menu bar app.

## The parts

- **Visor Runner**: the Mac menu bar app. It controls, and serves nothing
  itself:
  - starts, updates and stops the Mac's Visor Server and each container's
    host, every one a launchd job of its own, so that updating any of them
    — the Runner too — leaves the others' sessions running;
  - makes and removes container servers;
  - moves sessions between servers;
  - holds the credentials and gives each server and host what it needs.
- **Visor Server**: `visor-server`, one Swift binary for macOS and Linux
  (the server library, as now).
  - On the Mac it runs the native sessions: agents as the user, signed in
    as they are on the Mac.
  - In a container it runs that container's sessions. Its agents, their
    transcripts and attachments, and the agents' hosts are all inside the
    container, so an attached picture is where the agent reads it.
- **Container host**: one per container, a program on the Mac (a launchd job
  of the Runner's). The Runner is set up with one kind (see The container
  host's interface): Visor's own, which runs the container itself with
  Apple's `container`, or OS Server's adapter, which runs it on an OS Server
  lease. It replaces 0.44's container host, which stays as it is until this
  lands.
  - Makes its container and keeps it.
  - Starts the Visor Server in it.
  - Reverse-proxies that server for the clients, on a port of its own. To a
    client, each container server is a computer of its own, with its own
    id, address and code.
  - Proxies the MCP servers for the container's agents (GitHub's, OS
    Server's), adding the credentials the Runner gave it. Nothing secret
    enters the container but the agents' own sign-ins.

## Credentials

- **Native sessions:** Claude, Codex and OpenRouter as they sign in on the
  Mac, each in its own way; OpenRouter's key from the Mac's environment.
- **In containers:**
  - Codex: the Mac's sign-in file, copied in. Codex has no token to pass
    instead. If it gets one, it is passed as Claude's is.
  - Claude: an OAuth token set in the Runner. The Runner gives it to each
    container host, and the host to its server's sessions.
  - OpenRouter: an API key set in the Runner, given the same way.
- **MCP endpoints' secret headers:** the Runner gives them to the Mac's
  server and to each container host. Each adds them as it proxies.
- **How a container host gets them:** its `credentials` command (see The
  container host's interface).
- **Where secrets are kept:** in the keychain for notarized builds (alpha,
  production), and in the data folder for debug builds, chosen by a Bazel
  config.

## Reaching the servers

- The Mac's server is reached as today.
- A container's server is reached at its container host's port on the Mac,
  on the network paths the Runner sets for it (the LAN, a VPN, SSH, a
  reverse proxy of your own).
- The Runner shows each server's connection code.
- Clients already keep several computers, so a Mac with three servers is
  three computers in the sidebar.

## Moving sessions

- Between any two servers: the Mac's and a container's, or two containers'.
- Visor's Migrate… already moves a session between servers. The client
  carries the conversation's files and the projects across, and the other
  server resumes the session; the original is left until the new one works.
- The Runner adds a move of its own for servers that see the same folder
  (a container mounts the Mac's folders at their own paths). It carries the
  conversation and leaves the project where it is.

## The container host's interface (version 2)

A container host is a program the Runner is set up with, spoken to on its
command line, with JSON in and out (as 0.44's, docs/container-host.md, which
this replaces):

- **Visor's own:** `visor-container-host`, in Visor Server's bundle. It runs
  the container with Apple's `container`.
- **OS Server's:** `oss container-host`. It runs the container on a lease
  held until released, so OS Server counts it with everything else it lends.

### A container server's folder

Each container server has a folder of the Runner's,
`<Runner data>/container-servers/<id>/`, that holds:

- **`server.json`:** what it is, written by the Runner and never secret:

```json
{
  "api": 2,
  "id": "<uuid>",
  "name": "Builds",
  "image": "ghcr.io/attilathefun/visor-agent:0.45.3",
  "cpus": 6,
  "memoryBytes": 17179869184,
  "diskBytes": 137438953472,
  "mounts": [{"source": "/Users/me/Developer", "destination": "/Users/me/Developer", "readOnly": false}],
  "listen": {"port": 7440, "lan": true, "vpn": true},
  "mcp": [{"name": "gh", "url": "http://127.0.0.1:7450/mcp", "headers": {"X-Visor-Session": "$SESSION_ID"}, "secretHeaders": ["Authorization"]}]
}
```

  - `mounts`: this computer's folders, each at its own path.
  - `listen`: where clients reach the container's server on this computer
    (loopback always; the LAN and VPNs as set).
  - `mcp`: the MCP servers its agents may use. A secret header's value is
    never here: see `credentials`.
- **`state.json`:** what the host last found (see `status`), written by
  `serve`.
- **The host's own files:** its log, and in a debug build its secrets
  (mode 600). A notarized build keeps them in the keychain.

### The commands

Every command but `serve` answers one JSON object on standard output,
exiting 0, or 1 with `{"error", "code"?}`, as 0.44's do.

- **`<host> health`:** `{"ok", "name", "version", "api": 2, "limits"}`.
  Whether this host can make container servers now (as 0.44's).
- **`<host> serve <folder>`:** the long-running process, the Runner's launchd
  job for this server (kept alive). It:
  - makes the container if there is none, or starts it if it has stopped;
  - starts the Visor Server in it if it isn't running (below);
  - proxies the clients' connections and the agents' MCP calls;
  - gives the server its credentials, and again whenever they change;
  - writes `state.json` as it goes.

  Ended (SIGTERM, an update of the host), it stops proxying and leaves the
  container and its server running. Started again, it picks them up.
- **`<host> status <folder>`:**

```json
{"state": "starting|ready|stopped|failed",
 "container": "<the host's id for it>",
 "server": {"version": "0.45.3", "answering": true, "sessions": 5},
 "address": "http://<this computer>:7440",
 "code": "<the server's connection code>",
 "network": {"ok": true, "detail": "…"},
 "error": "…"}
```

  `code` is the server's own (its `GET /api/code`), leading with `address`,
  for the Runner to show.
- **`<host> credentials <folder>`:** reads `{"claudeToken"?,
  "openrouterKey"?, "codexAuth"?, "mcpSecrets"?: {"<name> <header>":
  "<value>"}}` from standard input and keeps them in the host's secrets. A
  running `serve` takes them up.
  - `codexAuth` is the Mac's `~/.codex/auth.json`, base64.
  - A field left out stays as it was; `null` takes it away.
  - Answers `{"kept": [<the fields kept>]}`. Values are never echoed.
- **`<host> stop <folder>`:** stops the container, and with it the server and
  its agents. Its disks are kept, and `serve` starts it again.
- **`<host> upgrade <folder>`:** makes the container again from the image
  `server.json` now names. Its disks are kept, so its sessions are as they
  were and their agents resume.
- **`<host> remove <folder> [--data]`:** removes the container. With
  `--data` its disks go too, and with them its sessions. Without it, a
  later `serve` starts the same server again.

### The server inside

- **Its disks:** its data at `/var/lib/visor` (VISOR_DATA_DIR: sessions,
  transcripts, attachments) and Bazel's output at `/var/cache/bazel`. Both
  are kept until `remove --data`.
- **Started detached** by the host (`visor-server run`, from the image), so
  a host that restarts leaves it, and the agents under it, running.
- **Its password:** made by the host when the container is made, and kept in
  the host's secrets. Its settings point its codes at the host's `address`.
- **Its agents' sign-ins**, from `credentials`:
  - Claude: `CLAUDE_CODE_OAUTH_TOKEN` in its `agents/claude.env`;
  - OpenRouter: `OPENROUTER_API_KEY` in `agents/openrouter.env`;
  - Codex: the Mac's `auth.json`, at `~/.codex/auth.json`.
- **Its MCP servers** are set by the host (the server's `PUT /api/mcp`) to the
  host's own proxy:
  - The proxy is reached at an address this computer has on the container's
    network.
  - Each call carries a token that only this container's proxy takes.
  - The host adds the secret headers as it passes the call on, so no
    secret header enters the container.

### Clients

- A client reaches the server at `address`. The host passes the bytes both
  ways (HTTP, the WebSocket), and serves TLS there when the Runner gives it
  an identity.
- The server is a computer of its own to the client: it is added from its
  code, which the Runner shows.

### Health

- `serve` asks the server every 30 seconds (`GET /api/hello`).
- When that fails, it checks the container's network (DNS and HTTPS, as
  0.44's `network`) and makes the container again, with its disks, when the
  network is lost.
- `state.json` and `status` say what it found.

### Moving a session in or out

- No command of the host's: sessions move through the servers' own API
  (Migrate…, and the Runner's move).
  - The session's server offers its conversation's files.
  - The other server says what it will do with them and with the projects.
  - The files are carried across, a piece at a time, through each server's
    address.
- A container mounts the Mac's folders at their own paths, so a project
  moves between the Mac's server and a container's without being copied.

### OS Server's adapter

The same commands, through OS Server:
- The container is a container lease held until released, its labels
  naming the container server.
- `address` is the adapter's own proxy, or the lease's forwarded port.
- The MCP proxy is the adapter's, with the secrets it keeps.
- `remove` releases the lease, and with `--data` deletes its volumes.

## Phases

Container servers come first: they are new code beside today's, and they
are what fixes the attachments and puts several sessions in one container.
Migrate… already moves a session between any two servers, so a container
server is usable as soon as it can be made.

1. **One container server, end to end.**
   - The container host binary, and the Linux `visor-server` in Visor's
     agent image.
   - The host makes the container, starts the server, proxies it and its
     MCP servers, and gives it its credentials.
   - Started and stopped from the menu bar app as a launchd job of its own.
2. **The Runner's side.**
   - Container servers made and removed from the menu bar app.
   - The Claude token and OpenRouter key set there.
   - A code for each server.
3. **The Mac's server apart from the Runner.**
   - `visor-server` runs as a launchd job that the menu bar app installs,
     updates and stops.
   - It keeps the menu bar app's data folder, so sessions, pairings and
     codes carry over.
   - Secrets: the keychain or the data folder, by build.
   - The Runner's settings and menu read and change the server through its
     local API.
4. **Moving sessions.**
   - Moving between servers from the Runner.
   - Today's agent-in-a-container sessions (0.44) moved onto container
     servers; then that way of running is retired.

## Sessions running today

- Sessions in OS Server containers (0.43) run on the Mac from 0.44 on, with
  a notice. Move into a Container then puts them in a 0.44 container.
- Once phase 1 is out, such a session moves to a container server with
  Migrate…. The old one is kept until the new one has answered.
- A server is updated only when its sessions aren't mid-turn.
