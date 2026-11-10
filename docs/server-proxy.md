# A plain server behind a proxy (design, Visor 0.50)

Logan, 10 Nov 2026: Visor's server becomes a plain HTTP server on one port,
with no authentication of its own, unreachable except through a proxy. The
proxy does everything that depends on where a client is and who it is:
HTTPS, SSH, the choice of localhost, the LAN or the tailnet, and signing in.
Containers, the GitHub proxy and remote access leave Visor. Visor 0.49 is
the small release before it (isomer 0.50); this is the 0.50 line.

## Decided (Logan, 10 Nov)

- **The server has no auth.** It listens where only its proxy reaches it,
  and trusts what comes. The proxy authenticates: it can mint auth codes a
  client sends as headers, and at work it uses Okta.
- **Remote clients always come through a proxy**, which terminates HTTPS,
  serves SSH, and switches between localhost, the LAN and the tailnet. The
  server knows none of that.
- **Visor.app is a client again**, with a menu bar proxy in it: the proxy
  for this Mac's server, and the one that adds auth to MCP calls.
- **Three programs in Visor.app, and a client alone in Shireworks** (Logan,
  10 Nov: "the shireworks visor tab should just be client only and we're
  just running an instance of the visor server in its primary container (if
  it has one) and independently Visor.app has the notarized native mac
  client, visor server swift binary and native mac visor proxy swift
  binary. the proxy can proxy to and from both the container server and
  native server"). Visor.app, notarized, carries the native client, the
  `visor-server` binary and the proxy's binary, each its own process.
  Shireworks.app embeds the client alone (VisorUI's VisorView, its own
  computers added by hand) and runs no proxy and no server of its own; a
  Visor server runs in Shireworks' primary container, and Visor.app's proxy
  fronts it beside the Mac's own.
- **The server serves Visor's MCP itself** (sending messages, asking the
  person), on Linux as on the Mac, and passes the agents' other MCP servers
  (Shireworks', any configured) on to the proxy generically.
- **Agents use the server's MCP proxy**, in their own environment: on the
  computer, or in a container.
- **The GitHub proxy is optional and external**, provided by Shireworks.
  Without it, a session runs where its real GitHub sign-in is.
- **Containers leave Visor.** Shireworks keeps a "primary container"
  always on and restarted (not leased); a Visor server in it is a server
  like any other, behind the proxy, by port forwarding Shireworks sets up.
  At work the same place is taken by the in-house sandboxes (abox,
  sandcastle).
- **Pushes:** clients register their device tokens with the server, and the
  server's calls to APNs go out through the proxy, which holds the APNs key.
- **Messages between computers stay client-carried** (the relay: each
  client reports the servers it holds and carries their messages). Proxies
  carry no messages.
- **Agents are kept from the settings by where they run, not by a token**
  (Logan, 10 Nov: "the goal is eventually all of my sessions will run
  inside containers so the'll never be in an environment where they can
  change the proxy settings"). What an agent must not change (the MCP
  servers and their keys, where pushes go, who may sign in) is the proxy's,
  outside the container; the server checks nothing.

## Today

The server does all of it itself:

- **Access** (VisorServer+Access): a password, connection codes carrying
  it, and tokens `hello` hands out; agents get tokens of their own, refused
  on the settings routes.
- **Reaching** (+Reaching, +Listening, TLSIdentity, FrontDoor): loopback or
  every interface, plain or TLS with a given certificate, a socket file for
  clients that come over the computer's own SSH, and the addresses a client
  learns from `hello`. The client probes paths (localhost, LAN, VPN, SSH:
  libraries/visor_ssh) per server.
- **SSH keys** (+SSHKeys): a device authorizes its key into this user's
  `authorized_keys`.
- **Pushes** (+Push, APNsSender, PushSigning, APNsKey): signed with the
  owner's APNs key when this computer has one, else through the push proxy
  (+PushProxy, the Runner's `/apns/`).
- **MCP** (+MCPProxy, MCPProxy): Visor's own MCP for the agents, and the
  configured MCP servers passed on, through the Runner's `/mcp/<name>` for a
  server that holds no keys.
- **GitHub** (+GitHubProxy): agents started with HTTPS_PROXY at the
  Runner's GitHub proxy (libraries/visor_runner's GitHubGate).
- **Containers** (+Containers, +ContainerChecks, +ContainerRegistry,
  +ContainerUpgrades, ContainerHost…, docs/container-host.md): a session's
  agent in a container from a container host, moving in and out, sign-ins
  copied in, the network checked.
- **Fronts** (`visor-server front`, settings' `frontPaths`): the Runner's
  port for a container's server, and the mini's socat forwarders.

The Runner (libraries/visor_runner, docs/runner-accounts.md) is already
most of a proxy: a sign-in with sessions (RunnerAuth, RunnerSessions), each
server it runs reverse-proxied by path (`/runner/v1/servers/<id>/…`, HTTP
and WebSocket), its own certificate (RunnerIdentity), the MCP and APNs
proxies with a token per server (`X-Visor-Proxy`), and a watch that starts
a server again (ServerWatch). What it lacks is being the only way in.

## The server's contract

What a server needs, whoever its proxy is (Visor's Runner, Shireworks' for
a container, abox or sandcastle at work):

- **One port, HTTP.** The REST side under `/api` and the live channel (a
  WebSocket) at `/`, as FrontDoor has them now. No TLS, no password, no
  connection codes. It listens on the address it is given: loopback on a
  Mac, the container's own interface in a container, never every interface
  unless told.
- **Its proxy's URL and token**, set once (`visor-server proxy <url>`, the
  token on standard input), for what goes out:
  - `<proxy>/mcp/<name>`: an MCP server passed on to the agents; the proxy
    adds its credentials.
  - `<proxy>/apns/<APNs host>/3/device/<token>`: a push, unsigned; the
    proxy signs it.
  
  Each with `X-Visor-Proxy: <token>`, as now. A server with no proxy set
  sends no pushes and passes no MCP servers on; Visor's own MCP still works.
- **What a request may carry from the proxy** (optional; a server works
  without them): `X-Visor-User`, the signed-in person's name, for the
  server to show; and the client's own address, for the log.
- **Agents** reach it on the same port, as now: Visor's MCP script with the
  session's token, which says which session calls (an identity, not a
  credential).

That is all of it. No path, no network, no certificate and no person is
the server's business.

## The proxy's job

Visor's own proxy is the Runner's program (libraries/visor_runner; today
`visor-runner-agent`), a binary in Visor.app's bundle that the menu bar
app starts and keeps up, as it does the Mac's `visor-server` (today the
server runs in the app's own process). Nothing of it is in Shireworks.app.
The fork's proxy is its sandboxes' front. Each:

- **Reaches its servers**, both ways: this Mac's on loopback, and the one
  in Shireworks' primary container at the port Shireworks forwards to the
  Mac's loopback (Containers, below); a Linux or Windows server elsewhere
  by whatever path its owner gives (an SSH tunnel the proxy holds, a
  forwarded port). And each server reaches it, for its MCP servers and
  pushes: the Mac's on loopback, the container's at the Mac's address on
  Shireworks' containers' network, where the proxy listens for servers
  alone (each with its own token, `X-Visor-Proxy`).
- **Lets clients in**: HTTPS with its own certificate (the tailnet's from
  Tailscale, else its own, pinned on first use: runner-accounts.md step 5c),
  on localhost, the LAN and the tailnet, and over SSH for a client with no
  open port. The client keeps one account per proxy and picks the path; a
  proxy's addresses are the paths, not a server's.
- **Signs people in**: RunnerAuth's providers (a password; OpenID Connect,
  which is Okta at work; GitHub), a session per client, and the auth codes
  it mints, sent as a header (`Authorization: Bearer`, or `runner_session`
  where a WebSocket can send no header).
- **Lists and fronts its servers**: `GET /runner/v1/servers`, and each one's
  API and channel at `/runner/v1/servers/<id>/…`, passed on with the person
  checked and nothing of theirs forwarded but `X-Visor-User`.
- **Holds the credentials**: the APNs key, the MCP servers' keys, never a
  server.
- **Keeps its servers up** (ServerWatch).

## Containers

Visor has no container code. Shireworks keeps a primary container per
computer that asks for one: always on, started again when it stops, not
leased. A Visor server runs in it as on any Linux computer, and Visor.app's
proxy fronts it beside the Mac's own. A session is on the Mac or in that
container by which server it was started on; there is no moving between
them.

What the container's server needs of Shireworks:

- **The image**: Visor's agent image, `ghcr.io/attilathefun/visor-agent:<MAJOR.MINOR>`
  (tools/containers/visor-agent), the released line's: `visor-server` and
  `visor-agent-host` in /usr/local/bin, the agents' command lines, git,
  Bazelisk. Shireworks follows the line Visor releases.
- **Its command**: `visor-server --port 7433`, listening on the container's
  own interface, with its proxy's URL and token given at start (step 2's
  setting: the Mac's address on the containers' network and the proxy's
  port, the token from Visor.app's proxy). Started again when it stops;
  its agents outlive a restart under their hosts, as on the Mac.
- **One port forwarded**: the container's 7433 to a port on the Mac's
  loopback alone (not the LAN), which the proxy is told (`server reach
  <id> --at 127.0.0.1:<port>`, or from Shireworks' API: Open questions).
- **Three volumes**, kept across restarts and new images
  (self-contained, no mounts of the Mac's folders): `/root`, the home (the
  server's data at ~/.local/share/visor, the agents' sign-ins,
  conversations and memory); `/workspaces`, the cloned source; and
  `/var/cache/bazel`.
- **The way out**: the internet, and the Mac's address on the containers'
  network for the proxy (its MCP servers, pushes); GitHub through
  Shireworks' GitHub proxy where it has one, else the agents' own sign-in.

Agents in the container run beside their server and reach it on loopback,
their MCP through it to the proxy as any server's.

## What goes, and from where

| Goes | Where it is | Taken by |
|---|---|---|
| Password, connection codes, client tokens, `/codes` | +Access, +Identity, ConnectionCodes (protocol, client) | the proxy's sign-in |
| TLS, every-interface listening, LAN/VPN addresses in `hello` | +Listening, TLSIdentity, +Reaching | the proxy's listeners |
| The SSH socket and device keys | +Listening's socket file, +SSHKeys, `/ssh/keys`; libraries/visor_ssh in the client | the proxy's SSH |
| Direct APNs (the key, signing) | APNsKey, PushSigning, APNsSender's signing, `/push/key` | the proxy's `/apns/` |
| Container sessions, the host, moving in and out, container checks and upgrades | +Containers, +ContainerChecks, +ContainerRegistry, +ContainerUpgrades, Container*, applications/visor_container_host, docs/container-host.md | Shireworks' primary container |
| Fronts and front paths | `visor-server front`, `frontPaths`, the Runner's per-server port | the proxy's path per server |
| The GitHub proxy's setup | +GitHubProxy, `/github-proxy`; GitHubGate and its rules in libraries/visor_runner | Shireworks |
| The Mac's server in Visor.app's own process | applications/visor_mac (VisorServer linked in) | the bundled `visor-server`, started by the app |
| Code-added computers in the client | AgentServerRecord's password and paths, Add Computer's code | an account per proxy (runner-accounts.md, "the version after") |

What stays: sessions and agents, transcripts, the relay and mail, Visor's
MCP and the MCP servers passed on, push device tokens, migration between
servers (client-carried, as the relay is), the agent hosts that outlive a
restart, and the settings that are the server's own.

## Versions

- **0.49** (the small release): nothing of this.
- **0.50**: the server takes the contract and the Runner is the only way in;
  a 0.50 client reaches servers only through a proxy account. A 0.49 client
  can't reach a 0.50 server directly, so 0.50's release notes say to sign
  in to the Runner first: every client since 0.47 has Runner accounts
  (runner-accounts.md step 5), which the version between was for.
- A server run without a proxy (the Linux `visor-server` on its own, for
  development) listens on loopback alone, and a client on the same computer
  reaches it there.

## Steps (0.50)

1. This design.
2. **The server's proxy setting** (`visor-server proxy`), pushes and MCP
   through it alone, and listening on the given address; the password and
   codes still there. Tests.
3. **Three programs in Visor.app**: the Mac's `visor-server` and the
   proxy's binary in the bundle, started and kept up by the menu bar app,
   the server out of the app's own process.
4. **The proxy as the only way in**: Visor.app's client signs in to its
   own proxy at loopback (runner-accounts.md), the proxy fronts this Mac's
   server and the container's (and listens for the container's server on
   the containers' network), its listeners for the LAN and the tailnet,
   and pinning on first use (step 5c).
5. **The server without auth**: the password, codes, tokens for clients,
   TLS, the SSH socket and keys, and direct APNs removed; `X-Visor-User`
   shown. No guard takes the agent token's place on the settings routes:
   the settings that matter move to the proxy, and the server's own proxy
   setting is given by what starts it (Shireworks, for its container), as
   Logan decided.
6. **The client without code-added computers**: records only from
   accounts; visor_ssh's transport and per-server path probing removed.
7. **Containers out**: the container code, visor-container-host and the
   fronts removed, with Shireworks' primary container running Visor's
   server in place (its own work, in Shireworks: Containers, above), and
   the GitHub proxy's setup with it.

Each step is its own pull request with its tests, on the 0.50 line.

## Open questions

- **Where Shireworks' primary container's port is told to the proxy**:
  Shireworks' API (the primary container and its forwarded ports), or the
  proxy's own `server reach` as now; and how the container's server is
  given the proxy's token (Shireworks' secret for the container, or the
  proxy writing it to the container's volume). To agree with Shireworks.
- **SSH at the proxy**: the Runner serving SSH itself, or a client's SSH
  tunnel to the Mac's own sshd reaching the Runner on loopback (no SSH code
  of Visor's at all).
