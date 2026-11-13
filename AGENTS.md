# Visor, for agents

Read README.md for the parts, docs/protocol.md for the wire format, and
docs/DEVELOPMENT.md for the setup, the architecture as built, the deploy
loop, probes, gotchas and open items. docs/isomer.md is blue Visor's (the
client on Isomer: the web, Android, the iPhone as WebAssembly): its apps,
its rules, and its local CI, end-to-end and snapshot harnesses
(tools/isomer).

## Changes

This repo is public. Every change to `main` goes through a pull request:
`main` is protected, direct pushes are rejected, and CI's one check,
`container` (the rules, then every app, library and server built on
Linux), must pass on main's head before a pull request can merge. No test
runs on its own: the tests and the proof run by hand (`run: verify`), and
every release proposal runs them (docs/DEVELOPMENT.md, CI). Run the tests
that touch your change before you push. Keep each pull request to one focused change, and say in it how the
change was verified.

## Rules

CI's rules step (tools/check_rules.py, in the `container` job) checks the ones that must hold:
signing material, the strict Swift copts, `nonisolated(unsafe)` and
`@unchecked Sendable`, Combine, networking in visor_client and visor_ui,
platform checks in the server library, and attribution lines in a pull
request's commits. A rule that matters and can be checked goes there too.

- No attribution lines in commits.
- No Apple team ids, certificates, provisioning profiles or device UDIDs in
  the repository: the team comes from the builder's own `.bazelrc.user`
  (tools/signing), which is not checked in.
- Dependencies: BCR versions in MODULE.bazel; agent_ui and swift_sql by
  version in third_party/swift_packages/Package.swift + Package.resolved
  (re-resolve with `swift package resolve`, delete `.build`), swift_sql in
  the root Package.swift too (the SwiftPM server). Versions are
  `MAJOR.MINOR.BUILD` (from 0.38; no point releases): the plists and
  MODULE.bazel say `0.58.0`, CI stamps each build's own (`0.58.N`, build
  number 1; Android's versionCode MAJOR×1,000,000 + MINOR×1,000 + BUILD),
  and a release is tagged `v0.58.N`, the build it releases.
  A branch in development may pin a revision of something not yet
  released; a release may not: CI's `pins` job (tools/released_pins.sh)
  fails on main's commits until every pin is a released version, and
  Reviews holds the release until it passes.
- Every Swift target is built in the Swift 6 language mode with warnings
  as errors: `copts = STRICT_SWIFT` (tools/swift/defs.bzl), which a new
  target takes too. (It holds for Apple builds against Apple's SwiftUI;
  a build against Isomer's — the web, Android, Linux, Windows, or a
  compiled feature — compiles it by Isomer's rules.) No `nonisolated(unsafe)`, no `@unchecked Sendable`, no lock
  where an actor or the main actor is what is meant; shared state that
  truly is shared across threads sits in a `Mutex`. A callback the system
  makes on a queue of its own is built outside the main actor (a
  `nonisolated` function), or it traps when called.
- One public or internal type per file, named after it; only nested types
  (`Foo.Bar`) and `private`/`fileprivate` helpers share a file. What a
  large type does is split by topic into `Type+Topic.swift` extensions,
  and a long `switch` over routes or commands dispatches to one small
  method per case.
- Never use Combine; async/await only. The protocol encodes over its own
  `JSONValue` and the client reaches the host only through
  libraries/visor_services and an `AgentServer` — no Foundation
  networking or UserDefaults in visor_client or visor_ui, so the same code
  builds on Isomer (the web, Android) as it does on Apple's platforms.
- Visor depends on Isomer (from 0.37): isomer, and the rules_swift fork it
  needs, come from the project's Bazel registry by version. `//:swift_ui`
  and `//:foundation` default to isomer's labels, which are Apple's own on
  Apple's platforms and Isomer's elsewhere. A file that uses Foundation
  imports it, even where another module has loaded it.
- The server library (libraries/visor_server) has no conditional
  compilation and no platform checks: what differs between systems is a
  protocol in its `ServerPlatform`, implemented per system
  (libraries/visor_server_apple, …_posix, …_linux, …_windows) and given
  by the binary that runs it. A new need of the system is a new member
  there, never an `#if os(…)`. The same holds for libraries/visor_system,
  below it (the tools, processes, folders and this computer the server and
  the agents' code share): its `SystemPlatform` is the part of
  `ServerPlatform` it needs, installed whenever `ServerPlatform.current`
  is set. And for libraries/visor_agent, between the two (the agents'
  processes, harnesses, transcripts and catalogs), which takes what it needs of the system from that
  `SystemPlatform` too.
- Apple-only SwiftUI (swipe actions, context menus, item sheets,
  SecureField) goes through libraries/visor_ui/Sources/Compat.swift.
  Views that touch the @MainActor models are marked @MainActor. AgentUI's
  look is the package's; do not copy views.
- Never send test turns into a real session: start a throwaway session
  over the protocol and end it.
- Verify a server restart by counting agent processes per session id:
  exactly one `claude --resume <id>` (or codex) per session id, parented to
  its `visor-agent-host` (which is parented to the menu bar app, or to
  launchd once the server that started it has restarted).
