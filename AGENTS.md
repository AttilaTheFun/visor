# Visor, for agents

Read README.md for the parts, docs/protocol.md for the wire format, and
docs/DEVELOPMENT.md for the setup, the architecture as built, the deploy
loop, probes, gotchas and open items.

## Rules

- Changes go through pull requests into `main`, one focused change each;
  no attribution lines in commits.
- Dependencies: BCR versions in MODULE.bazel; agent_ui by revision in
  third_party/swift_packages/Package.swift + Package.resolved (re-resolve
  with `swift package resolve`, delete `.build`).
- Never use Combine; async/await only. The protocol encodes over its own
  `JSONValue` and the client reaches the host only through
  libraries/visor_services and a `HostTransport` — no Foundation
  networking or UserDefaults in visor_client or visor_ui, so the same code
  can be carried to other platforms by a build that provides those.
- Apple-only SwiftUI (swipe actions, context menus, item sheets,
  SecureField) goes through libraries/visor_ui/Sources/Compat.swift.
  Views that touch the @MainActor models are marked @MainActor. AgentUI's
  look is the package's; do not copy views.
- Never send test turns into a real session: start a throwaway session
  over the protocol and end it.
- Verify a server restart by counting agent processes per session id:
  exactly one `claude --resume <id>` (or codex) parented to the menu bar app.
