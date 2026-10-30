# Container hosts (design)

A Visor Server can run a session's agent in a Linux container rather than
on the computer itself. It does not make containers on its own: it asks a
**container host**, a program it is given, which makes them however it
likes. With none, Visor runs sessions on the computer only, and New
Session offers no "In a Container".

From 0.44. Up to 0.43 Visor leased its containers from the OS Server on
its computer through OSSClient; this replaced that.

## Which host

In order, the first that is there:

1. **Settings**: `containerHost` in `settings.json`, a command and the
   arguments before each operation (`["/usr/local/bin/oss",
   "container-host"]`), set with `visor-server containers host
   <command…>` or the menu bar app's Containers.
2. **`visor-container-host` on the PATH.**

Visor ships one: `visor-container-host`, in this repository
(applications/visor_container_host), over Apple's `container` on macOS 26.
It has no leasing and no limits: every container asked for is made. Put it
on the PATH to use it:

```sh
bazel build -c opt //applications/visor_container_host:visor-container-host
cp "$(bazel cquery -c opt --output=files //applications/visor_container_host:visor-container-host)" /usr/local/bin/
```
 Hosts of other kinds are other programs that speak
the same contract: OS Server's, which leases from a server and keeps every
Mac's resources in one place, or a cloud's.

## The contract

A host is a command line. Visor runs it as
`<host> <operation> [arguments]`.

- **JSON:** what an operation is given goes on standard input. What it
  answers is one JSON object on standard output.
- **Success:** exit status 0.
- **Failure:** any other exit status, with
  `{"error": "<words a person can read>", "code"?: "<code>"}` on standard
  output.
  - Codes Visor understands: `busy` (no room now), `noImage`, `notFound`
    (no such container), `unsupported` (this host can't do that), and
    `network` (the container's network is lost; see Network).
- **Version:** every answer may say `"api"`, the contract's version this
  host speaks. This document is version 1.

### `health`

Whether the host can make containers now: `{"ok": true, "name",
"version", "api": 1}`, or `ok: false` with `"error"` saying why (no
container runtime, too old a system). Visor asks at start and when New
Session opens. A host that isn't healthy is as good as none.

### `create`

Makes a container and starts it. Given:

```json
{
  "api": 1,
  "name": "visor-<session id>",
  "image": "ghcr.io/attilathefun/visor-agent:0.44.1",
  "cpus": 6,
  "memoryBytes": 17179869184,
  "mounts": [{"source": "/Users/me/project", "destination": "/Users/me/project", "readOnly": false}],
  "volumes": [{"name": "visor-<session id>-build", "destination": "/var/cache/bazel", "sizeBytes": 137438953472}],
  "environment": {"VISOR_URL": "ws://…"},
  "rosetta": true,
  "labels": {"visor.session": "<session id>", "visor.server": "<server id>"}
}
```

- `mounts` are this computer's folders, seen at `destination`; the
  session's folder is always among them, at its own path.
- A volume is a disk of the container's own, made empty the first time
  and kept by its name until `rm --volumes`, so a container made again
  (see Network) finds it as it was.
- `name` and `labels` are the host's to use or not; a host that keeps
  accounts (OS Server) shows them.

Answers `{"id", "name", "image", "cpus", "memoryBytes"}`, the
container's own `id` being what every other operation takes. It answers
once the container runs and its network works (see Network): a
container that can't resolve a name is not made, it is `code: "network"`.

### `exec`

`<host> exec <id> [--workdir=DIR] [--env-file=FILE] [--interactive] -- <program> [arguments…]`

Runs `program` in the container and **becomes it**:
- its standard input, output and error are the host's own;
- the host's exit status is the program's;
- SIGINT, SIGTERM and SIGHUP sent to the host go to the program.
- When the host process is ended, the program is ended too.

`--env-file` is a file on this computer, `KEY=value` a line, given to the
program. `--interactive` keeps standard input open (the agent's
stream-json); without it, standard input is read to its end.

Visor runs an agent this way, as its agent host's child, so the agent
lives as long as the host process does, across restarts of Visor Server.
It runs short commands to their end the same way: writing the sign-ins
into the container's home, making its SSH key.

### `put`

`<host> put <id> <path> [--mode=600] < bytes`

Writes standard input to `path` in the container, making its folders.
Answers `{"path", "size"}`.

### `rm`

`<host> rm <id> [--volumes]`

Stops and removes the container; with `--volumes`, its volumes too.
Answers `{"removed": "<id>"}`. A container already gone is not an
error.

### `ls`

The host's containers made for Visor (by their labels):
`{"containers": [{"id", "name", "image", "state", "labels"}]}`.
Visor removes those of sessions it no longer has.

### `network`

`<host> network <id>`: whether the container's network works now.
- It must resolve a public name, through the host's DNS (see below).
- It must reach the internet beyond it (visor-container-host: github.com
  over HTTPS).
- Answers `{"ok", "dns", "reach", "detail"}`.

## DNS and the network

A container's network is the host's to keep working, which Visor checks.

- **DNS through the computer.** A container's names resolve through
  this computer's own resolver (the system's DNS), so whatever this
  computer resolves resolves in its containers: a tailnet's names among
  them, and a VPN's. A host may answer its containers' DNS itself, on the
  containers' side of their network, or leave it to its runtime where the
  runtime does this. visor-container-host leaves it to Apple's
  `container`: each container's resolver is its network's gateway, whose
  DNS resolves through the Mac's.
- **Checked when made.** `create` checks the container's network before
  it answers, and fails with `code: "network"` rather than hand over a
  container that can't reach anything.
- **Checked when a turn fails on the network.** When an agent's turn
  fails with a network error (it can't resolve or connect: `EAI_AGAIN`,
  `ENOTFOUND`, `ECONNREFUSED` to its API), Visor asks `network`. If it
  isn't ok, Visor makes the container again: `rm` without `--volumes`,
  `create` with the same spec (the session's folder and volumes as they
  were), its sign-ins written again, and the agent resumed by its id. It
  says so on the session's row. If that fails too, the row says the
  container has no network and why; the agent doesn't sit failing every
  turn.

This is what went wrong on 30 October 2026: a container's resolver and
gateway pointed at a virtual network its Mac no longer had, so nothing
resolved, and the agent failed every turn until it was moved out and in
again by hand.

## A host backed by a server

A host that leases from a server (OS Server; a cloud) is a small program
of its own that speaks this contract and talks to its server:
- `create` leases a container;
- `exec` runs the program through the server's own exec channel (OS
  Server's: its container socket on the server's Mac, or its API's
  `oss-exec` upgrade from another computer);
- `rm` releases the lease;
- `ls` lists its leases with Visor's labels.

Its configuration (the server, its key) is its own, never Visor's. OS
Server's is `oss container-host`, run with OS Server's client settings
and the Visor's key.
