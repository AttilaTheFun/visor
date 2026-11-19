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
- **The relay listener** on a loopback port (`relayPort`): the containers'
  way out. Each stream starts with the relay's PROXY v2 header, which carries
  the relay's token (TLV 0xE2). After the header comes one of these:
  - a CONNECT or a plain `http://` request: egress to the internet, or to
    this computer's networks where `egressAllow` lists them;
  - a CONNECT to GitHub's three hosts: the GitHub gate. agent-proxy's own
    authority shows a leaf for the host, each request is decided by the gate
    (gate.json, or the standard rules), and it goes on with the **auth
    token**;
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
  "egressLog": "…", "caCertificate": "…", "gateRules": "…"
}
```

- Without `mcp`, there is no pass-through. Without `relayPort`, there is no
  relay listener.
- By default the egress log is `~/Library/Logs/Visor-egress.log` on a Mac,
  and `<data folder>/agent-proxy/egress.log` elsewhere.
- The authority's certificate is `<data folder>/agent-proxy/ca.pem` unless
  `caCertificate` says otherwise. A `gate.json` put there replaces the
  standard rules.
- An `agentProxy` that can't be read leaves the rest of the settings as they
  are. agent-proxy then runs with the last good one it kept
  (`agent-proxy/last-good.json`).

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
| `relay-token` | the relay's token | agent-proxy, the first time |
| `ca.pem`, `ca-key.pem` | the GitHub authority, made new (a private key never moves) | agent-proxy, the first time |

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
