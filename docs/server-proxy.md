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

Visor's own proxy is the Runner, in Visor.app's menu bar on a Mac (and in
Shireworks.app beside Shireworks' server). The fork's is its sandboxes'
front. Each:

- **Reaches its servers**: this Mac's on loopback; one in Shireworks'
  primary container by the port Shireworks forwards; a Linux or Windows
  server elsewhere by whatever path its owner gives (an SSH tunnel the
  proxy holds, a forwarded port).
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
leased. A Visor server runs in it as on any Linux computer (the
`visor-server` binary, its data on the container's volume), listening on
the container's interface; Shireworks forwards a port of the Mac's to it,
and the Mac's proxy adds that server to the ones it fronts. Agents in the
container run beside their server and reach it on loopback; their MCP goes
through it to the proxy as any server's does. A session is on the computer
or in that container by which server it was started on; there is no moving
between them.

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
3. **The Runner as the only way in**: Visor.app's client signs in to its
   own Runner at loopback (runner-accounts.md), the Runner fronts this Mac's
   server, its listeners for the LAN and the tailnet, and pinning on first
   use (step 5c).
4. **The server without auth**: the password, codes, tokens for clients,
   TLS, the SSH socket and keys, and direct APNs removed; `X-Visor-User`
   shown.
5. **The client without code-added computers**: records only from
   accounts; visor_ssh's transport and per-server path probing removed.
6. **Containers out**: the container code, visor-container-host and the
   fronts removed, with Shireworks' primary container in place (its own
   work, in Shireworks), and the GitHub proxy's setup with it.

Each step is its own pull request with its tests, on the 0.50 line.

## Open questions

- **Agents and the person, without auth.** Today an agent's token is
  refused on the settings routes (the MCP servers, the push and GitHub
  proxies, restart, quit), so an agent can't act as the person. With no
  auth an agent on the same loopback could call them. The smallest guard is
  the proxy's own token on the requests it passes on (`X-Visor-Proxy`,
  which the server already holds for what goes out), required on those
  routes: not a person's credential, only proof the request came through
  the proxy. To decide with Logan.
- **Where Shireworks' primary container's port is told to the Runner**:
  Shireworks' API, or the Runner's own `server reach` as now.
- **SSH at the proxy**: the Runner serving SSH itself, or a client's SSH
  tunnel to the Mac's own sshd reaching the Runner on loopback (no SSH code
  of Visor's at all).
