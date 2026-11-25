# Visor on the Mac: Visor.app and its server (design, 24 Nov 2026)

**Logan (24 Nov 2026, verbatim):** "It's Visor.app on iOS and macOS. The mac version also bundles the notarized visor server background process which can run sessions natively or in containers it manages whose files are exclusively on the Visor, Sessions and Sources volumes. The Visor Disk Utility app should be stripped of all the migration code and serves purely to create / validate those volumes are created and configured correctly." And, the same day: Visor Agent Utility is dropped from the plan.

This replaces the design of 22 Nov 2026 (a sandboxed Visor.app with its server in its own process, and an unsandboxed Visor Agent Utility for native sessions). What changed, and why, is in section 4.

## 1. The apps

| App | Bundle id | Role |
|---|---|---|
| **Visor** | com.LoganShire.Visor | Visor.app, on iOS and macOS. On the Mac: the menu bar, the window, and **Visor's server**, a background process bundled in the app and notarized with it. |
| **Visor Disk Utility** | com.LoganShire.Visor.DiskUtility | Creates the Sessions, Sources and Visor volumes and checks they're as they should be (mounted where Visor looks, case-sensitive, the person's, Visor's left out of Time Machine and Spotlight). Nothing else: no conversion, migration or uninstall. |

There's no separate client app for the Mac: Visor.app is the client on both systems.

## 2. The server

- **What it is:** today's server agent. Visor.app's own executable, run with `--server` by the user's launchd, registered with SMAppService from the bundle (applications/visor_mac, MacServerAgent; docs/DEVELOPMENT.md, "The server as a background agent"). It's signed and notarized as part of Visor.app, so an update of the app is an update of the server.
- **What it runs:** every session, natively and in containers:
  - **native sessions:** agent hosts it starts itself (AgentChildren and HostedChild, through the AgentHostSpawner seam, whose one spawner is the server's own, ProcessAgentHostSpawner), with the user's access, PATH, folders and TCC grants;
  - **container sessions:** in the Sessions container it manages (Containerization, docs/containers.md), whose files are only on the Visor, Sessions and Sources volumes;
  - Visor's MCP on 7439, gh included, and agent-proxy (egress gate, GitHub gate, relay), as now.
- **Its data:** on the Visor volume (`Data`, `Caches`, `Logs`, `Containers`), once it's there (VisorFolders). The volumes are found through volumes.json, which Visor Disk Utility writes, and their mount points.
- **The app** is the server's client, at its socket file, whichever process runs the server.

## 3. What still holds from 22 Nov

- **App groups:** `group.com.LoganShire.Visor` (the Visor family's: presence, messaging, the sockets) and `group.com.LoganShire.Shireworks` (shared with Shireworks: UpdateKit's installed versions, the shared sign-in's lock; Logan, 23 Nov 2026, in place of `group.com.LoganShire.Applications`). The keychain group stays team-prefixed, `<team>.com.LoganShire.Visor`.
- **Sockets in the group's container** (0.66, behind a setting until every profile grants the group: MacPlaces' `groupSockets`): `~/Library/Group Containers/group.com.LoganShire.Visor/r/`, with `server.sock`, the Sessions container's `relay.sock` and `driver.sock`, and the agent hosts' `h-<8 hex>.sock`, each path under the 104 bytes a socket's may have (VisorPlaces). The SSH addresses carry the path (`?socket=`), and a client tries the volume's, the group's and `~/.visor`'s in turn without one.
- **The keychain:** #502's fix, and #503's copy of the client's login-keychain items into the group (written and read back; reads prefer the group's, writes go to the group alone). The login-keychain copies are kept for a rollback to a build that reads them alone; they go stale after, and stay until a person removes them.
- **The update helper:** Visor.app's updates are installed and watched outside the app's window: download, verify, replace, relaunch, the "stayed up" watch with its rollback, its lock, the 409 while a watch runs, and the per-watch backup (today the server agent's watcher, ServerAgentWatch, and `Visor server-agent register` after an update). **The quarantine lesson** (Shireworks 0.20.1, #561) holds for anything that installs an update: copy with `ditto --noqtn`, check the signature and team, then swap; and CI checks a self-update through the real path in a VM, then launches the new copy.
- **TCC:** the grants native agents need stay with Visor.app's identity (its server agent's), with no re-prompt; Background Items shows Visor.

## 4. What changed, and why

- **Visor Agent Utility is dropped.** Its design (an optional unsandboxed app spawning native agent hosts over a socket in the group's container, the native MCP on 7439 and gh moved into it, native agents' TCC grants moved to its identity, native sessions re-spawned by it on migration) existed only because a sandboxed Visor.app couldn't run native agents. Visor.app's server runs them itself, as it does today: one app to install, sign, notarize and update, and no second identity for the grants.
- **The server stays a background process, not the app's own process.** The 22 Nov design moved it into a sandboxed Visor.app (`SMAppService.mainApp`, no separate server agent). It now stays the bundled, notarized server agent, which runs native and container sessions alike.
- **Not planned now** (they were for the sandboxed app): the volume picker and its security-scoped bookmarks (the server finds the volumes through volumes.json), Containerization inside the App Sandbox, the in-app server, and the embedded installer XPC service as a sandbox's way out (the update helper above does that work).
- **The separate Mac client app is retired** (#525): Visor.app is the client.
- **Visor Disk Utility only creates and checks the volumes** (#524): no conversion of a case-insensitive volume, no migration, no Uninstall… With everything of Visor's on its volumes, a person removes it by deleting the apps and the volumes in Apple's Disk Utility.

## 5. Open

- **Sandboxing.** Whether any part of Visor.app is sandboxed later. Its server, the app's own executable, runs native agents with the user's access, which a sandbox forbids, so a sandboxed app would need the server as a separate helper.
- **What's still outside the volumes:** the server agent's registration, the keychain items, the apps' defaults, and the `authorized_keys` lines Visor adds (Forget This Device takes a device's out). Deleting the volumes doesn't remove them yet.
- **Group sockets on by default**, once every Developer ID profile grants the group; then the links in `~/.visor` and the volume's `run/` go.
