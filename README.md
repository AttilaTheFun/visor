# Visor

Remote agent sessions: Visor Server, a Mac menu bar app (or `visor-server`,
the same server as a command for Linux and Windows), runs Claude Code, Codex
and the openrouter CLI as subprocesses on the host and exposes them over
Tailscale; a SwiftUI client for iPhone, iPad and Mac adds a Mac from its
connection code, starts sessions, chats with them and watches their
progress, and opens terminal sessions — the Mac's own shell, drawn in
SwiftUI over SwiftTerm's emulator — to run anything there directly.

## Parts

- **applications/visor_menubar** — the host, Visor Server
  (`com.LoganShire.VisorServer.macOS`). A menu bar app (`LSUIElement`)
  running `VisorServer`: a WebSocket listener (port 7433) and a REST side
  (7434), both on loopback; Tailscale Serve is put in front on 443 at
  launch (`/api` to REST, `/` to the WebSocket) and is the one road in.
  Serve names the tailnet user behind each request, and the Mac's own
  user's devices are let in on that; a password (required — Settings
  opens on first launch until one is set) is for everyone else and for
  tools on the Mac. The menu shows the Mac's tailnet name, whose it is,
  the password, Copy Connection Code, the connected clients and the
  sessions; Settings shows the connection code as a QR code. How the server is exposed
  is a `ServerExposure`; Tailscale is the one shipped.
- **applications/visor_ios**, **applications/visor_macos** — the client on
  shared host sources: an inset grouped sidebar with a section per
  computer (its connection state in the header, its sessions, its
  settings last), the transcript and composer from AgentUI. A computer
  is added by pasting its connection code or scanning its QR code
  (`visor://connect?code=…`). Each computer is one agent server; what
  the client does with a server — signing in, the live channel, and
  every operation on sessions, folders and files — is the `AgentServer`
  protocol, and `TailscaleAgentServer` (the wire protocol: `hello`, wss
  + https with a bearer) is the one shipped. A fork that hosts agents on
  its own service registers an `AgentServerProvider` with its own
  `AgentServer`, and an `AgentServerProviderUI` with its own sign-in
  view; a new session goes to the one connected server, or to the one
  picked.
- **libraries/visor_protocol** — the wire format (docs/protocol.md) and its
  own small JSON, with no Foundation, so the same code runs wherever the
  client is carried.
- **libraries/visor_services** — what a host gives the client: a socket,
  HTTP and settings. Apple implementations sit beside the protocols.
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
`auth login` — and Tailscale must be running with HTTPS certificates
enabled. docs/DEVELOPMENT.md has the full setup, the architecture, and
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
- **Who can reach it.** The server listens on this Mac's loopback address
  only. The one way in from the network is Tailscale Serve on port 443,
  which is reachable from your tailnet, never the public internet.
  Serve names the Tailscale user behind each request, and your own
  devices are let in on that. Every other device needs the password.
- **The password and the connection code.** The connection code, and the
  QR code that carries it, holds the password in plain base64. Share it
  only with your own devices. The password is kept in the keychain, by
  Visor Server and by each client that saves it; the apps are signed so
  that each build reads its own items without a prompt.
- **On a shared tailnet, use a long password.** The generated password,
  four words from a short list, is easy to type rather than strong, and
  wrong guesses are not rate-limited. Anyone on a tailnet you share with
  others can reach port 443 and try.
- **Revoking access.** Changing the password stops new logins. Clients
  that are already connected keep their session until you quit and
  reopen Visor Server.
- **Agents.** Claude Code, Codex and `openrouter` run as your user with
  your credentials, configured outside Visor. Visor holds no API keys.

Report vulnerabilities privately; see [SECURITY.md](SECURITY.md).

## License

Apache 2.0.
