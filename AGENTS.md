# Visor, for agents

Read README.md for the parts, docs/protocol.md for the wire format, and
docs/DEVELOPMENT.md for the setup, the architecture as built, the deploy
loop, probes, gotchas and open items.

## Changes

This repo is public. Every change to `main` goes through a pull request:
`main` is protected, direct pushes are rejected, and the CI check (every
library and the apps' code built, then the tests) must pass before a pull
request can merge. Keep each pull request
to one focused change, and say in it how the change was verified.

## Rules

- No attribution lines in commits.
- No Apple team ids, certificates, provisioning profiles or device UDIDs in
  the repository: the team comes from the builder's own `.bazelrc.user`
  (tools/signing), which is not checked in.
- Dependencies: BCR versions in MODULE.bazel; agent_ui by revision in
  third_party/swift_packages/Package.swift + Package.resolved (re-resolve
  with `swift package resolve`, delete `.build`).
- Every Swift target is built in the Swift 6 language mode with warnings
  as errors: `copts = STRICT_SWIFT` (tools/swift/defs.bzl), which a new
  target takes too. (It holds while `//:swift_ui` is the system SwiftUI;
  a host that builds the client against its own compiles it by its own
  rules.) No `nonisolated(unsafe)`, no `@unchecked Sendable`, no lock
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
  can be carried to other platforms by a build that provides those.
- The server library (libraries/visor_server) has no conditional
  compilation and no platform checks: what differs between systems is a
  protocol in its `ServerPlatform`, implemented per system
  (libraries/visor_server_apple, …_posix, …_linux, …_windows) and given
  by the binary that runs it. A new need of the system is a new member
  there, never an `#if os(…)`.
- Apple-only SwiftUI (swipe actions, context menus, item sheets,
  SecureField) goes through libraries/visor_ui/Sources/Compat.swift.
  Views that touch the @MainActor models are marked @MainActor. AgentUI's
  look is the package's; do not copy views.
- Never send test turns into a real session: start a throwaway session
  over the protocol and end it.
- Verify a server restart by counting agent processes per session id:
  exactly one `claude --resume <id>` (or codex) parented to the menu bar app.
