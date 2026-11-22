# Visor, sandboxed (the Nimbus model): design note (22 Nov 2026)

**Logan (21:0xZ, verbatim):** "Visor is a sandboxed app with the menu bar and client that can out of the box run agents in containers. It will only allow you to do this if you point it to volumes for the Sessions Sources and Visor which you can either create by hand with Disk Utility or install the non-sandboxed Visor Disk Utility to do it. Additionally Visor Agent Utility is an optional application for running native sessions which handles that part."

## 1. The apps

| App | Bundle id | Sandboxed | Role |
|---|---|---|---|
| **Visor** | com.LoganShire.Visor | **yes** | Menu bar, client window, and the **server** with **container sessions**. A client only until the three volumes are picked. |
| **Visor Disk Utility** | com.LoganShire.Visor.DiskUtility | no (optional) | Creates the three case-sensitive volumes, with owner and Spotlight; Uninstall's privileged parts. As 0.65. |
| **Visor Agent Utility** | com.LoganShire.Visor.AgentUtility | no (optional, new) | Runs **native** sessions: agent hosts with the user's access, and the native MCP on 7439 including gh. |
| Visor Client | com.LoganShire.VisorClient.macOS | yes | **Retires**: Visor without volumes is the same thing. |

**Entitlements:**
- **Visor:**
  - app-sandbox, network.client, network.server (7433, LAN, the SSH tunnel);
  - **virtualization** (Containerization, as Nimbus);
  - device.audio-input;
  - files.user-selected.read-write and **files.bookmarks.app-scope** (the volumes);
  - keychain-access-groups `<team>.com.LoganShire.Visor` (team-prefixed: the keychain group is separate from app groups);
  - **application-groups** `group.com.LoganShire.Visor` (the Visor family: presence, messaging, sockets) and `group.com.LoganShire.Applications` (the installed-version advert, UpdateKit);
  - aps-environment.
- **Agent Utility:** not sandboxed, with the same keychain group and both app groups.
- **Disk Utility:** as 0.65, plus both app groups, so Uninstall can find the group container.
- **The updater:** an **embedded, unsandboxed XPC service** inside Visor.app, Sparkle-installer style, because a sandboxed app can't replace itself in /Applications. Developer ID allows it. It also takes over the 2-minute "stayed up" watcher.

## 2. Where things live
- **Volumes:** the user picks Sessions, Sources and Visor once, with NSOpenPanel. Visor keeps **security-scoped bookmarks** (app scope) and starts accessing them at launch. Without all three: client only.
- **The server runs in Visor.app's own process.** It starts at login through `SMAppService.mainApp` (a sandboxed app may register itself), and stays as a menu bar app when its window is closed. There's no separate server agent any more.
- **Server data:** `/Volumes/Visor/Data`, `Caches`, `Logs` and `Containers` (as 0.65), reached through the bookmark. Client-only data lives in the app's sandbox container.
- **Sockets:** a sandboxed app can't reach ~/.visor or arbitrary paths, so sockets live in the **group container** under a short folder, `~/Library/Group Containers/group.com.LoganShire.Visor/r/`, about 70 bytes. Host sockets get short names (`h-<8 hex>.sock`), so every path stays under the 104-byte limit:
  - `server.sock`: the app, local tools, and the SSH fronts' `nc -U`;
  - the relay and driver sockets for containers;
  - the agent hosts' sockets.
- **SSH from the phone:** macOS sshd, then `nc -U` the group-container socket. The connection code carries the path. `~/.visor` goes away.

## 3. The split of work
**Visor.app (sandboxed) owns:**
- session records (the JSONL → SQLite index), mail, sync, push and clients (REST, WebSocket, gRPC later);
- the **container engine** (Containerization: VM, mounts of the bookmarked Sessions and Sources, the relay);
- **agent-proxy** (egress gate, GitHub gate, relay, Visor's MCP for containers);
- Super Compact and the periodic models check, run **in the container**;
- JWT minting;
- the menu, Settings, and the volume picker.

**Visor Agent Utility (unsandboxed, optional) owns native sessions:**
- **spawning** agent hosts (`visor-agent-host`, plus claude or codex with the user's PATH, folders and TCC);
- the **native MCP on 7439**, including **gh** (#499's in-process gh_mcp, which execs `agent-token` and `/usr/bin/git`; that's simplest outside the sandbox);
- oss and shireworks pass-through;
- native sessions' egress, which isn't needed.

**The link:** the server already talks to agent hosts over Unix sockets (AgentChildren/HostedChild). With Agent Utility, those sockets sit in the group container, and the server asks the utility to spawn a host instead of `posix_spawn`ing it.
- The spawn request carries the session id, folder, harness, JWT and environment, over a small socket API in the group container. Presence: each app writes a heartbeat file in the group container, so the others can tell it's installed and running.
- Everything after the spawn is today's host protocol.
- Without Agent Utility, native sessions aren't offered, and Migrate… lists only containers and other Macs.

## 4. Updates
- **Visor.app** updates through its embedded unsandboxed installer XPC service: download, verify, replace, relaunch, and the watched rollback with the lock, the 409 and the per-watch backup from 0.65.
- **Accessories:** each updates itself, through UpdateKit as today, or Visor's updater offers them.
- **The quarantine lesson (Shireworks 0.20.1, #561):** a sandboxed app that installs its own update from inside the sandbox puts `com.apple.quarantine` on the new copy, which then won't launch (translocation, launchd EPERM, -10810). So the unsandboxed installer XPC must copy with `ditto --noqtn`, check the signature and team, then swap. **The same CI check as #561** goes into 0.67: self-update through the real path in a VM, then launch the new copy. Any sandboxed Visor-family app updates only through an unsandboxed installer, never in-sandbox.

## 5. TCC and keychain
- **TCC:**
  - native agents' grants (folders, etc.) move to **Agent Utility's** identity, so there's one re-prompt per grant;
  - container sessions need none;
  - microphone and Local Network stay with Visor.app;
  - Background Items shows Visor (the main app) and Agent Utility when it's installed.
- **Keychain:** one group, `<team>.com.LoganShire.Visor`, shared by all three apps. **#502's fix is a prerequisite**, since it makes the group keep items. The client's **ungrouped login-keychain items** (server passwords, SSH key), which a sandboxed app can't read, move into the group in a **0.66 prep step** run by the still-unsandboxed 0.66 app.

## 6. Migration from 0.65
1. **0.66 prep (unsandboxed):**
   - move the client keychain items into the group;
   - move the sockets and host sockets to the group container (with a ~/.visor link for one release);
   - keep data on the Visor volume, where 0.65 put it.
2. **0.67 (sandboxed) first launch:**
   - container-migration of the app's defaults and small client files into the sandbox container;
   - the **volume picker**: Visor asks for Sessions, Sources and Visor once, with each name pre-selected;
   - the server starts in-app and unregisters 0.65/0.66's SMAppService server agent (another Login Items change, with the calm wait from #501);
   - native sessions: if Agent Utility is installed, their hosts are re-spawned by it (claude resumes each conversation); if not, Visor offers it, or moving the session into the container.
3. **Visor Client:** its users install Visor instead; no data to move.

## 7. PR plan (agent hours, plus review and lease runs)
1. **This note, agreed by Logan.**
2. **0.66 prep (about 4 h):** the group container and short socket paths; client keychain items into the group; the spawner seam in AgentChildren (posix_spawn now, a remote spawner later).
3. **Visor Agent Utility (about 6–8 h):** the new app and its SMAppService agent; the spawn API; 7439 with gh moved there; tests; a lease run.
4. **Visor.app sandboxed (about 8–10 h):**
   - entitlements;
   - the volume picker and bookmarks;
   - the in-app server with the mainApp login item;
   - **Containerization inside the sandbox**, proved in a lease (virtiofs of bookmarked volumes, sockets in the group container);
   - the client audit (reused from Visor Client);
   - the updater XPC service.
5. **Migration, Disk Utility and retiring Visor Client (about 4–6 h):** Uninstall covers the group container and Agent Utility, plus a signed-alpha lease proof of 0.65 → 0.67.

**Total about 25–30 h, over 2–3 days with reviews: 0.66 (prep) and 0.67 (the switch).**

## 8. Risks
- **Containerization in the sandbox:** Nimbus does it, so it's feasible. The specifics to prove early in a lease are virtiofs sharing of bookmarked volumes and vsock/Unix sockets in the group container.
- **Native tools from a sandbox:** that's why gh, agent-token, git, claude and codex for native sessions all live in Agent Utility. In the sandbox, `claude -p` runs only inside the container.
- **Phone SSH path change:** the connection code must carry the group-container socket path. 0.64-style clients need the ~/.visor link until they update.
- **Two re-prompts:** Login Items, and TCC for native agents.

## 9. Order
1. 0.65.2 (in flight).
2. The Mini volume window.
3. The container check on the Mini.
4. **The session moves into containers**, once Shireworks is a pure client and Nimbus carries the workloads. **Do these before 0.67:** container sessions carry over to the sandboxed Visor unchanged (same volumes, same container), while native sessions would otherwise have to be moved to Agent Utility first. Fewer native sessions means a simpler migration.
5. The design note's PRs (0.66 prep, Agent Utility, sandboxed Visor) can proceed **in parallel** with waiting for Shireworks and Nimbus.
6. Visor 0.67 ships.

## Logan's decisions (22 Nov, 21:1xZ)
- **The design is OK'd:** "Sounds good".
- **App groups:** `group.com.LoganShire.Visor` for the Visor family, `group.com.LoganShire.Nimbus` for the Nimbus family, and `group.com.LoganShire.Applications` for advertising installed versions. All three Visor apps get Visor and Applications. Keychain access stays team-prefixed.
- Go ahead with the PRs, in parallel with the current queue.
