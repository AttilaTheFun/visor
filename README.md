# Visor

Remote agent sessions: a Mac menu bar app runs Claude Code, Codex and the
openrouter CLI as subprocesses on the host and exposes them over
Tailscale; a SwiftUI client for iPhone, iPad and Mac adds a Mac from its
connection code, starts sessions, chats with them and watches their
progress.

## Parts

- **applications/visor_menubar** — the host. A menu bar app (`LSUIElement`)
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
  (`visor://connect?code=…`). How a
  client reaches a computer is a `HostTransport` chosen by the computer's
  `backend`; `TailscaleTransport` (wss + https, a token from `hello` or
  the password) is the one shipped. A fork adds its own transport for
  its own backend and registers it with `Backends.register`.
- **libraries/visor_protocol** — the wire format (docs/protocol.md) and its
  own small JSON, with no Foundation, so the same code runs wherever the
  client is carried.
- **libraries/visor_services** — what a host gives the client: a socket,
  HTTP and settings. Apple implementations sit beside the protocols.
- **libraries/visor_client** — computers, connections, transcripts, the
  session cache, the transports.
- **libraries/visor_ui** — the views, on AgentUI and NavigationUI.
- **libraries/visor_server** — the server: sessions, agent processes
  (Claude, Codex, the openrouter CLI from github.com/AttilaTheFun/
  open_router_cli, which speaks Claude's stream-json protocol), the
  archive, the HTTP and WebSocket listeners. Agents are configured
  outside Visor (`claude`, `codex login`, `openrouter auth login`).

## Building

Bazel with rules_swift, rules_apple and rules_xcodeproj; AgentUI comes in
through rules_swift_package_manager from third_party/swift_packages.

    bazel build //applications/visor_menubar //applications/visor_macos
    bazel build --ios_multi_cpus=sim_arm64 //applications/visor_ios
    bazel test //tests/...
    bazel run //:xcodeproj     # generates Visor.xcodeproj for Xcode (not committed)

Needs Xcode 27 and Bazelisk. The bundle ids and the Apple team id are
constants at the top of each app's BUILD.bazel: set your own before
signing for a device. The agents are configured on their own — `claude`,
`codex login`, and [`openrouter`](https://github.com/AttilaTheFun/open_router_cli)
`auth login` — and Tailscale must be running with HTTPS certificates
enabled. docs/DEVELOPMENT.md has the full setup, the architecture, and
the deploy loop.

## Contributing

Pull requests into `main`. Read AGENTS.md for the rules the code keeps.

`//:swift_ui` is a label flag for where `import SwiftUI` comes from. On
Apple it points at nothing (the system framework); a build that carries
the client to another platform sets it to its own SwiftUI.

## License

Apache 2.0.
