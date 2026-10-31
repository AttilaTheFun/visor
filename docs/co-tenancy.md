# One Runner, several Visor Servers (design)

Status: planned for 0.45. The decisions below were taken on 31 October 2026.

Today one Mac runs one Visor Server, inside the menu bar app. A session can
run its agent in a Linux container (0.44's container hosts,
docs/container-host.md), but the server stays outside: the container sees
the session's folder and nothing else, so what the server keeps — the
pictures a client attaches, for one — is out of the agent's reach.

This design makes each container a server of its own. One Mac runs any mix:
two sessions on the Mac's own server, five in one container's server, one in
another's, all driven by one menu bar app.

## The parts

- **Visor Runner**: the Mac menu bar app. It controls, and serves nothing
  itself:
  - starts, updates and stops the Mac's Visor Server and each container's
    host, every one a launchd job of its own, so that updating any of them
    — the Runner too — leaves the others' sessions running;
  - makes and removes container servers;
  - moves sessions between servers;
  - holds the credentials and gives each server and host what it needs.
- **Visor Server**: `visor-server`, one Swift binary for macOS and Linux
  (the server library, as now).
  - On the Mac it runs the native sessions: agents as the user, signed in
    as they are on the Mac.
  - In a container it runs that container's sessions. Its agents, their
    transcripts and attachments, and the agents' hosts are all inside the
    container, so an attached picture is where the agent reads it.
- **Container host**: one per container, a Swift binary on the Mac (a launchd
  job of the Runner's).
  - Makes its container and keeps it, through a container runtime: Visor's
    own over Apple's `container`, or OS Server's.
  - Starts the Visor Server in it.
  - Reverse-proxies that server for the clients, on a port of its own. To a
    client, each container server is a computer of its own, with its own
    id, address and code.
  - Proxies the MCP servers for the container's agents (GitHub's, OS
    Server's), adding the credentials the Runner gave it. Nothing secret
    enters the container but the agents' own sign-ins.

## Credentials

- **Native sessions:** Claude, Codex and OpenRouter as they sign in on the
  Mac, each in its own way; OpenRouter's key from the Mac's environment.
- **In containers:**
  - Codex: the Mac's sign-in file, copied in. Codex has no token to pass
    instead. If it gets one, it is passed as Claude's is.
  - Claude: an OAuth token set in the Runner. The Runner gives it to each
    container host, and the host to its server's sessions.
  - OpenRouter: an API key set in the Runner, given the same way.
- **MCP endpoints' secret headers:** the Runner gives them to the Mac's
  server and to each container host. Each adds them as it proxies.
- **Where secrets are kept:** in the keychain for notarized builds (alpha,
  production), and in the data folder for debug builds, chosen by a Bazel
  config.

## Reaching the servers

- The Mac's server is reached as today.
- A container's server is reached at its container host's port on the Mac,
  on the network paths the Runner sets for it (the LAN, a VPN, SSH, a
  reverse proxy of your own).
- The Runner shows each server's connection code.
- Clients already keep several computers, so a Mac with three servers is
  three computers in the sidebar.

## Moving sessions

- Between any two servers: the Mac's and a container's, or two containers'.
- Visor's Migrate… already moves a session between servers. The client
  carries the conversation's files and the projects across, and the other
  server resumes the session; the original is left until the new one works.
- The Runner adds a move of its own for servers that see the same folder
  (a container mounts the Mac's folders at their own paths). It carries the
  conversation and leaves the project where it is.

## Names (to settle)

0.44 calls the program that makes, runs in and removes containers a
"container host" (docs/container-host.md, `visor-container-host`,
`oss container-host`). Here "container host" means the process that keeps a
container and proxies for it, as the decision put it.

Proposed: call 0.44's layer the **container runtime** (`visor-container-runtime`,
`oss container-runtime`) before 0.44 is released, and keep "container host"
for the per-container process, which uses a runtime to make its container.

## Phases

Container servers come first: they are new code beside today's, and they
are what fixes the attachments and puts several sessions in one container.
Migrate… already moves a session between any two servers, so a container
server is usable as soon as it can be made.

1. **One container server, end to end.**
   - The container host binary, and the Linux `visor-server` in Visor's
     agent image.
   - The host makes the container, starts the server, proxies it and its
     MCP servers, and gives it its credentials.
   - Started and stopped from the menu bar app as a launchd job of its own.
2. **The Runner's side.**
   - Container servers made and removed from the menu bar app.
   - The Claude token and OpenRouter key set there.
   - A code for each server.
3. **The Mac's server apart from the Runner.**
   - `visor-server` runs as a launchd job that the menu bar app installs,
     updates and stops.
   - It keeps the menu bar app's data folder, so sessions, pairings and
     codes carry over.
   - Secrets: the keychain or the data folder, by build.
   - The Runner's settings and menu read and change the server through its
     local API.
4. **Moving sessions.**
   - Moving between servers from the Runner.
   - Today's agent-in-a-container sessions (0.44) moved onto container
     servers; then that way of running is retired.

## Sessions running today

- Sessions in OS Server containers (0.43) run on the Mac from 0.44 on, with
  a notice. Move into a Container then puts them in a 0.44 container.
- Once phase 1 is out, such a session moves to a container server with
  Migrate…. The old one is kept until the new one has answered.
- A server is updated only when its sessions aren't mid-turn.
