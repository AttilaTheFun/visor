# agent-proxy (Visor's, from 0.62)

Visor's agent-proxy is Shireworks' agent-proxy, moved into Visor (Logan, 19
Nov 2026: "agent-proxy is Visor's now"). It came from shireworks **v0.15.1**
(`Sources/AgentProxy`, `CAgentProxyPOSIX`, `AgentProxyHost`, `RelayClient`,
`CRelayClientPOSIX`, `RelayClientMain`, and their tests; relay-client is
now visor-server run by that name). It is
`libraries/visor_agent_proxy`, its tests are `tests/visor_agent_proxy_tests`
(in `//tests:linux`), and it is **off by default**: nothing starts unless
settings.json has `agentProxy`.

## What it serves

- **The native sessions' MCP pass-through** on `127.0.0.1:7439`
  (NativeMCPProxy). Each upstream is at `/mcp/<name>`. A call that shows the
  sessions' token in `X-Visor-Proxy` goes on to its upstream with the
  upstream's plain headers and its secret headers added. A withheld tool is
  left out of `tools/list`, and a call to it is refused. A session's
  `mcpEndpoints` point here (`http://127.0.0.1:7439/mcp/gh`, with the
  `X-Visor-Proxy` header a secret of the endpoint's). Upstreams are plain
  `http://` addresses.
- **The Sessions container's agents' MCP** (from 0.72.1), at the same
  pass-through, Nimbus's alone: through the relay, by agent-proxy's own
  dial-in `mcp.agent.internal:80`, each call showing its agent's own token
  in `X-Visor-Proxy`, never the sessions' token. It is below, under The
  container's agents and the pass-through.
- **gh_mcp, in-process** (from 0.66) at the pass-through's `/mcp/gh`, when
  `agentProxy.gh` is set and no upstream is named `gh`. It is below, under
  gh_mcp in agent-proxy.
- **The relay listener** on a loopback port (`relayPort`): the containers'
  way out. Each stream starts with the relay's PROXY v2 header, which carries
  the relay's token (TLV 0xE2). After the header comes one of these:
  - a CONNECT or a plain `http://` request: egress to the internet, or to
    this computer's networks where `egressAllow` lists them;
  - a CONNECT to GitHub's three hosts: the GitHub gate. agent-proxy's own
    authority shows a leaf for the host, each request is decided by the gate
    (gate.json, or the standard rules), and it goes on with the **auth
    token**. Whatever authorization the client sent (a container's gh sends
    its `GH_TOKEN` placeholder) is taken off first. A read of a repository
    outside the allowed ones goes on **anonymously**, with no authorization
    at all (Logan, 9 Nov 2026: an agent's open-source dependencies); so does
    a read of an allowed one while no token is configured (from 0.71.1):
    REST's GET and HEAD, a GraphQL query, a fetch or a clone
    (`info/refs?service=git-upload-pack`, `git-upload-pack`), an LFS
    download, and a release's asset or a ref's archive. GitHub answers a
    private repository's with 404, and its GraphQL API answers 401 to any
    request without a token. A write (a push, its `git-receive-pack`
    discovery too, a REST write, a GraphQL mutation) still needs the token,
    and without one is refused, saying where it is set. Only a token that
    isn't configured lets a read go on anonymously: one GitHub turns down, or
    one that can't be had, never does. The egress log names such a request's
    decision `anonymous`;
  - a CONNECT to api.anthropic.com: the Anthropic interceptor. Its own
    authority (constrained to that name) shows a leaf, and each request
    goes on with the **Claude credential** in place of the agent's
    placeholder, `oauth-2025-04-20` merged into `anthropic-beta`; without
    one it's answered 401 (docs/containers.md, "Claude's credential");
  - `POST /dns-query`: DNS over HTTPS, split by `dns`;
  - a CONNECT to `<name>.agent.internal:<port>`: a dial-in to a port on
    this computer (`dialIns`), or agent-proxy's own, `mcp.agent.internal:80`,
    to the MCP pass-through's port, wherever the pass-through runs (from
    0.72.1);
  - `/mcp/<name>`: refused with 404 for now. The container runner (step 4)
    gives it something to answer.

  Each connection is a line of the egress log, a JSON object with no bodies,
  headers or tokens. Nothing of Visor's relays containers to it yet: the
  container runner (step 4 of the container-runner plan) will. That runner
  runs `relay-client` (in every container at `/opt/visor/bin/relay-client`;
  mounted elsewhere, its file must still be named `relay-client`, the name
  visor-server answers to), carries in
  `/run/agent-proxy/relay.sock`, and gives the container no network of its
  own.

What stayed in Shireworks:
- the `shireworks.agent.internal` forward to Shireworks' API, and
  `/mcp/shireworks`, with their agent key (ShireworksMCP, ShireworksRoutes,
  Forward). Their tests stayed too: ShireworksRoutesParityTests, ForwardTests
  and the forward's relay tests;
- logan-shire-agent's App key and its installation tokens (GitHubAppTokens).
  The gate attaches the auth token from Settings instead, so Visor has no
  hard dependency on Logan's GitHub Apps. From 0.71.1 an App's tokens are
  back as a choice: see The GitHub App, below;
- the relay token handed over on standard input. Here it is a secret of the
  server's, which agent-proxy makes the first time.

## The settings

ServerSettings' `agentProxy`, in the server's settings.json (on a Mac,
`~/Library/Application Support/Visor/settings.json`). Every field is
optional:

```json
"agentProxy": {
  "mcp": {
    "port": 7439,
    "upstreams": [
      {"name": "gh", "url": "http://127.0.0.1:7470/mcp",
       "headers": {"X-Client": "visor"}, "secretHeaders": ["API_KEY"],
       "withheldTools": []}
    ]
  },
  "relayPort": 7438,
  "egressAllow": ["192.168.1.20:8443"],
  "dns": {"tailnetSuffixes": ["ts.net"], "tailnet": ["100.100.100.100"], "fallbacks": ["1.1.1.1"]},
  "dialIns": [{"name": "visor", "port": 7434}],
  "maxConnections": 512, "maxConnectionsPerLease": 128,
  "egressLog": "…", "caCertificate": "…", "gateRules": "…",
  "gh": {
    "repositories": ["AttilaTheFun/*"],
    "agentToken": "~/.local/bin/agent-token",
    "agent": "logan-shire-agent",
    "sessionAgents": {"<session id>": "logan-shire-claude"},
    "auditLog": "…",
    "withheldTools": []
  }
}
```

- Without `mcp`, there is no pass-through, unless `gh` is set: then the
  pass-through listens on 7439 for gh_mcp alone. Without `relayPort`, there
  is no relay listener.
- By default the egress log is `~/Library/Logs/Visor-egress.log` on a Mac,
  and `<data folder>/agent-proxy/egress.log` elsewhere.
- The authority's certificate is `<data folder>/agent-proxy/ca.pem` unless
  `caCertificate` says otherwise. A `gate.json` put there replaces the
  standard rules, wholesale (below, under Release proposals on main).
- An `agentProxy` that can't be read leaves the rest of the settings as they
  are. agent-proxy then runs with the last good one it kept
  (`agent-proxy/last-good.json`).

## gh_mcp in agent-proxy (from 0.66)

gh_mcp is GitHub for coding agents: an agent gets only the GitHub access it
needs, and holds no GitHub credential. Until 0.66 it was a program of its own
(AttilaTheFun/gh_mcp, now archived; its main ends at #12), on 7470 as the
LaunchAgent `gh_mcp.server`, and agent-proxy's `gh` upstream passed calls on
to it. Logan, 21 Nov 2026: "fold gh_mcp into Visor's agent-proxy at /mcp/gh,
retire the LaunchAgent and binary". It is now `libraries/visor_gh_mcp`
(module VisorGHMCP), and agent-proxy answers it in its own process at
`/mcp/gh` on the pass-through's port. Its tests are
`tests/visor_gh_mcp_tests`.

**What a session sees doesn't change.** It gets the same 35 tools
(`gh__pr_create`, `gh__git_push`, …), with the same names, descriptions and
input schemas, byte for byte. `tests/visor_gh_mcp_tests` checks `tools/list`
against gh_mcp's own answer, recorded from its source. The answers, the
errors and the rules are gh_mcp's too:

- a push goes to `refs/heads/<branch>` only, never to main, master, the
  default branch or a tag;
- a force push is made only with a lease;
- a merge happens only when every check is green;
- reviews are COMMENT only;
- an issue's state is never edited;
- only the allowed repositories are touched (`repositories`,
  `AttilaTheFun/*` unless said).

Its README's never-list is `Policy.never`.

**Who the caller is.** gh_mcp took a key (`API_KEY`), which named an
application and an agent. Here there is no key. A call has already shown the
sessions' token (`X-Visor-Proxy`) to reach `/mcp/gh`, and its `CLIENT_ID`
(the session's own id, since #482) names the session.

**How far that is trusted.** `CLIENT_ID` is the caller's word, and the
sessions' token is one token shared by every native session. (The Sessions
container's agents never reach gh_mcp: their gh is the gh CLI through the
GitHub gate. Their calls to Nimbus's MCP carry their token's session as
CLIENT_ID, set by the pass-through; see The container's agents and the
pass-through.) So anything
holding the token can name any session, act as the app `sessionAgents` gives
that session, and be logged as it. `CLIENT_ID` and `sessionAgents` are
trusted only as far as the token is: they choose among the apps the token
already reaches, and are not an authority of their own. Keep the token from
anything that shouldn't act as every session, and
give a session its own app only to choose its GitHub identity, not to fence
it off from the others. So don't use `sessionAgents` to give a session an app
with more access on GitHub than `agent`'s. A later improvement is to bind
each call to its session's own JWT, so that one session can't claim
another's `CLIENT_ID`.

**Tools kept from the sessions.** `withheldTools` names gh_mcp tools the
sessions may not call, by gh_mcp's own names (`pr_merge`, not
`gh__pr_merge`). They are left out of `tools/list` and their calls
are refused (-32601) before gh_mcp sees them, as an upstream's
`withheldTools` are. They're read when agent-proxy starts.

**Tokens, per agent.** Each call acts as one of the GitHub Apps:
logan-shire-claude, -codex or -agent. Which one comes from `sessionAgents`
(by session id), else `agent` (logan-shire-agent unless said). Either may
name an app in full or by its last word (`claude`). The app's installation
token comes from `agentToken`, which is run exactly as gh_mcp ran it:
`~/.local/bin/agent-token token <agent> --owner <owner>`, with `<agent>`
being claude, codex or agent. Each token is kept for four minutes, and is
dropped when GitHub refuses it. agent-token holds the Apps' keys, and Visor
holds none.

The seam for minting tokens in-process later is VisorGHMCP's `TokenSource`.
A source that signs for installation tokens with App keys kept in Visor's
secrets would replace `AgentTokenCommand` there, and nothing else would
change. That isn't built yet.

**Settings read at each call.** `repositories`, `agent` and `sessionAgents`
are read again from settings.json at each `initialize` and `tools/call`, as
the dial-ins are, so a session given its own app needs no restart.
`tools/list` reads nothing: it is gh_mcp's catalog. If settings.json can't be
read, has no `agentProxy.gh`, or names an `agent` that agent-token doesn't
know, the last good settings stand in, and the log says so once. Taking
`gh` out therefore needs a restart. `agentToken`, `auditLog` and
`withheldTools` are the ones agent-proxy started with.

**The audit log.** Each tool call is one line, in gh_mcp's form: the time,
`<session id>@visor`, the tool, the repository, and the outcome (`ok`,
`refused: …`, `invalid: …`, `failed: …`). It never holds a token, a key or a
body. It is `auditLog`, or else `Visor-gh.log` in the server's logs folder,
beside the egress log. On a Mac, that is the Visor volume's `Logs/`
(`/Volumes/Visor/Logs`) where that volume is there, else `~/Library/Logs`.
Elsewhere it is `<data folder>/agent-proxy/gh.log`.

**What stayed behind** with the archived repo: gh_mcp's own HTTP listener,
its keys and `key` command, `~/.config/gh_mcp/config.json`, and its
LaunchAgent and `install`.

### The cut-over, per Mac

While `agentProxy.mcp.upstreams` still names `gh` (gh_mcp at 7470), calls
are passed through to it as before, even with `gh` set. The cut-over is a
settings change:

1. Install the release.
2. In settings.json, set `agentProxy.gh` (`{}` takes every default) and
   remove the `gh` upstream from `agentProxy.mcp.upstreams`. Then, with
   Logan's go, restart the server. agent-proxy starts again with the new
   settings: inside the server (Visor.app's, or visor-server's). Check
   its log for "the MCP pass-through is on loopback port 7439: /mcp/gh
   (in-process)".
3. Check that one gh call passes: from a native session, a read such as
   `gh__pr_list` on AttilaTheFun/visor. Then find its line in
   `Visor-gh.log`.
4. NCH boots out `gh_mcp.server`, and removes its plist
   (`~/Library/LaunchAgents/gh_mcp.server.plist`) and its binary
   (`~/.local/bin/gh_mcp`). `~/.config/gh_mcp` and `~/Library/Logs/gh_mcp.log`
   can go with them. agent-token stays as long as `agentToken` runs it.

Sessions' `mcpEndpoints` don't change: they still point at
`http://127.0.0.1:7439/mcp/gh`. The `mcp/gh/api_key` secret is no longer
read once the upstream is gone (`agent-proxy secret-remove mcp/gh/api_key`).
The MacBook's own gh_mcp goes when its sessions move to the Mini.

## The container's agents and the pass-through (0.72.1)

A native session reaches the pass-through through Visor's server, which
shows the sessions' token. The Sessions container's agents reach it
themselves (docs/containers.md, "MCP in the container"), for Nimbus's MCP
alone, and the token never goes into the container. Logan, 25 Nov 2026:
"agents can talk to the visor and nimbus mcps as well which are proxied
through visor to authenticate them just adding the headers visor saves in
its keychain"; gh in a container is the gh CLI through the GitHub gate, oss
is retired, and Shireworks' MCP is Nimbus's now. This replaces the 16 Nov
rule (no passed-on servers in a container) for Nimbus only.

- **The dial-in.** With the pass-through and the relay listener both
  running, the relay has a dial-in of agent-proxy's own:
  `mcp.agent.internal:80`, joined to the pass-through's loopback port (7439,
  or `mcp.port`; the one it started with). It isn't the settings': a
  `dialIns` entry named `mcp` is passed over, and the log says so. Like any
  dial-in it is that name and port alone: `mcp.agent.internal` on another
  port is refused, and the pass-through's port is never reached by loopback
  (the egress proxy refuses this computer's addresses). The relay listener's
  line at the start lists it (`, mcp.agent.internal:80 to loopback port
  7439`).
- **The token.** A call shows `X-Visor-Proxy` as before. The sessions'
  token lets it in as it always has. Any other token shaped as a JWT is
  checked first, at once, with no wait on the server (`agentTokenCheck`,
  VisorServer.passThroughTokenCheck: signed with a live key of the
  server's, for `visor.runner-agent`, of its issuer, unexpired, from the
  keys as last read, which follow each rotation); one that fails is refused
  with 401 there (NCH's check of #536: a forged token would otherwise hold
  one of the pass-through's places for the whole wait). One that passes is
  asked about (`agentSession`), on the call's own thread, for at most 10
  seconds, by at most 8 calls at once (`maxVouches`; another is refused
  with 503 at once): the server, which runs agent-proxy and the container
  in one process, answers with the session it acts as. That's a token of the
  server's (`visor.runner-agent`), unexpired, allowed MCP, naming an agent
  its container runner runs now (not let go), and that agent's session,
  live. Anything else (expired, forged, another server's, another session's,
  a native session's, an ended agent's) is refused with 401, before
  anything goes on. The agent's harness gets such a token from its own
  wrapper's stream, for MCP alone, an hour's, and asks again as it needs one
  (`visor-agent-host mcp-headers`, its Claude's headersHelper).
- **Nimbus's alone.** A call let in by an agent's token reaches only the
  servers containers are given (`NativeMCPProxy.containerServers`:
  `nimbus`). On any other path (`/mcp/gh`, `/mcp/oss`, `/mcp/shireworks`)
  it's refused with 403, its server never called. A token that's no one's
  is refused (401) first.
- **As its session.** A call let in by an agent's token goes on as that
  token's session: whatever `CLIENT_ID` it sent is replaced with its
  session's id, so Nimbus knows it by its token, not its word. An
  upstream's plain header of `$SESSION_ID` is filled with it, and one naming
  anything else of the session (`$SESSION_TITLE`, `$SESSION_REPOSITORY`) is
  left out; the caller's own of those names never goes on. The upstream's
  plain and secret headers (`mcp/nimbus/<header>` from Visor's secrets) are
  added exactly as for a native session's call, so the container never sees
  them. The token stops at the pass-through, as the sessions' token does.
- **Where.** Only the server agent (`Visor --server`) gives agent-proxy a
  server to ask. As a launchd job, or in visor-server on Linux, nothing
  runs a container, and the pass-through takes the sessions' token alone.

## The secrets

They are the server's own secrets: the keychain on a Mac (under the server's
service, `<bundle id>.server`), the secrets file elsewhere. Each is kept as
`agent-proxy/<name>`, never in the settings. agent-proxy reads its own items
and nothing else of the server's, and reads each again within a minute, so a
new one needs no restart.

| name | what | made by |
|------|------|---------|
| `github-token` | the auth token: the GitHub credential the gate attaches for container sessions. Optional: without it (and without the App), nothing that needs a token reaches GitHub through the proxy | you |
| `github-app/key` | the GitHub App's private key, a PEM (PKCS #1, `BEGIN RSA PRIVATE KEY`, as GitHub issues it, or PKCS #8). With `github-app/id`, the gate attaches the App's installation tokens instead of `github-token` | you |
| `github-app/id` | the GitHub App's id | you |
| `github-app/installation` | the App's installation's id. Optional: without it, the installation of the gate's owner | you |
| `mcp/token` | the sessions' token, shown in `X-Visor-Proxy` by Visor's server for its native sessions; never in a container (its agents show their own) | you (on the Mini, Shireworks' `agent-proxy/mcp/token`, imported) |
| `mcp/<upstream>/<header>` | an upstream's secret header (the header lower-cased) | you |
| `claude/oauth-token` | the Claude credential (a `claude setup-token` token) the Anthropic interceptor attaches for container sessions. Optional: without it, every request to api.anthropic.com is refused | you, in Settings › Sessions Container (Sign In to Claude…), or the import |
| `relay-token` | the relay's token | agent-proxy, the first time |
| `ca.pem`, `ca-key.pem` | the GitHub authority, made new (a private key never moves) | agent-proxy, the first time |
| `anthropic-ca.pem`, `anthropic-ca-key.pem` | the Anthropic authority (api.anthropic.com alone) | agent-proxy, the first time |

**The import**, with the value on standard input. It refuses a terminal, and
the value is never an argument:

```sh
# Linux (visor-server)
printf '%s\n' "$token" | visor-server agent-proxy secret-set mcp/token
# a Mac: Visor's own executable, so the item is the app's
printf '%s\n' "$token" | /Applications/Visor.app/Contents/MacOS/Visor agent-proxy secret-set mcp/token
# removing one
/Applications/Visor.app/Contents/MacOS/Visor agent-proxy secret-remove github-token
```

A name may also be given with its `agent-proxy/` prefix, as Shireworks names
it (`agent-proxy/mcp/token`). The command takes one line of at most 16 KB;
`github-app/key` takes its PEM, every line of it.

## The GitHub App (optional, from 0.71.1)

Container agents can act on GitHub as a GitHub App, logan-shire-agent,
never as Logan: the gate mints the App's installation tokens and attaches
them in place of the auth token. It is a choice (Logan's approval, for
0.71.1); without the App's secrets nothing changes, so Visor still has no
hard dependency on his GitHub Apps.

**Which credential.** At each request, from the secrets as kept now:
1. with `github-app/key` and `github-app/id` both set, the App's
   installation token;
2. otherwise `github-token`, as before;
3. otherwise none: what needs a token is refused.

The key or the id alone isn't the App, and the auth token is used. A
broken App (a key that isn't one, no installation) doesn't fall back to the
auth token: its requests are refused, saying why.

**The installation** is `github-app/installation` when it is set.
Otherwise it is found with the App's JWT: `GET /app/installations`, the one
whose `account.login` is the gate's owner (the owner of its first
repository, `AttilaTheFun` in the standard rules), case aside. It is kept.

**The tokens.** The App's JWT is RS256 (issued a minute ago, good for nine
minutes, the App's id its issuer), signed with its key by swift-crypto's
_CryptoExtras, on a Mac and on Linux alike. It mints the installation's
token with `POST /app/installations/{id}/access_tokens`, for the
repositories the gate's rules list for the owner (none named for
`owner/*`: all the installation's) and with the permissions the rules need
(GateRules' `tokenRepositories` and `tokenPermissions`). With `owner/*`, a
token reaches every repository of the owner the App is installed on, and
the gate's rules are what limit it, as with a `github-token` today (NCH's
review of the App source). A token is kept
until five minutes before it expires, about an hour; requests that come
while one is minted wait for that one. GitHub turning a token down (401)
has the next request mint another.

**Its bot, the container agents' git identity** (0.72.1). The App's bot
user is who the Sessions container's agents commit as (docs/containers.md,
git's identity in the container): its name `<slug>[bot]`, its email
`<id>+<slug>[bot]@users.noreply.github.com`. The slug is the App's, from
`GET /app` with its JWT; the id is its bot user's, from `GET
/users/<slug>%5Bbot%5D` (the brackets escaped) with an installation token,
not anonymously (anonymous reads share the containers' sixty an hour). It
is found at the start, beside the installation, and kept for the secrets;
askers that come together share one finding, and one that failed is tried
again at the next asking. The server, with agent-proxy inside it, asks the
GitHub interceptor for it (`gitIdentity`, through `AgentProxyHost.Running`)
as each container agent starts, and sets `GIT_AUTHOR_NAME`,
`GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME` and `GIT_COMMITTER_EMAIL` from it.
Without the App, or when it couldn't be found, none is set. On the Mac,
agent-proxy is folded in just after the server's start, and the Sessions
container's agents are carried on at it: the server is told before it
starts that agent-proxy is to come (`containerGitIdentityExpected`), and an
agent started before it's folded in waits for it, its fold-in and its
answer within the same ten seconds; past them, it starts without one.

The secrets are read again at most once a minute, like the others, so
setting or changing them needs no restart. With other secrets, the
installation and the token kept are forgotten.
With other secrets, the bot is found again.

**Closing its own** (0.72.1). Logan's decision, 25 Nov 2026: "agents may
close pull requests and issues they opened themselves", that is, those
whose author is the App's bot (`<slug>[bot]`, logan-shire-agent[bot]).
Before, the gate refused every close ("closing and reopening are Logan's").
Now a close is one of the checks that read before they write (GateChecker,
`GateCheck.close` and `graphQLClose`), read with the token the close goes on
with:
- REST: `PATCH /repos/{o}/{r}/issues/{n}` or `…/pulls/{n}` with `state:
  "closed"` (and, for an issue, `state_reason` `completed` or
  `not_planned`; the edit's other fields as an edit's) reads `GET
  /repos/{o}/{r}/issues/{n}` and passes only if its `user.login` is the
  bot's name;
- GraphQL: `closeIssue` (`issueId`, `stateReason` COMPLETED or NOT_PLANNED)
  and `closePullRequest` (`pullRequestId`), each a mutation of its own (gh
  issue close and gh pr close send them so), read the node: an Issue or a
  PullRequest as named, in an allowed repository, its `author` a Bot whose
  login is the slug (GraphQL names a bot without `[bot]`).

Anyone else's is refused: `… #<n> of <owner/repo> is <login>'s: an agent
closes only what it opened itself (<slug>[bot]'s)`. With no App (the auth
token, or none) or its bot not found, the bot is unknown and every close is
refused before GitHub is asked: `… with no GitHub App (github-app/key and
github-app/id) or its bot not found, closing is Logan's`. Still Logan's
alone: reopening (`state: "open"`, `reopenIssue`, `reopenPullRequest`), an
agent's own included, merging, publishing a release and deleting a ref.

**The import**, on a Mac in the desktop session (the secrets are in the
keychain), from the App's files in `~/Library/Application Support/Agents/github`:

```sh
"/Applications/Visor.app/Contents/MacOS/Visor" agent-proxy secret-set github-app/key < "$HOME/Library/Application Support/Agents/github/logan-shire-agent.pem"
python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["id"])' "$HOME/Library/Application Support/Agents/github/logan-shire-agent.json" | "/Applications/Visor.app/Contents/MacOS/Visor" agent-proxy secret-set github-app/id
```

On Linux, the same with `visor-server agent-proxy secret-set …`. Removing
`github-app/key` (`agent-proxy secret-remove github-app/key`) goes back to
`github-token`.

**Its lines in the log** (agent-proxy's: the server's log, Visor-server.log,
where it runs inside the server; `Visor-agent-proxy.log` as its own job):
- at the start, and when the secrets change (at the next request):
  `agent-proxy: github: tokens minted as the GitHub App <id> (installation <n> of <owner>), hourly, for <repositories, comma-separated | all of <owner>'s>`;
- each mint: `agent-proxy: github: an installation token minted (expires <ISO 8601 time>)`;
- its bot, once found (at the start, and when the secrets change):
  `agent-proxy: github: commits as <slug>[bot] <id>+<slug>[bot]@users.noreply.github.com`;
- why the container agents have no git identity, once until it changes:
  `agent-proxy: github: no git identity for container agents: <why>`, where
  `<why>` is `no GitHub App (github-app/key and github-app/id)`, `GitHub
  answered <status> for the App (GET /app): <message>`, `GitHub answered
  <status> for the App's bot user (GET /users/<slug>[bot]): <message>`, or
  what kept a token from being minted;
- what went wrong, once until it changes:
  `agent-proxy: github: the App's key isn't a PEM`,
  `… no installation of the App for <owner>`,
  `… GitHub answered <status> minting a token: <GitHub's message>`,
  `… GitHub answered <status> listing the App's installations: <message>`,
  `… the App's installation (github-app/installation) isn't a number`.
  The request is refused as with no token, saying why
  (`agent-proxy has no auth token for GitHub: <why>`).

No line, refusal or egress log entry holds the key, a JWT or a token.

## Release proposals on main (0.73)

Logan's rule (23 Nov 2026): agents propose releases freely, and only he
publishes. Container agents propose one the way he does, with a dispatch of
Visor's ci.yml on main (`gh workflow run ci.yml -R AttilaTheFun/visor --ref
main -f run=release`, or `prerelease`, or `verify`). The gate lets that
through under NCH's five conditions (26 Nov 2026), and a fresh Mac needs no
gate.json for it.

**The standard rules** (GateRules' `standard`, with no gate.json):
- on main, Visor's ci.yml with `run` one of `verify`, `prerelease` and
  `release`, at most 4 an hour. These only build, sign main's reviewed
  code, and propose a draft (docs/DEVELOPMENT.md, CI);
- on an agent's own branch, Visor's ci.yml with `run: verify` alone (NCH's
  review of #557). Never `prerelease` or `release` off main, and never
  `agent-image`: on a branch it would build that branch's toolchain image
  and push it to ghcr.io (#558 makes the job main-only, and the list keeps
  it off branches regardless). No other workflow is dispatched on a branch
  unless a gate.json lists it.

**gate.json.** Three fields, all optional, so a gate.json written before
them is still read. One that leaves `mainDispatch` out has no dispatch on
main, and one that leaves `branchDispatch` out lists no branch's inputs, as
before. A gate.json replaces the standard rules wholesale, so to keep
Visor's proposals it lists them itself:

```json
"dispatchableWorkflows": [".github/workflows/ci.yml", "AttilaTheFun/shireworks:.github/workflows/ci.yml"],
"mainDispatch": {
  "perHour": 4,
  "workflows": {
    "AttilaTheFun/visor:.github/workflows/ci.yml": {"run": ["verify", "prerelease", "release"]}
  }
},
"branchDispatch": {
  "workflows": {
    "AttilaTheFun/visor:.github/workflows/ci.yml": {"run": ["verify"]}
  }
}
```

- `dispatchableWorkflows`: dispatches on a branch of the agent's own, with
  any inputs within `dispatch`'s limits (`maxInputs`, `maxValueLength`), as
  before. An entry is a file's name (`ci.yml`) or path
  (`.github/workflows/ci.yml`) in any allowed repository, or one
  repository's path (`owner/name:path`).
- `branchDispatch.workflows`: dispatches on a branch of the agent's own with
  their inputs listed, named and checked as `mainDispatch`'s are (below):
  every listed input given, one of its values, and no other. A workflow
  listed here is held to its list even where `dispatchableWorkflows` names
  its file too, so `ci.yml` there doesn't let Visor's `agent-image` onto a
  branch.
- `mainDispatch.workflows`: dispatches on a repository's default branch.
  Each workflow is `owner/name:.github/workflows/<file>`, exactly. The
  repository is compared case aside, as GitHub compares it, and the path
  exactly. A file's name or a path alone is never matched here, and a
  gate.json with one isn't read. The repository is part of the name
  because an input means what that repository's workflow does with it:
  `run: release` proposes a draft in Visor's ci.yml, and another
  repository's `run: release` may publish. Each workflow lists its inputs,
  each with the values it may take.
- `mainDispatch.perHour`: how many of a repository's go through in any hour
  (4 if left out; 0 for none).

**How a dispatch on main is decided.** A dispatch (`POST
/repos/{o}/{r}/actions/workflows/{id}/dispatches`) names its branch alone,
never `heads/…`, `refs/…` or `tags/…`. When it names main (or another
protected branch), the repository must have a `mainDispatch` workflow. The
check then reads the repository's default branch and the workflow (its file,
its state) with the token the dispatch goes on with. On the default branch,
the dispatch goes through only if:
1. the workflow is the repository's listed one, by its exact path, and
   active;
2. it gives every listed input, each one of its values, and no other input;
3. fewer than `perHour` of the repository's went through in the last hour.

Otherwise it is refused, saying which: `CI's run on main is one of verify,
prerelease, release, never another value`, `CI on main takes no input
note: only run (verify, prerelease, release)`, `CI on main is dispatched
with run given: …`, `… isn't among the workflows dispatched on main,
<repo>'s default branch (gate.json's mainDispatch, each as
owner/name:path)`, or `<repo> has had 4 dispatches on main in the last
hour, the most gate.json's mainDispatch.perHour lets through: the next in
<n> minutes`. A refusal never repeats the value it refused. The count is the
gate's, in memory, shared by every container. **It resets when agent-proxy
restarts** (with the server, where it runs inside it): it is a soft rate
limit, not a ledger, and the audit's lines below are the record of what
was dispatched. A dispatch is counted once its checks pass, whether or not
GitHub then runs it. A protected branch that isn't the default (master,
say) is never dispatched on. A dispatch on any other branch is checked as
before: a listed workflow, active, on a branch that is there, with its
inputs as `branchDispatch` lists them where it lists the workflow.

**The audit.** Each dispatch on main is one line of agent-proxy's log,
whether it went through or was refused, by the gate or by its check:

```
agent-proxy: github: dispatch on main: container:<lease> agent <id>, AttilaTheFun/visor .github/workflows/ci.yml on main, inputs run=release: allowed
agent-proxy: github: dispatch on main: container:<lease> agent <id>, AttilaTheFun/visor .github/workflows/ci.yml on main, inputs run=(15 characters, not written): refused: CI's run on main is one of verify, prerelease, release, never another value
```

`<lease>` is the container's (the relay's), and `<id>` is the agent it
claims to be (`unnamed` without one). The workflow is `workflow <id>` when
the check didn't get as far as its file. An input's value is written only
when the lists have it; otherwise only its length is. The line never holds
a header, a token or the request's body. The egress log has its usual line
for the request too (method, path class, decision), as it does for a
dispatch on a branch.

**Still Logan's alone**, whatever gate.json says: publishing a release
(REST's release made without `draft: true`, or edited with `draft: false`;
any release mutation by GraphQL), cancelling a run on the default branch or
main, whatever its event (a proposal, main's verify, a push's populate), or
a published release's `release` run, and deleting a ref or a release (`DELETE …/git/refs/…`,
`DELETE …/releases/…` and its assets, `deleteRef`, `deleteRelease`, a push
to the zero commit). An agent cancels a run only on a branch of its own,
told as a push's own branch is (not protected, not the default, of
`ownBranchPrefixes` when gate.json lists any) and in the repository itself
(not a fork's): the cancel reads the run and the repository's default
branch first. Anything else is refused: `… is on main, <repo>'s default
branch or main: an agent never cancels a run there, whatever its event`. The draft itself is CI's, with the run's token, and
Logan's Release in Reviews publishes it.

## How it runs

**On a Mac**, from 0.72.1, it runs inside the server, in Visor.app's own
process (below). Until then, beside the server in the app, it was a
launchd LaunchAgent, `<bundle id>.agent-proxy`
(`com.LoganShire.Visor.agent-proxy`), in
`~/Library/LaunchAgents/com.LoganShire.Visor.agent-proxy.plist`. Its program
is **Visor.app's own executable with `--agent-proxy`**: the app's signature
is what lets it read the server's keychain items, and a tool in
Contents/Helpers can't carry that. Its log is
`~/Library/Logs/Visor-agent-proxy.log`, moved aside to `.1` past about 8 MB.

At each start, Visor's server in the app settled the job (AgentProxyJob):
- With `agentProxy` set, and no job running, or one of another version,
  other settings (a digest in the plist) or another program, the plist is
  written and the job started (again).
- The same job, running, is left alone: a restart of Visor cuts no session's
  MCP.
- Without `agentProxy`, the job is stopped and its plist removed. A Mac that
  never set it has none.
- Nothing is written for a copy of the app outside /Applications, or while
  settings.json can't be read.

The job is started again 5 seconds after a failure. A listener that can't be
had (its port still Shireworks') is a failure, so the job retries until the
port is free. With nothing configured it ends with 0 and stays ended. Once
you've changed `agentProxy`, restart Visor; the job is restarted with the new
settings.

**Inside the server** (Visor.app's own process from 0.72.1, and the
server agent's, `Visor --server`, before it: docs/DEVELOPMENT.md, The server
in the app), agent-proxy runs as on Linux: at the server's start the job
is stopped and its plist removed, then the proxy is started in the
server's process when `agentProxy` is set (MacAgentProxy.foldIn), and
started again when it changes.

**On Linux**, visor-server runs the same proxy **inside its own process**,
started once the server is made, when `agentProxy` is set. A change takes a
restart of visor-server. This is the simpler choice: no second process, the
same secrets file, and its lines in the server's log.

**relay-client** is visor-server run by that name: a link to it, as
visor-agent-host is, made by `tools/linux_programs.sh`, which builds
visor-server static for arm64 Linux. A relay-client of its own was 67 MB
stripped, most of it the Swift runtime, Foundation's ICU data and BoringSSL
that visor-server already carries; inside visor-server it costs about
nothing. It is checked to run, and is in the linux-programs tar and the Mac
app's `Contents/Resources/Linux`, a link beside visor-server. The container
runner mounts it into its containers. `//applications/relay_client` is the
same command on its own, for Bazel.

## The cut-over, per Mac

Only the Mini runs one today. The MacBook's Shireworks has no `agentProxy`.
Visor's listens on the same port, 7439, with the same token, so `mcpEndpoints`
don't change.

1. Export Shireworks' `agent-proxy/mcp/token` (the admin-only export, stdout
   to a pipe) into Visor's:
   `… | /Applications/Visor.app/Contents/MacOS/Visor agent-proxy secret-set mcp/token`.
   Set each upstream's secret headers again from their source
   (`… secret-set mcp/gh/api_key`), and `github-token` (or the GitHub App's
   `github-app/key` and `github-app/id`) when container sessions are to have
   GitHub.
2. Add `agentProxy` to Visor's settings.json, copying the upstreams from
   Shireworks' `nativeMCP.endpoints`, without `oss`. `shireworks` becomes
   Nimbus's MCP once it has one. Leave `relayPort` out until the container
   runner lands.
3. Remove `agentProxy` from Shireworks' server.json and restart Shireworks.
   That frees 7439 and the relay port. Don't touch `oss.network`.
4. Restart Visor. Its server writes and starts
   `com.LoganShire.Visor.agent-proxy`. Check
   `~/Library/Logs/Visor-agent-proxy.log` for "the MCP pass-through is on
   loopback port 7439", then make one MCP call from a native session.

If Visor's job starts before step 3, it retries every 5 seconds until 7439 is
free, so the order of 3 and 4 only decides how long the gap is.
