# GitHub through the Runner (0.47)

Logan, 31 Oct 2026: "we retire gh mcp, have the runner hold a github app key
and be configured with the rules for what agents should be allowed to do and
it's a true forward proxy like Charles so the agents think they're talking to
github.com but it passes through the visor proxy. The visor runner configures
the container / server and tells it to trust its certificates." On 7 Nov 2026,
with 0.46 released, he made it 0.47's work.

This is the design. The rules it enforces are gh_mcp's, ported as behaviour:
`docs/github-gate-rules.md` lists every one (97 guards, cited to gh_mcp's
source at 6c29c8f, with the 39 tests that pin them) and maps each allowed
operation to the requests `git` and `gh` send. Ids like **[M3]** below point
there.

## What changes for an agent

- Agents use `git` and `gh` (and `curl` against the API) as anywhere else:
  clone, fetch, push their branches, open and edit pull requests, comment,
  merge a green pull request, re-run and dispatch workflows, draft releases.
- They hold no GitHub credential. `GH_TOKEN` is a placeholder the proxy
  replaces; git has no credential helper of its own.
- A repository outside the allowed ones (an open-source dependency,
  `swiftlang/swift-foundation`, say) is read through the proxy with no token
  at all, as anyone on the internet reads it: a clone or fetch
  (`git-upload-pack`), an LFS download, and its REST GETs (Logan, 9 Nov 2026).
  The client's placeholder is taken off and nothing is put in its place, so
  a private repository of anyone else stays out of reach (GitHub answers 404).
  Nothing else of it goes through: no push, no write, no GraphQL.
- A refusal reads as GitHub's own errors do, in each client's form: REST `403
  {"message": "Refused: …"}`, GraphQL `{"errors": [{"type": "FORBIDDEN",
  "message": "Refused: …"}]}`, git `! [remote rejected] … (Refused: …)` or
  `fatal: remote error: Refused: …`. The reasons keep gh_mcp's wording.
- The `gh__…` MCP tools go, with gh_mcp, once the proxy is in.

## The pieces

1. **The proxy** (libraries/visor_runner, the Runner's agent on each Mac).
   - An HTTP `CONNECT` listener. Each server's agents reach it through
     `HTTPS_PROXY`, with `Proxy-Authorization: Basic <server token>:<session
     id>`. The server token is the one the Runner's MCP proxy already checks;
     the session id is the server's word, as for MCP (a client is the trust
     boundary, not a session: docs/co-tenancy.md).
   - It opens TLS only for `github.com`, `api.github.com` and
     `uploads.github.com`, with a leaf from the Runner's own certificate
     authority. The CA is name-constrained to those three names, so it can't
     sign for anything else. Every other host is a plain tunnel, untouched.
   - Its upstream is GitHub over TLS with the system's trust. HTTP/1.1 to the
     client (ALPN `http/1.1`), bodies streamed. Chunked bodies,
     `Expect: 100-continue` and gzip request bodies (upload-pack) are handled;
     nothing is buffered beyond what a check needs.
   - SwiftNIO, swift-nio-ssl and swift-certificates, all already in Visor's
     graph through swift-nio-ssh's neighbours or added by version.
2. **GitHubGate**, the policy, as data in the Runner's settings (below), with
   gh_mcp's rules as the default. Default deny.
3. **One token, from the agents' App** (Logan, 7 Nov: "one read-write GitHub
   token for all agents, which agents can never see"; no Keymaster). The
   Runner holds the logan-shire-agent App's private key in its secrets (the
   keychain for notarized builds, a mode-600 file for debug ones) and mints
   the App's installation token itself: a JWT signed RS256 with the key, then
   `POST /app/installations/{id}/access_tokens` (an hour). The token is kept
   in memory, asked for again five minutes before it expires and at once on a
   401 from GitHub, and attached to every request the gate lets through, for
   every session. No agent, server or container holds the key or the token.
   - It is broad, and Logan accepts that: what protects his repositories is
     GitHub's branch protection, CODEOWNERS and required checks, and
     GitHubGate's rules here. Agents' pull requests stay the App's
     (`logan-shire-agent[bot]`), so Logan reviews them, in the Shireworks app.
   - `visor-runner-agent github-proxy app --app-id <id> --installation <id>`
     takes the key on standard input, once per Mac.
4. **Setup.**
   - A container server's agents: the Runner's CA in the container's trust
     store (`update-ca-certificates`), `HTTPS_PROXY` and `NO_PROXY` in the
     agents' environment, `GH_TOKEN=placeholder`, and git's
     `http.https://github.com/.proxy` set per agent (`GIT_CONFIG_*`). The
     server writes these when it starts an agent; the image needs nothing
     new.
   - The Mac's agents: the same environment, with the CA given through
     `SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS` and `GIT_SSL_CAINFO`, never the
     login keychain.
   - A `ServerPlatform` member says where the CA file is and how to trust it,
     so the server library stays free of platform checks.

## GitHubGate's rules

Every request is checked in this order:

1. **Host and path.** Only the three hosts. Paths are normalized: `.` and `..`
   segments, empty segments and percent-encoded `/`, `.` or `\` are refused, so
   `GET /repos/A/x/../../repos/B/y` can't pass a prefix test. Templates match
   segment by segment ([P1], [P2]).
2. **Repository.** From the path (`/repos/{o}/{r}`, `/{o}/{r}(.git)`) or, for
   GraphQL, from each node id the input names, resolved by a query
   (`node(id:){… on PullRequest{repository{nameWithOwner}} …}`). It must match
   the allowed patterns, `AttilaTheFun/*` by default, case-insensitively ([R2]).
3. **The operation**, by surface:
   - **REST reads** (`GET`/`HEAD` under `/repos/{o}/{r}`): allowed. A redirect
     away from GitHub's three hosts (logs, artifacts, codeload) is followed by
     the client and never gets a token ([P5]).
   - **REST writes**: one template each, with the body fields it may carry and
     their values. Bodies must be absent or a JSON object, with no duplicate
     keys and no query string ([P3], W1–W15). Anything not listed is refused:
     every `DELETE`, refs and contents writes, settings, secrets, protection,
     rulesets, approvals, `force-cancel`, job re-runs.
   - **GraphQL**: queries pass (the token's scope bounds them). A mutation is
     checked on every root field after aliases and variables are resolved.
     Allowed: ready/draft, create and update pull request (title and body
     only), comment, COMMENT review, review reply, create and update issue
     (no state), labels, update branch (merge only). Everything else is
     refused, auto-merge and every delete among it (gh_mcp allowed exactly two
     mutation strings; `gh` builds its own documents, so the check has to be
     by field).
   - **git**: fetch and clone pass for allowed repositories. A push's command
     list is read before any of its pack is forwarded, and the whole push is
     refused if any command is: only `refs/heads/…`, a valid branch name, never
     `main`, `master` or the repository's default branch, no deletes, no
     push certificates ([G3a]–[G3g]). git's empty probe POST passes.
   - **uploads.github.com**: refused (no agent uploads release assets).
4. **Checks that read before they write**, made by the proxy with the same
   token before it forwards the request:
   - **Merge** (`PUT …/pulls/{n}/merge`, and `gh pr merge`'s GraphQL): open,
     not a draft, into the default branch, from a branch of the same
     repository, `mergeable_state` clean, every check run passed (`success`,
     `skipped`, `neutral`) and every status `success`, code owners satisfied
     for owned paths, and the SHA it merges is the head it read ([M1]–[M13]).
     No `admin`, no deleting the branch, no `rebase` wording in a title.
   - **Re-run** and **cancel**: only `push`, `pull_request` and
     `workflow_dispatch` runs at their branch's head, never a release's
     ([RR1]–[RR8], [C1]–[C2]).
   - **Dispatch**: a numeric workflow id of an active workflow, a branch of the
     same repository that exists, at most 10 one-line string inputs. The
     proxy allows `return_run_details` (which `gh workflow run` sends), so
     GitHub answers the run, as gh_mcp did by polling ([D1]–[D8]).
   - **Release edits**: only a draft, never `draft: false`, its tag kept
     ([RL6], [RL7]).
   - **Update branch**: the expected head SHA required, merge only.

The rules are data, so a repository pattern, a protected branch or a switch
changes without a build:

```json
{
  "repositories": ["AttilaTheFun/*"],
  "protectedBranches": ["main", "master"],
  "protectDefaultBranch": true,
  "merge": {"methods": ["squash", "merge", "rebase"], "passingConclusions": ["success", "skipped", "neutral"],
            "codeOwners": true},
  "rerunEvents": ["push", "pull_request", "workflow_dispatch"],
  "dispatch": {"maxInputs": 10, "maxValueLength": 200},
  "forcePushToOwnBranches": true
}
```

## Decisions

Logan approved this design as proposed on 7 Nov 2026 (through Manager): agents
may force-push to their own branches, never to `main` or another protected
branch; `gh pr merge` is checked exactly as the REST merge, and `--auto` is
refused. gh_mcp is retired by it (Rollout, step 5), its cut-over agreed with
the Shireworks session, which maintains it. 0.47 is this work.

1. **Forced pushes** ([G3f]), approved. On the wire a forced push, a lease and a
   fast-forward look the same; gh_mcp forced only with
   `--force-with-lease`, which lives in the client. So: allow
   non-fast-forward updates to agents' own branches (never the protected
   ones). GitHub's compare-and-swap still stops a push over commits that
   arrived after the agent fetched. The deviation: a plain `--force` can now
   replace a branch another agent pushed. The alternative, reading the pack to
   tell a rewrite from a fast-forward, is costly and fragile.
2. **`gh pr merge`**, approved: treat its `mergePullRequest` as the REST
   merge: the proxy runs every merge check and injects `expectedHeadOid` with
   the head it read, so the merge is of exactly what was checked. Auto-merge
   (`--auto`) stays refused: it merges later, unchecked.
3. **One token for all agents**, the App's, as above (Logan, 7 Nov; the
   per-session Keymaster tokens first planned were dropped). Worth knowing, as it
   is today with gh_mcp: workflows write lets an agent push a branch whose
   changed workflow runs at once on the repository's self-hosted runners
   (a same-repository branch or pull request; forks never reach them), with
   that run's own token and OIDC. Keymaster's CI rules honour only the refs
   they name (main, release-*), and Applications takes a branch's builds only
   as betas.
4. **LFS**: downloads pass as reads; uploads and locks are refused.
5. **What gh_mcp did on the Mac that has no place here**: its scratch
   repositories, hook switches and artifact destinations protected the Mac
   from an agent's checkout. Agents now run git in their own sandbox with no
   token, so those go.

## Identity and logs

- The session's agent picks the App (`claude`, `codex`, or the generic
  `agent`); one App for all of them, logan-shire-agent, whose token the
  Runner mints (Logan, 7 Nov: logan-shire-claude and -codex retire).
- One log line a request: time, `<session>@<server>`, method, host, path
  template, repository, outcome. Never a token or a body.
- The token never reaches the agent, and as defence in depth it's scrubbed
  from any response that echoes it.

## Rollout

Each step is a pull request:

1. This design, reviewed by Shireworks, Keymaster and Container Helper.
2. The proxy and its CA, passing everything through (no GitHub host opened
   yet), with tests: tunnels, CONNECT auth, the CA's name constraints.
3. GitHubGate and the token flow, with gh_mcp's tests ported
   (`github-gate-rules.md` §5 marks which), plus the request hazards above.
4. Setup in the server: the environment and the CA for container and Mac
   agents. Behind a setting at first, on for one session, then for all.
5. Container Helper uninstalls gh_mcp on both Macs; Logan archives its
   repository; the `gh__…` tools leave the agents' lists.

CI is unaffected: its jobs act as GitHub Actions with their own token, not
as agents, and don't go through the proxy.
