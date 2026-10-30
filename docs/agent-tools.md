# Agent tools (design)

> Superseded (0.44): agents reach GitHub and OS Server through MCP servers Visor Server proxies (docs/protocol.md, Proxied MCP servers), and containers come from a container host (docs/container-host.md). Visor no longer has `visor machine` or OSSClient. Kept for the reasoning.

What Visor puts in a session's hands, and how it keeps them narrow.
Status: proposed. Nothing here is built beyond what "Today" says.

## The rule

**Credentials never enter a session.** Every tool Visor injects is a thin
client of the session's Visor server. The server holds the credentials,
checks each call against that tool's policy, makes the call itself, and
writes it on the session's row, so the person following the session sees
what its agent did with each tool.

A wrapper around a token in the environment would control nothing: the
agent can `curl` with the token and go around the wrapper. So a tool's
reach is what the server does for it, never what a token lets it do.

The same tools serve sessions on the computer and in containers. Only
how they reach the server differs: the Unix socket or loopback on the
computer, the network from a container (`VISOR_URL`).

Repository rules back the server up: only the owner pushes to main or
makes tags, whatever a tool gets wrong.

## Today

- `visor` is a Node script on every agent's path: on the computer, and
  read-only at `/opt/visor` in containers. Its `visor machine` leases OS
  Server machines through the server, in the session's name, with oss's
  token, which the session never sees. This is the pattern for every
  tool below.
- Visor's MCP server (`visor_mcp.js`) gives agents `list_sessions`,
  `send_message`, `read_messages`, `message_status` and `approve`.
  Its `initialize` instructions tell the agent where it runs.
- A session authenticates to its server with its agent token
  (`VISOR_TOKEN`). The token is the session's own, and is good only
  for what the server lets a session do.
- Not yet narrow:
  - a session on the computer has the computer's own sign-ins (git,
    `gh`, `agent-token`, the shell's App Store Connect key);
  - a container's `.netrc` holds oss's read token, read-only, for its
    Bazel cache and files.

## Pieces

### Injection

The server writes its tools into one folder: `visor`, `gh`, `git-credential-visor`,
`oss` and `apple`. It puts that folder first on the path of every agent
it starts: on the computer, and at `/opt/visor` in a container. Each tool
is a script the server writes from its own build, so a server's tools
always match it. A tool takes the session's identity from its
environment (`VISOR_SESSION`, `VISOR_TOKEN`, `VISOR_URL`), and nothing
else of value.

### Credentials, held by the server

| Credential | Used for | Kept |
| --- | --- | --- |
| Each agent's GitHub App key (Claude's, Codex's) | installation tokens, minted per operation | the server's data folder, mode 600 |
| OS Servers' tokens | leasing, exec, storage | as now (`POST /api/oss`) |
| The App Store Connect API key | bundle ids, capabilities, development profiles | the server's data folder |
| Later: Linear's key, a project's run-time secrets | their tools | the same |

The server's own settings take each one, and none is ever written into
a session, a container's files or a log.

### Policy

Each tool's operations are a fixed list the server implements, each
allowed, refused or asked for. What a session may touch comes from the
session itself: its folder's repository (from its git remote) and the
branches it made. A call outside that is refused with a reason the agent
can act on, never failed silently.

### Audit

Every tool call is recorded on the session: the tool, the operation, its
target (a repository and ref, a lease, a bundle id), allowed or refused,
and when. The client shows the list with the session. It's kept with the
session's record, as its leases are.

### Requests: what a tool refuses, the person can allow

`visor request <action> [--reason …]`: for what no tool allows, such as
merging, tagging, or a step only the computer can take (restarting a
service). The person sees the request on their phone and allows or
denies it, as they answer an approval today. An allowed request runs as
one of a fixed list of server-implemented actions, never as arbitrary
shell. That keeps work that needs the computer possible as sessions on
the computer become rare, without giving a container the computer.

## The tools

### visor

- `visor message list | send | read | status`: the MCP tools, from
  the shell too.
- `visor ask <question>`: a question to the person, answered on their
  phone. `visor notify <text>`: a notification, no answer.
- `visor request <action>`: as above.
- `visor machine …`: as today.

### git and gh

- **git:** `git-credential-visor` answers git's credential requests with
  an installation token the server mints for that one repository, contents
  only, for an hour at most, as the session's agent's app. Pushes and
  pulls work as git does. The token is the one place a credential reaches
  a session, so it's as narrow as GitHub allows, and the repository's
  rules stop pushes to main, tags and force-pushes. Later, the server
  can relay git's smart HTTP itself and check each ref before GitHub
  sees it; then no token reaches the session at all.
- **gh:** a subset, the server making the calls:
  - pull requests: create, view, edit, comment, review comments;
  - CI: runs, checks and their logs;
  - releases: none. Merging, settings and secrets: none, or
    `visor request`.
  Pull requests are the session's agent's app's, as `agent-token`'s are
  today, which moves into Visor.

### oss

The OS Server client, scoped to the session, on plain OS Server API. Small
calls (lease, renew, release, list) the server forwards as it does every
OS Server call, holding oss's token and making the session the holder.
Bytes don't go through the server: for a stream (exec, xctest, an upload,
a stored object, an install), the server asks OS Server for a grant
(`/v1/grants`: one verb on one lease or object, signed, minutes long) and
hands the tool its URL, and the tool streams to OS Server directly, a
chunked body in and chunked lines out. A grant is all the tool holds.

- `oss machine …`: lease, renew, release, exec (stdin streamed in, the
  output streamed back, the exit status), upload, download, screenshot,
  simctl, adb.
- `oss machine xctest <ios lease> <bundle>`: tests on a leased simulator,
  their output streamed back.
- `oss storage put <file> [--ttl …]`, `get`, `ls`, `renew`, `rm`: the
  session's own file store (`/v1/storage/…`), objects kept while a lease
  on them is renewed. `oss machine install <lease> <object>`: what an
  agent built, installed for testing without publishing it. Only CI
  publishes.

OS Server's side (storage, xctest, install from storage, grants, lease
kinds) is OS Server's design, `/v1/storage/…`, `/v1/machines/{id}/…` and
`/v1/grants`. This side forwards the small calls and asks for the grants.

### apple

Through the server's App Store Connect key, narrowly:

- register a bundle id and its capabilities;
- make or refresh a development profile for it (the team's development
  certificate, the registered devices);
- a `.Beta` bundle id beside each app and extension, for the beta and
  production split.

Signing with distribution identities, notarizing and uploading stay in
CI, never a tool.

### Later

- **linear:** issues, with the server's key.
- **Project secrets:** a project's run-time keys, relayed by the server
  where they can be (an API call made for the session), handed over only
  where they can't, and recorded.

## A container's network

A container reaches only what an allowlist names:

- the session's Visor server;
- OS Server (its cache and files, read-only, on its own address);
- GitHub;
- the Bazel and Swift package registries;
- Apple's and swift.org's downloads;
- the agent's own model API.

With nothing else reachable, the tools are the only way to act. OS
Server enforces the allowlist, as a lease option, since it runs the
container; Visor gives the list for each session:

- the container is on an internal network, host-only, with no route out;
- a proxy on the host's side of it (HTTP, and CONNECT for HTTPS) knows
  the lease by its address, so the container holds nothing for it, and
  lets through only that lease's list;
- the container's `HTTP_PROXY`/`HTTPS_PROXY` name it. OS Server's cache
  and files and the Visor server are reached at the host's address;
- what ignores a proxy, or isn't HTTP (git over SSH, raw sockets), has no
  way out, so git goes over HTTPS with `git-credential-visor`.

The image keeps what builds need: Bazel, git, Swift, clang.

## Sessions on the computer

A session on the computer runs as the person who owns it. It can't be
held to the tools the way a container is: it can read what they can. So
the narrow road is a container, and sessions on the computer are for
what only the computer can do, by `visor request` where possible.

## Order

1. Injection and audit: one tools folder on every agent's path; every
   call recorded on the session.
2. `gh` and `git-credential-visor`, with the agent apps' keys in the
   server. `agent-token` retires.
3. `visor ask`, `notify` and `request`.
4. `oss`: small calls forwarded, streams by grant; storage and xctest as
   OS Server ships them.
5. `apple`.
6. The container network allowlist, with OS Server.
7. Linear and project secrets.

## Open questions

- Should git eventually go through the server's own relay, so that no
  token reaches a session, or are short-lived, single-repository tokens
  plus rulesets enough?
- Which actions `visor request` offers first.
- Whether a refusal the agent repeats should go to the person on its
  own, or only when the agent asks.
