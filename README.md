# Visor

Remote agent sessions: Visor Server, a Mac menu bar app (or `visor-server`,
the same server as a command for Linux and Windows), runs Claude Code, Codex
and the openrouter CLI as subprocesses on the host and serves them to your
devices over whatever reaches the host — a LAN, a VPN, a reverse proxy, a
tunnel; a SwiftUI client for iPhone, iPad and Mac adds a computer from its
connection code, starts sessions, chats with them and watches their
progress, and opens terminal sessions — the Mac's own shell, drawn in
SwiftUI over SwiftTerm's emulator — to run anything there directly.

## Parts

- **applications/visor_menubar** — the host, Visor Server
  (`com.LoganShire.VisorServer.macOS`). A menu bar app (`LSUIElement`)
  running `VisorServer`: one listener (port 7433) for the WebSocket at `/`
  and the REST side under `/api`, on loopback alone or on every interface
  when opened to the network, plain or over TLS with a PKCS#12 identity.
  A password (required — Settings opens on first launch until one is
  set) is what every client signs in with. The menu shows the address
  clients take, the password, Copy Connection Code, the connected
  clients and the sessions; Settings shows the connection code as a QR
  code, and takes the network setting, the address a front of your own
  gives, and the TLS identity. The server knows nothing of what reaches
  it: a LAN, a VPN, a reverse proxy and a tunnel are all the same to it.
- **applications/visor_ios**, **applications/visor_macos** — the client on
  shared host sources: an inset grouped sidebar with a section per
  computer (its connection state in the header, its sessions, its
  settings last), the transcript and composer from AgentUI. A computer
  is added by pasting its connection code or scanning its QR code
  (`visor://connect?code=…`). Each computer is one agent server; what
  the client does with a server — signing in, the live channel, and
  every operation on sessions, folders and files — is the `AgentServer`
  protocol, and `HTTPAgentServer` (the wire protocol: `hello`, ws(s) +
  http(s) with a bearer, at any URL or a bare name; followed by
  polling where the road carries no WebSocket) is the one shipped.
  On a Mac or an iPhone the address can also be the computer's own SSH
  (Remote Login), `user@host[:port]`, through jump hosts if need be
  (`?via=user@jump`): the client opens the connection with a key it
  makes and keeps, and runs the same wire protocol through a port
  forwarded to the server's loopback — nothing open on the network but
  SSH, and nothing added to the server. A fork that hosts agents on
  its own service registers an `AgentServerProvider` with its own
  `AgentServer`, and an `AgentServerProviderUI` with its own sign-in
  view; a new session goes to the one connected server, or to the one
  picked.
- **libraries/visor_protocol** — the wire format (docs/protocol.md) and its
  own small JSON, with no Foundation, so the same code runs wherever the
  client is carried.
- **libraries/visor_services** — what a host gives the client: a socket,
  HTTP, settings and, where it has it, SSH. Apple implementations sit
  beside the protocols.
- **libraries/visor_client** — agent servers and their providers,
  connections, transcripts, the session cache.
- **libraries/visor_ui** — the views, on AgentUI and NavigationUI.
- **libraries/visor_server** — the server: sessions, agent processes
  (Claude, Codex, the openrouter CLI from github.com/AttilaTheFun/
  open_router_cli, which speaks Claude's stream-json protocol), the
  archive, the HTTP and WebSocket listeners. Agents are configured
  outside Visor (`claude`, `codex login`, `openrouter auth login`). It is
  the same on every system and asks the system for nothing except
  through the `ServerPlatform` it is given: sockets, terminals, process
  signals, secrets, pushes, picture headers, file watching, tool paths.
- **libraries/visor_server_apple**, **…_posix** — the Mac's platform (the
  Network framework, the keychain, CryptoKit, ImageIO) and what macOS and
  Linux share (terminals, signals and sockets, through a small C shim).
- **libraries/visor_server_cli**, **…_linux**, **…_windows**,
  **applications/visor_server_linux**, **…_windows** — `visor-server`,
  the command-line server, and each system's platform for it (Linux:
  POSIX; Windows: Winsock and ConPTY).

## Building

Bazel with rules_swift, rules_apple and rules_xcodeproj; AgentUI comes in
through rules_swift_package_manager from third_party/swift_packages.

    bazel build //applications/visor_menubar //applications/visor_macos
    bazel build --ios_multi_cpus=sim_arm64 //applications/visor_ios
    bazel test //tests/...
    bazel run //:xcodeproj     # generates Visor.xcodeproj for Xcode (not committed)

The command-line server for Linux and Windows is SwiftPM's (Package.swift
at the root; Swift 6.2 or later, and on Linux `libsqlite3-dev`):

    swift build -c release --product visor-server
    .build/release/visor-server            # run here, saying what it does
    .build/release/visor-server start      # or in the background (stop, status)
    .build/release/visor-server code       # the connection code to add it with

Needs Xcode 27 and Bazelisk. The bundle ids are constants at the top of
each app's BUILD.bazel; your Apple team id goes in a `.bazelrc.user` you
keep (`common --repo_env=VISOR_TEAM_ID=<team>`), for signing for a device. The agents are configured on their own — `claude`,
`codex login`, and [`openrouter`](https://github.com/AttilaTheFun/open_router_cli)
`auth login`. docs/DEVELOPMENT.md has the full setup, the architecture, and
the deploy loop.

## Contributing

Pull requests into `main`. Read AGENTS.md for the rules the code keeps.

`//:swift_ui` is a label flag for where `import SwiftUI` comes from. On
Apple it points at nothing (the system framework); a build that carries
the client to another platform sets it to its own SwiftUI.

## Security

Visor gives whoever connects to it the run of your Mac. Read this before
you install it.

- **What access means.** A connected client starts agents in any folder,
  and they run without permission prompts by default. It can also read
  and write any file your user account can, through the API, and install
  an app bundle over Visor Server. Treat access to Visor like an SSH
  login to your Mac.
- **Who can reach it.** By default the server listens on this Mac's
  loopback address only, and a reverse proxy or a tunnel on the Mac is
  the road in; opened to the network in Settings, it listens on every
  interface, for a LAN, a VPN or a tunnel to reach directly. Every
  device signs in with the password; nothing about the road is trusted.
  Keeping the server off the public internet — on a VPN, behind a front
  that authenticates — is yours to do.
- **The password and the connection code.** The connection code, and the
  QR code that carries it, holds the password in plain base64. Share it
  only with your own devices. The password is kept in the keychain, by
  Visor Server and by each client that saves it; the apps are signed so
  that each build reads its own items without a prompt.
- **On a shared network, use a long password.** The generated password,
  four words from a short list, is easy to type rather than strong, and
  wrong guesses are not rate-limited. Anyone who can reach the port can
  try.
- **Revoking access.** Changing the password stops new logins. Clients
  that are already connected keep their session until you quit and
  reopen Visor Server.
- **Agents.** Claude Code, Codex and `openrouter` run as your user with
  your credentials, configured outside Visor. Visor holds no API keys.

Report vulnerabilities privately; see [SECURITY.md](SECURITY.md).

## License

Apache 2.0.
