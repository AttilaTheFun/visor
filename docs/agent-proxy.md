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
    token**;
  - a CONNECT to api.anthropic.com: the Anthropic interceptor. Its own
    authority (constrained to that name) shows a leaf, and each request
    goes on with the **Claude credential** in place of the agent's
    placeholder, `oauth-2025-04-20` merged into `anthropic-beta`; without
    one it's answered 401 (docs/containers.md, "Claude's credential");
  - `POST /dns-query`: DNS over HTTPS, split by `dns`;
  - a CONNECT to `<name>.agent.internal:<port>`: a dial-in to a port on
    this computer (`dialIns`);
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
  hard dependency on Logan's GitHub Apps;
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
  standard rules.
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
sessions' token is one token shared by every native session. So anything
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
   settings: as its job, settled to them, or inside the server agent. Check
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

## The secrets

They are the server's own secrets: the keychain on a Mac (under the server's
service, `<bundle id>.server`), the secrets file elsewhere. Each is kept as
`agent-proxy/<name>`, never in the settings. agent-proxy reads its own items
and nothing else of the server's, and reads each again within a minute, so a
new one needs no restart.

| name | what | made by |
|------|------|---------|
| `github-token` | the auth token: the GitHub credential the gate attaches for container sessions. Optional: without it, nothing that needs a token reaches GitHub through the proxy | you |
| `mcp/token` | the sessions' token, shown in `X-Visor-Proxy` | you (on the Mini, Shireworks' `agent-proxy/mcp/token`, imported) |
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
it (`agent-proxy/mcp/token`). The command takes one line of at most 16 KB.

## How it runs

**On a Mac**, it is a launchd LaunchAgent, `<bundle id>.agent-proxy`
(`com.LoganShire.Visor.agent-proxy`), in
`~/Library/LaunchAgents/com.LoganShire.Visor.agent-proxy.plist`. Its program
is **Visor.app's own executable with `--agent-proxy`**: the app's signature
is what lets it read the server's keychain items, and a tool in
Contents/Helpers can't carry that. Its log is
`~/Library/Logs/Visor-agent-proxy.log`, moved aside to `.1` past about 8 MB.

At each start, Visor's server settles the job (AgentProxyJob):
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

**In the server agent** (`Visor --server`, docs/DEVELOPMENT.md, The server
as a background agent), agent-proxy runs inside the server, as on Linux:
at the agent's start the job is stopped and its plist removed, then the
proxy is started in the agent when `agentProxy` is set.

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
   (`… secret-set mcp/gh/api_key`), and `github-token` when container
   sessions are to have GitHub.
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
