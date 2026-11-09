# GitHub rules to port: gh_mcp's guards, as a spec for the Runner's GitHub proxy

Source: `AttilaTheFun/gh_mcp`, `main` at `6c29c8f` (2026-11-06, "run_dispatch,
and run_rerun of a dispatched run (#12)"). File references are
`Sources/GHMCP/<File>.swift:<line>` shortened to `<File>:<line>`; the tests are
`Tests/GHMCPTests/GHMCPTests.swift` (`Tests:<line>`). gh's requests were checked
against `cli/cli` trunk on 2026-11-07 (paths given where it matters).

Every guard has an id in bold, like **[M3]**, so the proxy's rules and tests
can point back here.

## 0. How gh_mcp enforces anything (the two layers)

1. **Request layer: `Policy.refusal`.** Every GitHub REST/GraphQL request any
   tool makes goes through `GitHub.send`, which calls `Policy.refusal(request,
   repo:)` before *every* attempt: the first try, the retry after a 401, and
   each redirect it follows (GitHub:73-97, check at GitHub:81). It denies by
   default: GETs inside the named repository pass, and a write passes only if it
   matches one entry of `Policy.writes` (method, path template, allowed body
   fields, value rule). Policy:3-8, 105-122.
2. **Tool layer.** Each tool checks its arguments and does its own reads
   (pull request state, run state, default branch, and so on) before it sends
   the write. Most of the semantic guards (merge only when green, re-run only at
   the head, edit drafts only) live here, **not** in Policy. Policy alone would
   let through, for example, a `PUT …/merge` with any SHA and method, or a
   dispatch on a tag's short name.

The proxy has to do both on every request: the template, field and value
checks of layer 1, and layer 2's reads before it forwards the write.

The git operations (`git_push`, `git_fetch`) don't go through Policy. They run
`git` on the Mac with their own guards (Git.swift, Fetch.swift).

---

## 1. Configuration

### 1.1 The config file

| Item | Value / default | Where |
| --- | --- | --- |
| Path | `~/.config/gh_mcp/config.json`; `--config PATH` or `GH_MCP_CONFIG` overrides | Command.swift:37-39; Config:77-79 |
| Mode | written 600, its folder 700, atomically (temp + rename); a looser mode is logged as a warning | Config:145-161; Command.swift:104-105 |
| Missing file | the defaults, with **no keys**, so every request is refused | Config:135-136; Command.swift:107-108 |
| Reload | reread whenever its mtime changes, at the next request | Config:169-199 |
| `port` | 7470, on 127.0.0.1 only | Config:31, 62; HTTP.swift:215 |
| `repositories` | `["AttilaTheFun/*"]`. Each entry is `Owner/*` or `Owner/name`, compared case-insensitively | Config:32, 36-38, 63; Rules:89-104 |
| `agentToken` | `~/.local/bin/agent-token` | Config:39-40, 65-67 |
| `log` | `~/Library/Logs/gh_mcp.log` (macOS), `~/.local/state/gh_mcp/gh_mcp.log` elsewhere | Config:41-42, 69-75 |
| `keys[]` | `{application, agent, sha256, created}`. Only `keys` is required | Config:10-26, 43 |

**Keys.** A key is `ghmcp_` plus 32 random bytes, base64url (Config:117-124).
Only its SHA-256 is stored (Config:106). Lookup rejects an empty key or one over
512 bytes, and compares hashes in constant time (Config:83-91). `application` is
1-64 characters of `[A-Za-z0-9._-]` (Config:126-130), one key per application
(Config:102-104). `agent` is one of `claude`, `codex`, `agent` (Config:6,
99-101).

### 1.2 The App and its token

- There is one GitHub App per agent: `logan-shire-claude`, `-codex` and
  `-agent` (Config:3-6; README:5-8). The caller's key says which one acts
  (MCP:44; Tools:254).
- The token is an installation token **per owner, not per repository**:
  `agent-token token <agent> --owner <owner>`, run with a 60 s timeout
  (Tokens:26). The binary must be executable, or the call fails with "agent-token
  is not at <path> (the config's agentToken)" (Tokens:21-23). Its output must be
  one token of `[A-Za-z0-9_.-]`, else "agent-token printed something that is not
  a token for <agent>" (Tokens:31-35).
- Tokens are cached for 240 s per (agent, lowercased owner), and concurrent asks
  share one fetch (Tokens:46-79, maxAge Tokens:58). A 401 drops the token and
  retries once with a new one (GitHub:84-88; Tokens:82-85). git does the same on
  "Authentication failed", "Invalid username or token" or "403" (Git:151-154;
  Fetch:51-54).
- REST requests carry `Authorization: Bearer <token>`, `Accept` (default
  `application/vnd.github+json`), `X-GitHub-Api-Version: 2022-11-28` and
  `User-Agent: gh_mcp/0.1.0` (GitHub:171-180).
- git gets the token only from a one-off credential helper: username
  `x-access-token`, password from `$GH_MCP_TOKEN` in that one command's
  environment, given only for `https://github.com` (Git:193-200).

### 1.3 Protected refs

- **Never pushed:** `Policy.protectedBranches = ["main", "master"]` (Policy:25),
  plus the repository's live `default_branch` (Git:101-104). Both are compared
  case-insensitively (Rules:151; Git:102).
- **Tags are never pushed or created:** `refs/…` other than `refs/heads/…` is
  refused (Rules:145-147). So is a branch whose name is also a local tag
  (Git:72-74). No tag-creating API is in `Policy.writes`.

### 1.4 Constants that act as switches (none of them are configurable)

| What | Value | Where |
| --- | --- | --- |
| Merge methods | `squash` (default), `merge`, `rebase` | Policy:62; Merge:54, 182-183 |
| Repository flags read per method | `allow_squash_merge`, `allow_merge_commit`, `allow_rebase_merge` | Merge:72 |
| Check-run conclusions that pass | `success`, `skipped`, `neutral` | Merge:147; Actions:22 |
| Commit status that passes | `success` only | Merge:155-158 |
| Re-runnable events | `pull_request`, `push`, `workflow_dispatch` | Reruns:20 |
| Event never cancelled | `release` | Reruns:183 |
| Dispatch inputs | ≤10; name `^[A-Za-z0-9_-]{1,64}$`; value a string, ≤200 characters, no newline | Reruns:156-171 |
| Workflow argument | `^([A-Za-z0-9._-]+\.ya?ml\|[0-9]+)$` | Reruns:107 |
| CODEOWNERS locations | `.github/CODEOWNERS`, `CODEOWNERS`, `docs/CODEOWNERS` (first found wins) | CodeOwners:21 |
| Paging caps | check runs ≤10 pages (1000); PR files ≤30 pages (3000); reviews ≤10 pages | Merge:138; CodeOwners:126-127, 150 |
| GraphQL | exactly two mutation strings | Policy:93-96 |
| Artifact size cap | 2 GiB (`2 << 30`) | Artifacts:11 |
| Artifact destinations | under `/tmp` or `/private/tmp`, or inside a checkout of an allowed repository | Tools:148; Artifacts:71-85 |
| `repo_file` cap | 512 KiB | Releases:60 |
| `run_log` cap | 400 KB in total; `max_lines` 1-5000 (default 200) | Actions:139-142; Tools:332 |
| Redirects followed | ≤3, GET only, to `https://api.github.com/` only | GitHub:89-94 |

**For the proxy's data model**, the config could hold: allowed repository
patterns; protected branch names, plus the "default branch" flag; the rules per
operation (the table in §3); merge method set; conclusion sets; re-runnable
events; never-cancelled events; dispatch input limits; CODEOWNERS locations;
and the agent→App mapping.

---

## 2. The guards, tool by tool

### 2.1 gh_mcp's own surface (caller auth, transport)

None of these guard GitHub. The proxy covers them in its own way, since the
Runner knows which session is calling.

- **[A1]** The key is `API_KEY`/`API-KEY`/`X-API-Key` or `Authorization:
  Bearer` (MCP:134-146; header names are lowercased with `_` read as `-`,
  HTTP.swift:12-13). An unknown or missing key gets HTTP 401, JSON-RPC -32001
  "Unauthorized: send a key gh_mcp knows as API_KEY (or Authorization: Bearer)",
  and the refusal is logged (MCP:39-43).
- **[A2]** A non-local `Origin` gets 403 "Forbidden: requests from web pages
  are refused". Only 127.0.0.1, localhost or ::1 pass (MCP:34-36, 162-165).
- **[A3]** Only `POST /mcp`: another path gets 404, another method 405 with
  `Allow: POST` (MCP:26-33).
- **[A4]** It listens on 127.0.0.1 only (HTTP.swift:215). A body over 8 MiB gets
  413, a request head over 64 KiB gets 431 (HTTP.swift:82-126).
- **[A5]** `CLIENT_ID` is cleaned to ≤64 characters of `[A-Za-z0-9._:-]`
  (MCP:149-158). It is logged as `<client>@<application>` (Tools:127).
- **[A6]** One log line per call: ISO time, caller, tool, repo, outcome (≤300
  characters, redacted). Never a token, key or body (Log:6, 19-24; MCP:102).
- **[A7]** Token-shaped strings are redacted from every answer and log line:
  the prefixes `ghs_ ghp_ gho_ ghu_ ghr_ github_pat_ ghmcp_ x-access-token:`,
  followed by 8 or more token characters (Rules:168-201; Tools:257-264).

### 2.2 Request layer (Policy), applied to every REST/GraphQL request

- **[P1]** **GET** passes if its path is `/repos/{owner}/{repo}` or anything
  under it, for the tool's own repository (owner and name case-insensitive), or
  starts with `/repositories/` (a renamed repository's redirect, **for any
  id**). Anything else is refused with "GET <path> is outside <repo>"
  (Policy:109-114, 126-139). The `https://api.github.com` prefix and any query
  string are stripped first (Policy:107-108).
- **[P2]** **Any other method** must match one write template exactly: same
  number of segments, literal segments case-sensitive, `{owner}`/`{repo}`
  case-insensitive against the tool's repository, `{n}` all ASCII digits.
  Otherwise "<METHOD> <path> is not among the writes gh_mcp makes"
  (Policy:115-117, 126-139). So HEAD, DELETE and every unlisted write are
  refused.
- **[P3]** The body's top-level keys must be a subset of the template's fields,
  else "<METHOD> <path> never sends <sorted extra keys>" (Policy:118-120). No
  body counts as `{}`. *Gap:* a body that is not a JSON object has no keys and
  passes this check (Policy:119). gh_mcp builds every body itself, so this
  never happens there; the proxy must require an object.
- **[P4]** The value rules (`Policy.writes`, Policy:37-91):

| # | Method and path | Fields allowed | Value rule and refusal |
| --- | --- | --- | --- |
| W1 | `POST /repos/{o}/{r}/pulls` | title, head, base, body, draft | (none) (Policy:38) |
| W2 | `PATCH /repos/{o}/{r}/pulls/{n}` | title, body | (none) (Policy:39) |
| W3 | `POST /repos/{o}/{r}/pulls/{n}/comments/{n}/replies` | body | (none) (Policy:40) |
| W4 | `POST /repos/{o}/{r}/pulls/{n}/reviews` | body, event, commit_id | `event == "COMMENT"` (so a missing event is refused), else "a review is COMMENT only; approving and requesting changes are Logan's" (Policy:41-43) |
| W5 | `POST /repos/{o}/{r}/issues` | title, body, labels | (none) (Policy:44) |
| W6 | `PATCH /repos/{o}/{r}/issues/{n}` | title, body, labels | (none) (Policy:45) |
| W7 | `POST /repos/{o}/{r}/issues/{n}/comments` | body | (none) (Policy:46) |
| W8 | `POST /repos/{o}/{r}/releases` | tag_name, target_commitish, name, body, draft | `draft` is JSON `true`, else "a release is made as a draft only" (Policy:47-49) |
| W9 | `PATCH /repos/{o}/{r}/releases/{n}` | name, body, target_commitish, tag_name | (none). Never `draft`, `prerelease` or `make_latest`; the tool checks the release is a draft first (Policy:50-55) |
| W10 | `PUT /repos/{o}/{r}/pulls/{n}/merge` | merge_method, sha, commit_title, commit_message | `sha` is 40 or 64 hex digits, else "a merge names the head it checked (sha)". `merge_method` is in {squash, merge, rebase}, else "a merge names its method: squash, merge or rebase" (Policy:56-66, isSHA Policy:99-102) |
| W11 | `PUT /repos/{o}/{r}/pulls/{n}/update-branch` | expected_head_sha | SHA, else "an update names the head it expects (expected_head_sha)" (Policy:67-71) |
| W12 | `POST /repos/{o}/{r}/actions/runs/{n}/rerun` | (none) | no `enable_debug_logging` (Policy:72-77) |
| W13 | `POST /repos/{o}/{r}/actions/runs/{n}/rerun-failed-jobs` | (none) | (Policy:78) |
| W14 | `POST /repos/{o}/{r}/actions/runs/{n}/cancel` | (none) | (Policy:79). Never `/force-cancel` |
| W15 | `POST /repos/{o}/{r}/actions/workflows/{n}/dispatches` | ref, inputs | workflow by **numeric id**; `ref` a non-empty string not starting `refs/`, else "a dispatch names a branch (ref)" (Policy:80-85) |
| W16 | `POST /graphql` | query, variables | `query` byte-equal to one of the two strings in Policy:94-95, else "the only GraphQL gh_mcp sends is ready-for-review and back to draft" (Policy:86-90) |

  The two GraphQL strings, exactly:
  `mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { number isDraft } } }`
  and the same with `convertPullRequestToDraft`.

- **[P5]** Redirects: within `https://api.github.com/` they are followed only
  for GET, at most 3 times, with the token, and each hop passes P1 again
  (GitHub:89-94, 81). The transport itself never follows redirects (NoRedirects,
  GitHub:142-143, 240-256). A redirect off the API (logs, artifacts) is fetched
  **without** the token, https only (GitHub:112-122, 184-192). The transport
  refuses any URL whose host isn't `api.github.com`: "Not a GitHub API URL: …"
  (GitHub:168-170).
- **[P6]** `Policy.never`, the list of what goes through Logan (Policy:11-21;
  README:43-59):
  1. merge any way but pr_merge's: into anything but the default branch, from a
     fork, before GitHub's rules and every check pass, bypassing them (admin),
     or by GraphQL;
  2. close or reopen a pull request or issue;
  3. approve or request changes (reviews are COMMENT only);
  4. delete anything: branches, tags, comments, reviews, releases, issues,
     files;
  5. push main, master, the default branch or a tag; force without a lease;
  6. create a tag, publish a release, or edit a published one;
  7. change settings, collaborators, branch protection, rulesets, webhooks,
     deploy keys, secrets, variables or environments;
  8. re-run, dispatch or cancel any way but run_rerun's, run_dispatch's and
     run_cancel's (no old commit's run, no release or schedule re-run, no
     dispatch on a tag or another repository's branch, no release cancel, no
     force-cancel); delete runs or logs, approve a fork's runs, or change
     Actions' settings;
  9. touch a repository outside the configured ones.

### 2.3 Repository and argument checks (every tool)

- **[R1]** `repo` parses as `owner/name`: the owner is 1-39 characters of
  `[A-Za-z0-9-]`, the name 1-100 characters of `[A-Za-z0-9._-]` and not `.` or
  `..` (Rules:35-46, 79-86). Else Invalid "repo is owner/name, e.g.
  AttilaTheFun/oss: <text>" (Rules:109).
- **[R2]** `repo` is allowed, else Refused "<repo> is not among the
  repositories gh_mcp allows (<patterns, comma-separated>)" (Rules:111-113).
  The proxy departs from gh_mcp here (Logan, 9 Nov 2026): a *read* of a
  repository not allowed (git's `info/refs?service=git-upload-pack` and
  `git-upload-pack`, an LFS download, a REST GET or HEAD under
  `/repos/<owner>/<name>`) goes on anonymously, with no token
  (`GateDecision.anonymous`); every other request of one is Refused as R2
  says.
- **[T1-T7]** Arguments (Tools:56-106), each an Invalid:
  - not an object: "<tool>'s arguments are an object";
  - an unknown key: "<tool> takes no argument <key> (it takes …)";
  - a missing required one: "<tool> needs <name>";
  - an empty string where not allowed: "<name> is empty";
  - a value outside its choices: "<name> is one of …: <v>";
  - an integer out of range: "<name> is between <lo> and <hi>: <v>".
    `number` is 1…2³¹-1 and `run_id` 1…Int.max (Tools:46-47). Integers may come
    as digit strings and booleans as "true"/"false".
- Errors come back as one line, `Invalid: …`, `Refused: …` or `Failed: …`
  (Rules:12-18).

### 2.4 Reads

All of these are GETs that P1 allows. The tool-level checks below only
validate arguments; none of them is a security guard the proxy needs.

| Tool | GitHub requests | Argument checks |
| --- | --- | --- |
| `pr_view` | `GET /repos/{o}/{r}/pulls/{n}`; `GET …/pulls/{n}/reviews?per_page=100` (PullRequests:63-64) | It adds a mergeability note when `mergeable` is null on an open PR (PullRequests:82-84) |
| `pr_list` | `GET …/pulls?state=<open\|closed\|all>&per_page=50[&head=<owner>:<branch>]` (PullRequests:89-95) | `head` goes through [PC1]/[PC2] |
| `checks` | `GET …/commits/{ref}/check-runs?per_page=100`; `GET …/commits/{ref}/status?per_page=100` (Actions:9-12) | `ref` must be a valid ref name, else "ref is a commit SHA, branch or tag: <ref>" (Actions:7). A 403/404 on statuses is tolerated and noted (Actions:12-16, 45-47). Tallies: a check run passes if completed with success/neutral/skipped; a status passes on `success`, is pending on `pending`, else failed (Actions:18-37) |
| `runs` | `GET …/actions/runs?per_page=<1-50, 10>[&branch][&event]` (Actions:60-73) | branch must be valid, else "branch is not a branch name: <b>" (Actions:64); event is letters and `_`, else "event is a word like push: <e>" (Actions:68) |
| `run_view` | `GET …/actions/runs/{id}`, `…/runs/{id}/jobs?per_page=100`, `…/runs/{id}/artifacts?per_page=100` (Actions:76-93) | |
| `run_log` | `…/runs/{id}/jobs`, then `GET …/actions/jobs/{job}/logs` → redirect fetched without the token (Actions:129-132) | A job that matches nothing: "run <id> has no job <job> (its jobs: …)" (Actions:115). 400 KB cap (Actions:139-142) |
| `release_list` | `GET …/releases?per_page=30` (Releases:56) | |
| `repo_file` | `GET …/contents/<encoded path>[?ref=]`, with `Accept: application/vnd.github.raw` (Releases:77) | path relative, no empty, `.` or `..` segment, no control characters, else "path is a path in the repository, like docs/README.md: <p>" (Releases:65-69); ref valid (Releases:71-74); 404 → Failed "<repo> has no <path>[ at <ref>]" (Releases:79-81); folders listed, binaries summarised, 512 KiB cap (Releases:85-98) |
| `pr_review_comments` | `GET …/pulls/{n}/comments?per_page=100` (Collaboration:28) | |
| `pr_files` | `GET …/pulls/{n}/files?per_page=100` (Collaboration:41) | |
| `commits` | `GET …/commits?per_page=<1-100, 20>[&sha=ref][&path]` (Collaboration:60-66, 233) | ref valid (Collaboration:17-21) |
| `commit_view` | `GET …/commits/{ref}` (Collaboration:72) | |
| `compare` | `GET …/compare/{base}...{head}` (Collaboration:83) | |
| `branches` | `GET …/branches?per_page=100` (Collaboration:95) | |
| `issues_list` | `GET …/issues?state&per_page=50[&labels]`, with PRs filtered out (Collaboration:110-116) | |
| `issue_view` | `GET …/issues/{n}`, `…/issues/{n}/comments?per_page=100` (Collaboration:122-123) | |

### 2.5 Collaboration writes

**`pr_create`.** `POST /repos/{o}/{r}/pulls` with `{title, head, base, body
(default ""), draft (default false)}` (PullRequests:25-38).
- **[PC1]** For `head` and `base`: if the value is `owner:branch`, the owner
  must equal the repository's owner (case-insensitive), else Refused
  "<head|base> is a branch of <repo owner>'s: <text>". The prefix is stripped
  before sending (PullRequests:13-20).
- **[PC2]** The branch is a valid ref name, else Invalid "<arg> is not a branch
  name: <text>" (PullRequests:21).
- **[PC3]** `head != base`, else Invalid "head and base are the same branch:
  <b>" (PullRequests:29).
- It doesn't require the base to be the default branch, and doesn't check that
  the head exists (GitHub answers 422).

**`pr_edit`.** `PATCH …/pulls/{n}` with `{title?, body?}` (PullRequests:40-49).
- **[PE1]** At least one is given, else Invalid "pr_edit changes a title or a
  body: give one" (PullRequests:45).
- It never sends state, base or reviewers (Tools:295; W2).

**`pr_comment`.** `POST …/issues/{n}/comments {body}` (PullRequests:51-58). The
body is required and non-empty.

**`pr_review_comment_reply`.** `POST …/pulls/{n}/comments/{comment_id}/replies
{body}` (Collaboration:136-142).

**`pr_review`.**
- **[RV1]** `POST …/pulls/{n}/reviews {body, event: "COMMENT"}`; the event is
  fixed (Collaboration:145-151) and W4 enforces it.

**`issue_create`.** `POST …/issues {title, body, labels?}`. Labels are the
comma-separated argument, trimmed, with empty entries dropped
(Collaboration:12-15, 153-159).

**`issue_comment`.** `POST …/issues/{n}/comments {body}` (Collaboration:161-167).

**`issue_edit`.** `PATCH …/issues/{n} {title?, body?, labels?}`
(Collaboration:170-179).
- **[IE1]** At least one is given, else Invalid "issue_edit changes a title,
  body or labels: give one" (Collaboration:176).
- **[IE2]** There is no `state` argument (closing is Logan's: Tools:272;
  Tests:404). `labels: ""` sends `[]`, which clears them.

**`pr_ready_for_review`** (Collaboration:183-209).
- `GET …/pulls/{n}` first. It needs `node_id`, else Failed "GitHub gave pull
  request <n> no node id" (Collaboration:188).
- **[RD1]** It acts only if the PR isn't already in the asked state (`draft ==
  ready`). Otherwise it answers success with no write (Collaboration:191).
- `POST /graphql {query: readyMutations[ready ? 0 : 1], variables: {id}}`
  (Collaboration:192-193; W16).
- **[RD2]** GraphQL `errors[0].message` → Failed "GitHub refused: <message>"
  (Collaboration:194-196).
- **[RD3]** It verifies the result: if `data.<field>.pullRequest.isDraft !=
  !ready`, it GETs the PR again. If that still disagrees: Failed "GitHub
  answered but pull request #<n> is still <a draft|ready for review>: <result>"
  (Collaboration:199-206).

### 2.6 Releases

**`release_draft`** (Releases:10-26).
- **[RL1]** `tag` is a valid ref name, else Invalid "tag is not a name git
  would take: <tag>" (Releases:13).
- **[RL2]** `target` is a valid ref name, else Invalid "target is a branch or
  commit SHA: <target>" (Releases:14).
- **[RL3]** `POST …/releases {tag_name, target_commitish, name, body, draft:
  true}`. `draft` is always true (Releases:15-21; W8).
- **[RL4]** The answer must say `draft: true`, else Failed "GitHub made release
  <id> but did not say it is a draft; check it" (Releases:22-24).

**`release_edit_draft`** (Releases:33-52).
- **[RL5]** At least one of title, body or target, else Invalid
  "release_edit_draft changes a title, body or target: give one" (Releases:43).
  `target` must be valid (Releases:40).
- **[RL6]** `GET …/releases/{id}` first. If it isn't `draft == true`: Refused
  "release <id> (<tag>) is published; gh_mcp edits drafts only"
  (Releases:44-48).
- **[RL7]** It sends the draft's current `tag_name` back unchanged, because
  GitHub resets a draft's tag to `untagged-…` when a PATCH leaves it out
  (Releases:28-32, 49). Then `PATCH …/releases/{id} {name?, body?,
  target_commitish?, tag_name}` (Releases:50).
- It never sends `draft`, `prerelease` or `make_latest` (W9; Tests:354-355).

### 2.7 Merging

`openSameRepositoryPull` (Merge:12-27) is shared by `pr_update_branch` and
`pr_merge`. It starts with `GET …/pulls/{n}`.
- **[M1]** `merged == true` → Refused "pull request #<n> is already merged"
  (Merge:14).
- **[M2]** `state != "open"` → Refused "pull request #<n> is <state|not open>"
  (Merge:15-17).
- **[M3]** `head.repo.full_name` must equal `base.repo.full_name`
  (case-insensitive; a missing head repo counts as deleted), else Refused "pull
  request #<n>'s head is in <head repo>|in a deleted repository, not a branch of
  <base repo>" (Merge:18-22).
- **[M4]** `head.sha` must be a SHA, else Failed "GitHub gave pull request #<n>
  no head SHA" (Merge:23-25).

**`pr_update_branch`** (Merge:29-49). It doesn't check for drafts.
- **[U1]** [M1]-[M4], then `PUT …/pulls/{n}/update-branch
  {expected_head_sha: <head.sha read in M4>}` (Merge:35-36; W11). There is no
  `update_method`, so GitHub merges rather than rebases (Tests:348).
- **[U2]** A 422 (the head moved, or nothing to update) is Refused with GitHub's
  description; any other non-2xx is Failed (Merge:37-43).
- It answers the new head if GitHub gave one, else "updating its branch …; its
  checks run again on the new head" (Merge:44-48).

**`pr_merge`** (Merge:51-123). The checks run in this order, and the first
failure is the answer.
- **[M5]** If `method == rebase` and a title or message is given: Invalid "a
  rebase makes no merge commit: title and message are for squash or merge"
  (Merge:56-58). The method defaults to `squash` (Merge:54).
- [M1]-[M4] (Merge:62).
- **[M6]** `draft == true` → Refused "pull request #<n> is a draft" (Merge:63).
  This comes before the mergeable_state check (Tests:595).
- **[M7]** `GET /repos/{o}/{r}`. No `default_branch` is Failed "GitHub gave
  <repo> no default branch" (Merge:64-67).
- **[M8]** `base.ref == default_branch` (an exact, case-sensitive comparison),
  else Refused "pull request #<n> is into <base>, not <repo>'s default branch
  <default>" (Merge:68-71).
- **[M9]** The repository allows the method: `allow_squash_merge`,
  `allow_merge_commit` or `allow_rebase_merge`. Only an explicit `false`
  refuses: "<repo> doesn't allow <method> merges" (Merge:72-75).
- **[M10]** `mergeable_state` (a missing value counts as `unknown`)
  (Merge:79-89):
  - `clean` passes;
  - `behind` → Refused "pull request #<n> is behind <base>: call
    pr_update_branch, then merge once its checks pass again";
  - `unknown` → Refused "GitHub is still working out whether pull request #<n>
    can be merged; ask again in a few seconds";
  - anything else (`blocked`, `dirty`, `unstable`, `has_hooks`, `draft`, …) →
    Refused "pull request #<n> isn't clean to merge: GitHub's mergeable_state is
    <state>".
- **[M11]** The checks on the head SHA (Merge:94-96, 127-163). Any failure is
  Refused "pull request #<n>'s head <sha[0..12]>: <reason>". The reasons:
  - It pages `GET …/commits/{sha}/check-runs?per_page=100&page=k` until a page
    has fewer than 100 or the `total_count` is reached. More than 10 pages:
    "more than 1000 check runs; too many to check" (Merge:128-139).
  - No check runs at all: "it has no check runs: nothing says CI passed"
    (Merge:140).
  - Every run must be `status == completed`, else "<name> is <status>"
    (Merge:143-145). A re-run in progress therefore shows as `queued` and holds
    the merge (Tests:607-608).
  - Every conclusion must be success, skipped or neutral, else "<name> concluded
    <conclusion>" (Merge:146-147).
  - `GET …/commits/{sha}/status?per_page=100`: on 2xx, every `statuses[].state`
    must be `success`, else "status <context> is <state>" (Merge:151-158). A 403
    or 404 is ignored, so check runs alone decide; any other status is Failed
    (Merge:159-161).
- **[M12]** CODEOWNERS (Merge:100-102; CodeOwners:110-184). Refused "pull
  request #<n>: <reason>".
  - The file comes from the **base branch**: for each of `.github/CODEOWNERS`,
    `CODEOWNERS` and `docs/CODEOWNERS`, `GET …/contents/<p>?ref=<base>`. A 404
    moves on to the next; the first other answer is used. One that can't be
    decoded is Failed "<repo>'s <path> can't be read: …", so it refuses rather
    than guess. No file at all means no owned paths (CodeOwners:169-184).
  - Parsing: one rule per line. Blank lines and `#` comments are skipped.
    Fields split on spaces and tabs; the first is the pattern. Owners are the
    following tokens up to an inline `#`, kept if they start with `@` or contain
    `@`. A rule with no owners un-owns what it matches. A pattern that fails to
    compile is **silently dropped** (CodeOwners:26-39).
  - Matching follows gitignore's rules:
    - a leading or inner `/` anchors the pattern at the root, otherwise it
      matches at any depth;
    - a trailing `/` matches folders only;
    - `*` and `?` don't cross `/`, `**/` crosses folders, `**` matches anything;
    - `\` escapes the next character;
    - `*`, `**` or an empty pattern matches everything.

    A path counts as matched if the file or any folder above it matches; a
    folder-only rule tests only the folders. **The last matching rule wins**
    (CodeOwners:43-57, 66-103).
  - The changed files come from paging `GET …/pulls/{n}/files?per_page=100`;
    each entry's `filename` **and** `previous_filename` count. More than 30
    pages: "it changes more than 3000 files, too many to check against
    CODEOWNERS" (CodeOwners:114-128).
  - If any changed path has owners, it pages `GET
    …/pulls/{n}/reviews?per_page=100` (≤10 pages) and keeps each login's
    (lowercased) **latest** review that is neither `COMMENTED` nor `PENDING`,
    with its `commit_id` (CodeOwners:139-152).
  - An owned path is approved only if one of its owners is a plain `@user` (no
    `/`, so not a team, and not an email), whose latest review is `APPROVED`
    with `commit_id == head` (CodeOwners:153-160).
  - Otherwise: "it changes protected files (<first 5 paths>[ and N more]) and
    <owners, sorted> hasn't approved its head: those need their review"
    (CodeOwners:161-164).
- **[M13]** It sends `PUT …/pulls/{n}/merge {merge_method, sha: head,
  commit_title?, commit_message?}` (Merge:105-109; W10). The SHA pins the
  head, so a push in between makes GitHub refuse:
  - 409 → Refused "pull request #<n>'s head changed since it was checked:
    <GitHub's description>";
  - 405 or 422 → Refused with GitHub's description;
  - anything else → Failed (Merge:110-117).
- **[M14]** The answer must have `merged == true` and a `sha`, else Failed
  "GitHub answered the merge of #<n> without merging it: …" (Merge:118-121).
  Success: "Pull request #<n> of <repo> is merged into <base> (<method>):
  <sha>." (Merge:122).
- It never deletes the head branch; the repository's own setting does that
  (README:93-96).

### 2.8 Actions

`run` (Reruns:23-27) starts with `GET …/actions/runs/{id}`. A run with no
SHA in `head_sha` is Failed "GitHub gave run <id> no head SHA". Runs are named
in messages as "run <id> (<workflow>[ on <branch>])" (Reruns:29-33).

**`run_rerun`** (Reruns:35-101). `failed_only` defaults to true (Reruns:38).
- **[RR1]** `status == completed`, else Refused "<name> is <status>, not
  completed: only a finished run is run again" (Reruns:43-44).
- **[RR2]** `event` is pull_request, push or workflow_dispatch, else Refused
  "<name> is a <event> run: only pull_request, push and workflow_dispatch runs
  are run again" (Reruns:48-51).
- **[RR3]** `head_repository.full_name` equals the repository
  (case-insensitive), else Refused "<name>'s commit is in <repo>|in a deleted
  repository, not a branch of <repo>" (Reruns:54-57).
- **[RR4]** `head_branch` is a valid ref, else Failed "GitHub gave <name> no
  branch" (Reruns:58-60).
- **[RR5]** For a pull_request run: `GET
  …/pulls?head=<owner>:<branch>&state=open&per_page=10`. The current head is the
  head SHA that equals the run's, else the first PR's head. No open PR: Refused
  "<name>: no pull request from <branch> is open, so its runs aren't run again"
  (Reruns:66-73).
- **[RR6]** For push and workflow_dispatch: `GET …/git/ref/heads/<branch>`, with
  each segment percent-encoded. A 404 is Refused "<name>: <branch> is no longer
  a branch of <repo>"; another failure is Failed (Reruns:74-82).
- **[RR7]** The current head must equal the run's `head_sha`, else Refused
  "<name> is of <sha12>, but <branch>'s head is now <cur12>: only the head's
  runs are run again" (Reruns:83-85).
- **[RR8]** With `failed_only`, a conclusion of success, skipped or neutral is
  Refused "<name> concluded <c>: no job failed (failed_only: false runs every
  job again)" (Reruns:89-92).
- **[RR9]** It sends `POST …/actions/runs/{id}/rerun-failed-jobs` (or `/rerun`
  when `failed_only` is false) with **no body** (Reruns:93-95; W12/W13). A 403
  gets the hint "(the GitHub App needs Actions: Read and write)" (Reruns:195-199).

**`run_dispatch`** (Reruns:104-153).
- **[D1]** `workflow` matches `^([A-Za-z0-9._-]+\.ya?ml|[0-9]+)$`, else Invalid
  "workflow is a file name in .github/workflows (ci.yml) or a workflow's id: <w>"
  (Reruns:107-109).
- **[D2]** `ref` is a valid ref and doesn't start `refs/`, else Invalid "ref is
  a branch's name: <ref>" (Reruns:111).
- **[D3]** inputs (Reruns:156-171), each an Invalid:
  - absent or blank means none;
  - it must be a JSON object, else `inputs is a JSON object of strings, like
    {"kind": "quick"}`;
  - more than 10: "at most 10 inputs";
  - a name not matching `^[A-Za-z0-9_-]{1,64}$`: "an input's name is letters,
    digits, _ and -: <k>";
  - a value that isn't a string of ≤200 characters with no newline: "input <k>
    is one line of at most 200 characters".
- **[D4]** `GET …/actions/workflows/<workflow>` resolves the workflow; no `id`
  is Failed (Reruns:115-116).
- **[D5]** The workflow's `state == "active"`, else Refused "<title> is
  <state>: it isn't dispatched" (Reruns:118-120).
- **[D6]** `GET …/git/ref/heads/<ref>`: a 404 is Refused "<ref> is not a branch
  of <repo>". Its `object.sha` is the commit the run will be of
  (Reruns:122-128). This is what keeps out a tag's short name, which W15 alone
  doesn't.
- **[D7]** It sends `POST …/actions/workflows/<numeric id>/dispatches {ref,
  inputs?}` (Reruns:130-133; W15). A 422 is Refused "<GitHub's description>
  (does <workflow> on <ref> declare workflow_dispatch, with these inputs?)";
  other failures as in RR9 (Reruns:134-137).
- **[D8]** It finds the run it made: up to 10 tries 2 s apart of `GET
  …/actions/workflows/<id>/runs?event=workflow_dispatch&branch=<ref>&per_page=5`,
  taking the first run with `head_sha == sha` and `created_at ≥ asked - 10 s`.
  The answer is "<title> dispatched on <ref> at <sha12>[, inputs k=v …]: run
  <id>, <url>.", or, when no run turns up, "… GitHub hasn't listed its run yet:
  runs (event workflow_dispatch, branch <ref>) shows it." (Reruns:138-152).
- `main` is allowed (README:117-119; Reruns:214).

**`run_cancel`** (Reruns:173-192).
- **[C1]** `status != completed`, else Refused "<name> is already completed
  (<conclusion>): nothing to cancel" (Reruns:178-181).
- **[C2]** `event != release`, else Refused "<name> is a release's run: its
  publishing must finish" (Reruns:182-183).
- **[C3]** It sends `POST …/actions/runs/{id}/cancel` with no body (W14). A 409
  is Refused with GitHub's description, other failures as in RR9
  (Reruns:184-190).
- **[C4]** Never `/force-cancel`, which isn't in Policy (Tests:361).

**`artifact_download`** (Artifacts:13-43, destination Artifacts:49-87, unzip
Artifacts:94-126).
- **[AD1]** `path` is absolute, else Invalid "path is absolute" (Artifacts:50).
- **[AD2]** It has no `.` or `..` component, else Invalid "path has no . or ..
  in it: <p>" (Artifacts:52).
- **[AD3]** It has no `.git` component, checked again after resolving symbolic
  links, else Refused "artifacts never go into a .git folder"
  (Artifacts:53, 70).
- **[AD4]** The nearest existing ancestor is a folder, else Invalid "<x> is not
  a folder" (Artifacts:61-64). An existing target must be empty, else Refused
  "<path> is not empty; name a folder that does not exist yet"
  (Artifacts:65-67).
- **[AD5]** After realpath the target is under `/tmp` or `/private/tmp`
  (Artifacts:71-73). Otherwise it must be inside a git toplevel, else Refused
  "<path> is not in a checkout of an allowed repository, nor under /tmp", and
  some `remote.*.url` of that checkout must be an allowed repository, else
  Refused "<top> is not a checkout of an allowed repository" (Artifacts:75-85).
- **[AD6]** It finds the artifact with `GET
  …/actions/runs/{id}/artifacts?name=<n>&per_page=100`. Missing: Failed "run
  <id> has no artifact <n> (its artifacts: …)". Expired: Failed "artifact <n>
  of run <id> has expired" (Artifacts:19-26).
- **[AD7]** `size_in_bytes ≤ 2 GiB`, else Refused "artifact <n> is <size>
  bytes; gh_mcp downloads at most 2147483648" (Artifacts:27-29).
- **[AD8]** `GET …/actions/artifacts/{id}/zip` must answer a redirect, and the
  Location is downloaded **without the token** (Artifacts:30-39;
  GitHub:191-216).
- **[AD9]** The zip's entries must not be absolute, contain `\` or contain
  `..`, else Refused "the artifact has an entry outside its folder (<name>); not
  unzipped" (Artifacts:98-102).
- **[AD10]** No symbolic links, checked in the listing and again after
  unzipping, else Refused "the artifact has a symbolic link in it[ (<item>)];
  not unzipped". It unzips into a scratch folder and moves the files in
  (Artifacts:103-124).

### 2.9 git

**`git_push`** (Git:56-168).
- **[GP1]** `path` is absolute, else Invalid "path is absolute: the checkout's
  path on this Mac" (Git:59). It must be a folder and a checkout, else Invalid
  "there is no folder at <path> on this Mac" or "<path> is not a git checkout:
  …" (Git:61-71).
- **[GP2]** `Refs.pushableBranch` (Rules:141-155):
  - a `refs/heads/` prefix is stripped;
  - any other `refs/…` is Refused "only branches are pushed (refs/heads/…),
    never tags or other refs: <input>";
  - a name git's check-ref-format rules wouldn't take (≤255 bytes, Rules:124-137)
    or `HEAD` is Invalid "not a branch name git would take: <input>";
  - `main` or `master`, case-insensitive, is Refused "<name> is never pushed;
    push a branch of your own and open a pull request".
- **[GP3]** If `refs/tags/<branch>` exists in the checkout: Refused "<branch>
  is a tag in <path>; tags are never pushed" (Git:72-74).
- **[GP4]** `refs/heads/<branch>^{commit}` must exist, else Invalid "<path> has
  no branch <branch>" (Git:75-77).
- **[GP5]** The remote is the first of `branch.<b>.pushRemote`,
  `remote.pushDefault`, `branch.<b>.remote` or `origin`. Its name must be valid,
  else Refused "<branch>'s remote is <remote>, not a remote gh_mcp pushes to"
  (Git:81-88).
- **[GP6]** It reads `remote.<r>.pushurl`, falling back to `.url`. None: Invalid
  "<path> has no remote <r>" (Git:89-93).
- **[GP7]** The URL must name a GitHub repository (`https|http|ssh|git://`, an
  optional `user@`, host `github.com`, or scp-like `[user@]github.com:O/N`, with
  `.git` and trailing `/` stripped: Rules:50-75), else Refused "remote <r>
  (<url>) is not a GitHub repository" (Git:94-96).
- **[GP8]** That repository must be allowed (R2) (Git:98-100).
- **[GP9]** `GET /repos/{o}/{r}`: if `default_branch` equals the branch
  (case-insensitive), Refused "<branch> is <repo>'s default branch; push a
  branch of your own and open a pull request" (Git:101-104).
- **[GP10]** It forces only with `force_with_lease`, leased against the
  checkout's `refs/remotes/<remote>/<branch>`. If that ref is missing: Refused
  "force_with_lease leases against refs/remotes/<r>/<b>, what the checkout last
  saw of the branch, and the checkout has none" (Git:105-114).
- **[GP11]** The push itself (Git:126-200):
  - it runs in a fresh bare scratch repository whose `objects/info/alternates`
    points at the checkout's objects (and copies its `shallow` file);
  - git runs with `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`,
    `GIT_TERMINAL_PROMPT=0`, `core.hooksPath=/dev/null` and
    `core.fsmonitor=false`;
  - only gh_mcp's credential helper, only for `https://github.com`;
    `protocol.allow=never` except the URL's own scheme;
  - `push --porcelain --no-verify [--force-with-lease=refs/heads/<b>:<lease>]
    https://github.com/<o>/<r>.git <sha>:refs/heads/<b>`: **exactly one refspec**,
    to a URL gh_mcp built (Tools:147).
- **[GP12]** It retries once with a fresh token on an authentication failure
  (Git:151-154).
- **[GP13]** A rejected ref (`!` in porcelain) is Failed "GitHub refused the
  push of <b>: <reason>", with a hint: "…force_with_lease replaces it" for
  non-fast-forward or "fetch first", and "…the remote branch moved since the
  checkout last saw it; nothing was replaced" for stale info (Git:155-164).
- **[GP14]** After a push it updates the checkout's
  `refs/remotes/<remote>/<branch>`, so the next lease leases against this push
  (Git:118-120). The answer is "Pushed <b> to <repo> at <sha12> (a new
  branch|forced|already up to date|fast-forward)." (Git:121, 143-148).

**`git_fetch`** (Fetch:14-74; Git:204-232).
- **[GF1]** The same path and checkout checks as GP1 (Git:221-232). `remote`
  defaults to `origin` and must be a valid name, else Invalid "not a remote's
  name: <r>" (Git:205). Its `url` (not its pushurl) must be a GitHub repository
  and allowed (Git:207-217).
- **[GF2]** `refs` are branch names separated by spaces or commas; a
  `refs/heads/` prefix is stripped. Any other `refs/` or a `*` is Invalid "refs
  names branches (main, feature/x): <word>" (Fetch:21-28).
- **[GF3]** It fetches `+refs/heads/<b>:refs/remotes/<remote>/<b>` (all
  branches if none are named) with `--no-tags --no-write-fetch-head`, in a
  scratch repository seeded with the checkout's refs except the `*/HEAD`
  symbolic refs. It then fetches from that scratch repository into the
  checkout's tracking refs only, with `protocol.file.allow=always`, its hooks
  off and nothing written to its config. It never checks out or merges
  (Fetch:29-65).
- **[GF4]** "couldn't find remote ref" is Failed "<repo> has no branch <…>";
  authentication failures retry once (Fetch:50-59). The answer lists each moved
  ref (Fetch:66-73).

---

## 3. For the proxy: each allowed operation as HTTP

Ground rules that apply to every row:

- **Hosts.** Only `github.com`, `api.github.com` and `uploads.github.com` are
  opened (TLS by the Runner's CA). The token goes **only** to those three, and
  only after the request passes (P5; GitHub:142-143, 184-192). Redirect targets
  elsewhere get no token: log and artifact storage, `codeload.github.com`,
  `objects.githubusercontent.com`, `*.blob.core.windows.net`. Those are either
  passed through untouched or refused by egress, but never re-signed.
- **Repository.** It comes from the request: the path's `{o}/{r}` for REST and
  git, the resolved node for GraphQL. It must match the allow-list (R2).
  gh_mcp bound each request to the tool's `repo` argument; the proxy has to
  derive it.
- **Auth.** Strip any client `Authorization` header. The agent's `gh` needs
  `GH_TOKEN` set to *something*; use a placeholder that the proxy replaces. Add
  `Authorization: Bearer <token>` for REST and GraphQL. For git smart-HTTP use
  `Authorization: Basic base64("x-access-token:<token>")`, the same identity as
  Git:195. Retry once on a 401 with a fresh token from Keymaster (§1.2; GP12).
- **Path hygiene.** These matter because the proxy sees client-built paths,
  where gh_mcp built its own:
  - refuse `.` and `..` segments, empty segments (`//`), and percent-encoded
    `/`, `.` or `\` in path segments. Otherwise `GET
    /repos/AttilaTheFun/x/../../repos/other/y` would pass P1's prefix test;
  - match templates segment by segment as Policy:126-139 does: literals
    case-sensitive, `{o}`/`{r}` case-insensitive, `{n}` ASCII digits.
- **Bodies.** A write's body must be absent or a JSON **object**; this closes
  the P3 gap. Reject duplicate keys, since the proxy's parser and GitHub's
  could pick different ones (`{"draft":true,"draft":false}`). Reject a query
  string on any write (Policy:108 strips the query before matching, so gh_mcp
  never checked it). Reject request bodies over a cap, as A4 does at 8 MiB for
  JSON; git packs need a far larger cap or streaming.
- **Refusal wire formats.**
  - REST: HTTP 403 `{"message": "Refused: <reason>"}`. gh prints `HTTP 403:
    Refused: …`.
  - GraphQL: HTTP 200 `{"errors": [{"type": "FORBIDDEN", "message": "Refused:
    <reason>"}]}`. gh prints `GraphQL: Refused: …`.
  - git info/refs: HTTP 200 with the advertisement content type and one
    `ERR <reason>` pkt-line. git prints `fatal: remote error: <reason>`.
  - git receive-pack: a report-status (see G3).

  Reuse §2's wording so agents' existing habits still apply.

### 3.1 REST (api.github.com)

| Operation (gh_mcp tool) | What the client sends | What the proxy checks |
| --- | --- | --- |
| Reads (every read tool) | `GET`/`HEAD /repos/{o}/{r}[/…]`; gh, curl, `gh api` | P1: repository allowed. `GET /repositories/{id}/…` (P1 allows any id): allow only if the token is scoped to the allowed repositories (see §4.5). Off-API redirects: the client follows them; no token |
| Open a PR (`pr_create`) | `POST /repos/{o}/{r}/pulls {title, head, base, body, draft}` (`gh api`; `gh pr create` uses GraphQL, §3.2) | W1 fields (refuse `head_repo`, `issue`, `maintainer_can_modify`; the last is harmless, see §4); PC1 (a `head`/`base` with an `owner:` prefix must have the repository's owner); PC3 head≠base |
| Edit a PR (`pr_edit`) | `PATCH /repos/{o}/{r}/pulls/{n} {title?, body?}` | W2 fields only: refuse `state` (Tests:349), `base`, `maintainer_can_modify`. PE1 |
| Comment (`pr_comment`, `issue_comment`) | `POST /repos/{o}/{r}/issues/{n}/comments {body}` | W7 fields |
| Reply inline (`pr_review_comment_reply`) | `POST /repos/{o}/{r}/pulls/{n}/comments/{id}/replies {body}` | W3 fields |
| COMMENT review (`pr_review`) | `POST /repos/{o}/{r}/pulls/{n}/reviews {body, event:"COMMENT", commit_id?}` | W4: `event` present and exactly `COMMENT`; refuse `comments` (an inline array is not in W4) |
| Open an issue (`issue_create`) | `POST /repos/{o}/{r}/issues {title, body, labels}` | W5 fields: refuse `assignees`, `milestone`, `type` |
| Edit an issue (`issue_edit`) | `PATCH /repos/{o}/{r}/issues/{n} {title?, body?, labels?}` | W6 fields: refuse `state`, `state_reason`, `assignees`, `milestone` (Tests:350). This path takes PR numbers too, as it does in gh_mcp |
| Draft a release (`release_draft`) | `POST /repos/{o}/{r}/releases {tag_name, target_commitish, name, body, draft:true}`; `gh release create --draft` | W8: `draft` is JSON `true`. Refuse `prerelease`, `make_latest`, `generate_release_notes`, `discussion_category_name`. Optionally RL4 on the response. Without `--draft`, gh creates a draft, uploads assets, then sends `PATCH {draft:false}` (cli `pkg/cmd/release/create/http.go:183`): refused below |
| Edit a draft (`release_edit_draft`) | `PATCH /repos/{o}/{r}/releases/{id} {name?, body?, target_commitish?, tag_name?}`; `gh release edit` | W9 fields: refuse `draft` (Tests:354), `prerelease`, `make_latest` (Tests:355), `discussion_category_name`. **RL6: the proxy GETs the release first and refuses if it isn't a draft.** RL7: if `tag_name` is absent, inject the draft's current one. gh already sends it (cli `pkg/cmd/release/edit/edit.go:110-113`); curl wouldn't |
| Update branch (`pr_update_branch`) | `PUT /repos/{o}/{r}/pulls/{n}/update-branch {expected_head_sha}` | W11: SHA required; refuse `update_method` (Tests:348). M1-M3 by a proxy GET of the PR. The pinned head is GitHub's own check (U2) |
| Merge (`pr_merge`) | `PUT /repos/{o}/{r}/pulls/{n}/merge {merge_method, sha, commit_title?, commit_message?}` | W10: `sha` and `merge_method` required. Refuse `admin`, `delete_branch` and any other field (Tests:342-343). **Before forwarding, the proxy runs M1-M4, M6-M12 itself, and requires `sha == head.sha` it read** (M13). M5: refuse a title or message with `rebase`. Pass 405, 409 and 422 back as refusals |
| Re-run (`run_rerun`) | `POST /repos/{o}/{r}/actions/runs/{id}/rerun-failed-jobs` or `…/rerun`, with no body; `gh run rerun [--failed]` (cli `pkg/cmd/run/rerun/rerun.go:190-213`) | W12/W13: body absent or `{}`. Refuse `enable_debug_logging` (`gh run rerun --debug` sends it, rerun.go:243-255; Tests:359-360). **RR1-RR8 by proxy GETs** (the run, then the PR list or the branch ref). RR8 applies only to `rerun-failed-jobs`. `POST …/actions/jobs/{id}/rerun` (`gh run rerun --job`) is refused (Tests:363); §4 has an option |
| Cancel (`run_cancel`) | `POST /repos/{o}/{r}/actions/runs/{id}/cancel`, no body; `gh run cancel` | W14: no body. **C1-C2 by a proxy GET of the run.** Refuse `/force-cancel` (Tests:361) |
| Dispatch (`run_dispatch`) | `POST /repos/{o}/{r}/actions/workflows/{id}/dispatches {ref, inputs, return_run_details?}`; `gh workflow run` sends the numeric id and adds `return_run_details: true` (cli `pkg/cmd/workflow/run/run.go:322-338`) | W15: `{id}` numeric (Tests:369); `ref` non-empty and not `refs/…` (Tests:370); D3 inputs. **D5: the proxy GETs `/actions/workflows/{id}`, which must be `active`. D6: it GETs `/git/ref/heads/<ref>`, which must be 200.** `return_run_details` is refused by gh_mcp (Tests:371) but should be **allowed** here; it gives back D8's answer (§4.2) |
| Artifacts and logs (`artifact_download`, `run_log`) | `GET …/actions/runs/{id}/artifacts`, `GET …/actions/artifacts/{id}/zip` → 302; `GET …/actions/jobs/{id}/logs` or `…/runs/{id}/logs` → 302; `gh run download`, `gh run view --log` | P1 (reads). The client follows the 302 to storage, which must get no token (P5, AD8). AD1-AD10 are local and can't be enforced here (§4.3) |
| (none: refused) | `POST /repos/{o}/{r}/merges` (Tests:346); `DELETE` anything (Tests:356-357, 364-365); `POST /repos/{o}/{r}/git/refs`, which would create a tag or branch (Tests:358); `PATCH /repos/{o}/{r}/git/refs/…`; `PUT …/contents/…` (a commit by API); `…/actions/runs/{id}/approve` (Tests:362); `PUT …/actions/permissions` (Tests:366); `PUT …/branches/{b}/protection` (Tests:372); `PUT …/actions/secrets/…` (Tests:373); `PATCH /repos/{o}/{r}` (Tests:374); rulesets, hooks, keys, environments, collaborators, variables; `POST …/pulls/{n}/requested_reviewers`; `POST …/issues/{n}/labels`; `PUT …/issues/{n}/lock`; `POST …/releases/generate-notes`; and anything for another repository (Tests:345, 367, 376-377) | Default deny (P2) |

### 3.2 GraphQL (`POST https://api.github.com/graphql`)

gh_mcp allows exactly two byte-identical mutation strings (W16). That can't be
ported: gh builds its documents with githubv4, so `gh pr ready` sends something
like `mutation PullRequestReadyForReview($input:MarkPullRequestReadyForReviewInput!){markPullRequestReadyForReview(input: $input){…}}`.
gh also uses GraphQL for most PR and issue writes, and for nearly all of its
reads. The proxy must:

1. **Parse** the document. Body fields: `query`, `variables`, and
   `operationName`, which gh can send and Policy:88 would refuse. Select the
   operation by `operationName`, or take the single one. Reject documents with
   several operations unless all are queries. Reject `subscription`.
2. Let a `query` operation through as a read, under the scope caveat in §4.5.
3. For a `mutation`, check **every root field** after resolving aliases (a
   mutation may carry several root fields, run in order). Fragments can't hold
   mutation root fields, but variables must be substituted into `input:` before
   it is checked. Deny any field not in the allow-list.
4. **Resolve each global node id** in the input to its repository with a
   proxy-side query: `node(id:){… on PullRequest{repository{nameWithOwner}}
   … on Issue{…} … on Repository{nameWithOwner}}`. Then apply R2.

| Mutation (gh command) | gh_mcp equivalent | Allowed input fields and checks |
| --- | --- | --- |
| `markPullRequestReadyForReview` (`gh pr ready`) | W16 / pr_ready_for_review | `pullRequestId` → allowed repository. (RD1 and RD3, the no-op and the read-back, are client-side and lost; §4.2) |
| `convertPullRequestToDraft` (`gh pr ready --undo`) | W16 | as above |
| `createPullRequest` (`gh pr create`; cli `api/queries_pr.go:490-510` sends `repositoryId, title, body, draft, baseRefName, headRefName, maintainerCanModify`) | W1 | `repositoryId` → allowed repository; `headRepositoryId` absent or the same repository; `headRefName` without an `owner:` prefix, or with the repository's owner (PC1); head≠base (PC3). `maintainerCanModify` is a field W1 refuses, but **gh always sends it**, so it has to be allowed (harmless on a same-repo PR). Refuse `issueId` |
| `updatePullRequest` (`gh pr edit`; cli `pkg/cmd/pr/shared/editable_http.go:117-128`) | W2 | `pullRequestId`, `title`, `body` only. Refuse `baseRefName`, `state` (closing), `assigneeIds`, `labelIds`, `milestoneId`, `projectIds`, `maintainerCanModify`. gh's `pr create` with `--assignee`/`--label`/`--milestone`/`--project` follows up with `updatePullRequest` (queries_pr.go:539-540), which is refused |
| `addComment` (`gh pr comment`, `gh issue comment`; cli `api/queries_comments.go:57-64`) | W7 | `subjectId` → an Issue or PullRequest in an allowed repository; `body` |
| `addPullRequestReview` (`gh pr review --comment`; cli `api/queries_pr_review.go:253-268`) | W4 | `pullRequestId`, `body`, `event: COMMENT`, `commitOID`. **Refuse `APPROVE` and `REQUEST_CHANGES`** (`gh pr review --approve/--request-changes`). Refuse a missing `event` (it would create a PENDING review W4 doesn't allow), and refuse `threads`/`comments` |
| `submitPullRequestReview` | W4 | only `event: COMMENT` |
| `addPullRequestReviewThreadReply` | W3 | `pullRequestReviewThreadId` → allowed repository; `body` |
| `createIssue` (`gh issue create`; cli `api/queries_issue.go:328`) | W5 | `repositoryId`, `title`, `body`, `labelIds`. Refuse `assigneeIds`, `milestoneId`, `projectIds`, `issueTypeId`, `parentIssueId` |
| `updateIssue` (`gh issue edit`; editable_http.go:131-138) | W6 | `id`, `title`, `body`, `labelIds`. Refuse **`state`**, `assigneeIds`, `milestoneId`, `projectIds` |
| `addLabelsToLabelable` / `removeLabelsFromLabelable` (`gh issue/pr edit --add-label/--remove-label`; editable_http.go:153-178) | W6's `labels` (labels may be replaced) | `labelableId` → an Issue or PR in an allowed repository. Optional; without it, `--add-label` fails |
| `updatePullRequestBranch` (`gh pr update-branch`; cli `pkg/cmd/pr/update-branch/update_branch.go:141-149` always sends `expectedHeadOid` and `updateMethod`) | W11 | `pullRequestId` → M1-M3; `expectedHeadOid` required; `updateMethod` absent or `MERGE`. **Refuse `REBASE`** (`--rebase`), as W11 refuses `update_method` |
| `mergePullRequest` (`gh pr merge`; cli `pkg/cmd/pr/merge/http.go:44-103`) | **Policy.never says "or by GraphQL" (Policy:12)**; W10 is the only path | Either **refuse**, pointing to `gh api -X PUT repos/{o}/{r}/pulls/{n}/merge -f sha=<head> -f merge_method=squash`, or treat it as W10: resolve `pullRequestId`, run M1-M12, then **inject or require `expectedHeadOid == head`** (gh sends it only with `--match-head-commit`, http.go:77-79). Map `mergeMethod` (absent means MERGE at GitHub, not gh_mcp's squash); `commitHeadline`/`commitBody` ≈ title/message, and apply M5 to REBASE. Decide on `authorEmail` (harmless) |
| **Refuse** | | `enablePullRequestAutoMerge` (`gh pr merge --auto`: it merges later without M11/M12 being checked at merge time); `disablePullRequestAutoMerge`; `enqueuePullRequest`/`dequeuePullRequest`; `closePullRequest`/`reopenPullRequest`/`closeIssue`/`reopenIssue` (never 2); `deleteIssue`, `deleteIssueComment`, `deletePullRequestReview`, `deletePullRequestReviewComment`, `deleteRef`, `deleteBranchProtectionRule` (never 4); `dismissPullRequestReview`; `createRef`, `updateRef`, `updateRefs`, `createCommitOnBranch` (ref and commit writes that bypass receive-pack and §3.3's ref rules, main included); `revertPullRequest`; `requestReviews`, `requestReviewsByLogin`, `replaceActorsForAssignable`, `addAssigneesToAssignable` (no gh_mcp equivalent: Tools:295 "not … reviewers"); `updateIssueComment`; `updateRepository`, branch protection and ruleset mutations, `approveDeployments`/`rejectDeployments`, environment mutations, `transferIssue`, `lockLockable`, `minimizeComment`, `pinIssue`, project and discussion mutations, reactions; **anything else** |

### 3.3 git smart-HTTP (github.com)

Repository paths may or may not end in `.git`: `/{o}/{r}.git/…` or `/{o}/{r}/…`.
Normalize to `{o}/{r}` and apply R2. Anything else on github.com is refused:
the web UI, `/login/…`, archive and `releases/download` paths unless you choose
to allow them as reads.

| # | Operation (gh_mcp tool) | Client requests | What the proxy checks |
| --- | --- | --- | --- |
| G1 | Fetch or clone (`git_fetch`, as a read) | `GET /{o}/{r}.git/info/refs?service=git-upload-pack` (protocol v2 via the `Git-Protocol: version=2` header), then `POST /{o}/{r}.git/git-upload-pack` (`ls-refs` and `fetch` commands; body possibly `Content-Encoding: gzip`) | R2 only. gh_mcp fetched branches with `--no-tags` (Fetch:43), but reading tags is harmless, so no ref filter is needed |
| G2 | Push, advertisement | `GET /{o}/{r}.git/info/refs?service=git-receive-pack` | R2. Inject the token (GitHub answers 401 without one). On refusal, answer an `ERR` pkt-line |
| G3 | Push (`git_push`) | `POST /{o}/{r}.git/git-receive-pack`, `Content-Type: application/x-git-receive-pack-request`. The body is a pkt-line command list, then a flush `0000`, then optional push-options plus a flush, then a packfile (absent for delete-only pushes). Over `http.postBuffer` (1 MiB by default) git sends it **chunked**, and first sends a **probe POST whose body is just `0000`**; let that through | Parse the command list **before forwarding any of the body**. Skip leading `shallow <oid>` lines. The first command is `<old> SP <new> SP <ref> NUL <capabilities>`, the rest `<old> SP <new> SP <ref>`, and an oid is 40 or 64 hex digits. For **every** command: **[G3a]** the ref starts with `refs/heads/`, else refused (tags and any other ref: GP2); **[G3b]** the branch is a valid ref name (Rules:124-137); **[G3c]** it isn't `main` or `master` (case-insensitive) or the repository's `default_branch` (a proxy GET of `/repos/{o}/{r}`, cached briefly) (GP2, GP9); **[G3d]** `new` isn't all zeros (no deletes: never 4); **[G3e]** `old` all zeros means a create and is fine; **[G3f]** see §4.1 on forced updates; **[G3g]** refuse `push-cert`. If any command is refused, refuse the whole request, whether or not the client asked for `atomic`. Answer with report-status so git shows the reason: `unpack ok`, then `ng <ref> Refused: <reason>` per ref and a flush, inside side-band-64k band 1 if negotiated, optionally with a band-2 `remote:` line. git prints `! [remote rejected] <b> -> <b> (Refused: …)`. Then drain or close |
| G4 | LFS (no gh_mcp equivalent) | `POST /{o}/{r}.git/info/lfs/objects/batch {operation: download\|upload}`; `…/info/lfs/locks…` | Decide: `download` is a read; `upload` loses nothing but has no gh_mcp equivalent; locks are refused |

### 3.4 uploads.github.com

gh_mcp makes no request here; it never uploads release assets. `gh release
create/upload` sends `POST
https://uploads.github.com/repos/{o}/{r}/releases/{id}/assets?name=…`. Refuse it
by default. If it is ever allowed, require the release to be a draft (as RL6)
and the repository to be allowed. PR #254's notarized dmg is uploaded by CI
with its own token, not by agents.

---

## 4. What a proxy can't do the way gh_mcp does, with suggestions

### 4.1 git push: the lease isn't on the wire

gh_mcp forced only with `--force-with-lease` against the checkout's
`refs/remotes/<remote>/<branch>` (GP10). On the wire every receive-pack
command is a compare-and-swap on `old`. A forced push, a lease and a
fast-forward all look the same: `old` is the value just advertised. The
lease's real meaning ("only replace what I last fetched") lives in the client.
The proxy can't tell a fast-forward from a rewrite without the object graph.
Options:

- **(a)** Parse the pack (inflate, resolve deltas) to walk the commits from
  `new` down to parents not in the pack. Then ask GitHub `GET
  /repos/{o}/{r}/compare/{old}...{parent}` whether `old` is an ancestor
  (`identical` or `ahead`). Refuse a non-fast-forward unless an explicit
  signal is present, such as a push option `-o force` (receive-pack's
  `push-options` capability).
- **(b)** Accept non-fast-forward updates to agents' own branches, which G3c
  already restricts. GitHub's CAS still stops clobbering anything pushed
  between the advertisement and the push, but a plain `git push --force` can
  now overwrite a branch the agent never fetched (another agent's commits).
  Record this as a deliberate deviation.
- Either way, GP3 (no branch named like a local tag) can't be seen. An optional
  stand-in is to refuse `refs/heads/X` when the advertisement or `GET
  …/git/ref/tags/X` shows a tag `X`.

### 4.2 Answers gh_mcp composed

- **run_dispatch** (D8): GitHub's 204 has no run, and gh_mcp polled for up to
  20 s to name the run and commit. Allow `return_run_details: true` (gh sends
  it already) so GitHub answers the run id and URL. Optionally the proxy adds
  it when absent. Lacking that, the agent runs `gh run list --workflow …
  --branch … --event workflow_dispatch`.
- **pr_ready_for_review**: the no-op when already in the asked state (RD1) and
  the read-back (RD3) are lost. GitHub answers directly; the agent can `gh pr
  view`.
- **release_draft**: RL4 (the response must say draft) can be a response check
  in the proxy, which would log a mismatch, since the request has already been
  sent.
- **release_edit_draft**: RL7 needs **body rewriting** (inject `tag_name`).
- **pr_merge, run_rerun, run_cancel, run_dispatch, pr_update_branch,
  release_edit_draft**: their preconditions are **multi-request reads** that the
  proxy must make itself, with the same installation token, before forwarding
  (M1-M12, RR1-RR8, C1-C2, D5-D6, RL6). That adds latency (pr_merge makes 7 or
  more GETs plus paging). There is the same check-then-act window gh_mcp had:
  the head is pinned by `sha`/`expectedHeadOid`, but a review or CODEOWNERS
  could change in between. Cache `GET /repos/{o}/{r}` (`default_branch`,
  `allow_*_merge`) for seconds, never for long.
- **The refusal texts** become HTTP, GraphQL or git error bodies (§3 ground
  rules). Keep §2's wording so agents' existing habits still apply.
- Summaries (`pr_view`, `checks`, `run_view`, `run_log` trimming, `repo_file`
  caps) are formatting. gh and the raw API answer instead.

### 4.3 Guards that were local to the Mac

- GP11's scratch repository, hooks off, no checkout config, the token never in
  a file or URL, the URL gh_mcp built, and one refspec: all of this protected
  **the Mac** from a checkout the agent controlled. In 0.47 git runs in the
  agent's own sandbox with no token, so these are moot. The proxy's
  equivalents are "token only in the proxy" and "only github.com's repository
  paths".
- GP5-GP8 (which remote and URL): replaced by G3's repository from the path.
- GP14, the tracking ref update, happens in git itself.
- artifact_download's AD1-AD5 and AD9-AD10 (destination rules, zip-slip and
  symlink checks) and AD7 (2 GiB) protected the Mac's filesystem. In the
  sandbox the agent unzips for itself. AD7 could be kept by checking
  `size_in_bytes` on `GET …/artifacts/{id}/zip`, at the price of one more GET.
  Suggest dropping it.

### 4.4 Identity, logs and redaction

- A1-A5 become the Runner's knowledge of the session. Map the session to the
  agent's App (claude, codex or agent) and ask Keymaster for that App's token.
- A6: log one line per request: time, `<session>@<application>`, method, host,
  path **template**, repository, outcome. Never a token or body.
- A7: the proxy never shows the agent its token. As defence in depth, scrub
  the injected token from response bodies and headers.

### 4.5 Reads gh needs that gh_mcp never allowed

P1 refuses every GET outside `/repos/{o}/{r}` and every GraphQL query. gh
needs both: GraphQL queries for `pr view/list/checks/status`, `repo view` and
`issue list`, and some global REST such as `/rate_limit`, `/user` (403 for an
App token) and `/meta`. GraphQL's `node(id:)`, `search` and `repository(owner:,
name:)` can reach any repository the token can.

**Suggestion:** have Keymaster mint installation tokens **restricted to the
allowed repositories**, with the GitHub App's `repositories` parameter, and to
the needed permissions: contents, pull_requests, issues and actions write;
checks, statuses and metadata read; `workflows` write if agents' branches touch
`.github/workflows/`. GitHub then enforces the read scope for GraphQL,
`/repositories/{id}` and search, and the proxy enforces the write rules.
Without that, a narrower allow-list (`Owner/name`) is enforceable only on REST
paths and resolved nodes.

### 4.6 Parsing hazards that come with the proxy

- HTTP/1.1 chunked and HTTP/2 bodies; `Expect: 100-continue`.
- gzip request bodies (upload-pack).
- Request smuggling between the client side and the upstream side.
- Duplicate JSON keys, non-object bodies, query strings on writes (§3 ground
  rules).
- GraphQL aliases, variables and multiple operations (§3.2).
- receive-pack's probe `0000` request and its streamed packs (§3.3).

### 4.7 Discrepancies inside gh_mcp worth knowing

- The MCP `initialize` instructions still say "It never merges" and don't
  mention re-runs or dispatch (MCP:112-121).
- Reruns:46-47's comment says "never … a dispatch's", but the code allows
  `workflow_dispatch` (Reruns:20). Policy:72-73 says "a completed pull_request
  or push run", and so does the README's table (README:165).
- W15 alone accepts a tag's short name (`ref: "v1.0"`); only D6 makes it a
  branch. A proxy could also rewrite `ref` to `refs/heads/<b>`, which GitHub
  accepts and which removes the branch/tag ambiguity, if W15's "no `refs/`"
  rule is relaxed for `refs/heads/` alone.
- P1's `/repositories/` passes for **any** id, relying on the token's scope.
- P3's gap: a non-object body skips the field check (Policy:119).
- CodeOwners silently drops a pattern it can't compile (CodeOwners:34-36), and
  reads at most 10 pages of reviews (CodeOwners:150). An owner's later
  CHANGES_REQUESTED beyond 1000 reviews would be missed.

---

## 5. The tests (Tests/GHMCPTests/GHMCPTests.swift), and what each pins

The fakes: `FakeTransport` answers `"<METHOD> <path>"` from a table, else 404,
and records every request (Tests:8-30). `FixedToken` stands in for agent-token
(Tests:32-34). `makeServer` builds a config with one key (Tests:36-43). The
fixtures: `mergeablePull`, PR 50, clean (Tests:525-533); `greenRuns`
(Tests:535-538); `mergeTransport` (Tests:542-554, statuses 403 by default);
the `guardrails` CODEOWNERS (Tests:650-659); `workflowRun`, run 77 (Tests:724-732);
and `runTransport` (Tests:736-745).

"Proxy" in the right-hand column marks what should be ported as a proxy test.
The rest is MCP- or Mac-specific.

| Test (line) | Behaviour pinned | Port? |
| --- | --- | --- |
| `sha256Vectors` (87) | SHA-256 against the FIPS vectors | no |
| `keysAreKeptAsHashesOnly` (94) | `ghmcp_` prefix; only the hash is stored and the key never appears in the config; lookup by key, and a wrong key isn't found; unknown agent `gpt` refused; second key for an application refused; saved mode 600; round-trip | no (Runner identity) |
| `unknownKeyIs401` (111) | no key or a wrong key gets 401; `API_KEY` and `Authorization: Bearer` work; `CLIENT_ID` "sess 42\n" becomes "sess42"; label `s1@macbook-pro-visor` | identity only |
| `jsonRPCFraming` (125) | initialize echoes the asked version; a notification gets 202; tools/list is exactly the 35 tools; unknown method -32601; unknown tool -32602; parse error 400/-32700; a batch; GET 405; another path 404 | no |
| `httpParsing` (150) | header `API_KEY` read as `api-key`; incomplete bodies; 100-continue; chunked; 413 over maxBody | partly (body caps) |
| `repositoryRules` (167) | `AttilaTheFun/*` and `other/one` match case-insensitively; `other/two` and `someone/else` refused; "not a repo" invalid; remote URL forms https/.git, scp, ssh, with credentials in the URL, trailing `/`; gitlab and local paths aren't GitHub repositories | **proxy** (R2, path to repo) |
| `branchRules` (182) | pushable: `feature/x`, `refs/heads/fix` → `fix`. Refused: `main`, `master`, `Main`, `refs/heads/main`, `refs/tags/v1.0`, `refs/remotes/origin/x`. Invalid: `a..b`, `-x`, `x.lock`, `a b`, `x:y`, `HEAD`, ``, `a/`, `.hidden` | **proxy** (G3a-c) |
| `redaction` (193) | `ghs_…` and `ghmcp_…` redacted; a log line keeps only the first line and redacts it | **proxy** (logs) |
| `argumentsAreChecked` (201) | missing `number`; unknown `merge` argument; `state: merged` invalid; `limit: 500` invalid; disallowed repository Refused; `pr_edit` with nothing "give one"; `repo_file ../etc/passwd` Invalid; **no GitHub request made** | partly (repository refused; path hygiene) |
| `releasesAreDraftsOnly` (214) | the draft is sent with `draft: true`; editing a published release (id 8) refused with "published" and **no PATCH sent**; editing a draft (id 9) sends `tag_name: "v1.1"` back, the new body, and no `draft` | **proxy** (W8, RL6, RL7) |
| `tokenCacheAsksAgentTokenOnce` (239) | one agent-token call per (agent, owner, case-insensitive); args `token claude --owner AttilaTheFun`; another agent gets another token; expired at 300 s with maxAge 240; invalidate forces a new one; a failure throws | Keymaster client |
| `pushRefusesMainTagsAndOtherRepos` (265) | `main`, `master`, `refs/tags/v1`, `v1` (a local tag), `develop` (the remote default branch) are all Refused; remote `someone/else` "not among"; a local bare path "not a GitHub repository" | **proxy** (G3a, G3c, R2; not the local tag) |
| `pushSendsTheBranchWithoutHooksOrStoredToken` (287) | the push lands in the remote; the tracking ref is updated; the pre-push hook doesn't run; no `ghs_` or `credential` in `.git/config`; an amended commit is refused without a lease ("refused"); with a lease it is "forced" and replaces | partly (§4.1 decides) |
| `launchAgentPlistRunsServe` (321) | the LaunchAgent runs `gh_mcp serve`, KeepAlive | no |
| `policyRefusesWhatGoesThroughLogan` (329) | see the list after this table | **proxy, all of it** |
| `newWritesAreNonDestructive` (394) | `pr_review` sends `event: COMMENT`; `issue_edit labels "bug, ui"` sends exactly `{labels: ["bug","ui"]}`; `issue_edit state:` is "no argument state" | **proxy** (W4, W6) |
| `fetchBringsBranchesIntoTrackingRefs` (407) | `refs: feature` moves only `origin/feature`; a full fetch moves `origin/main`; the config is unchanged; the reference-transaction hook doesn't run; `refs/tags/v1` Invalid; another repository Refused | **proxy** (G1 repository check only) |
| `servesMCPOverHTTP` (447) | a real 127.0.0.1 listener; tools include `pr_merge` and no tool named delete, close or publish; a bad key gets 401 | no |
| `readyForReviewMakesADraftReady` (479) | a draft PR leads to `POST /graphql` | **proxy** (the mutation allowed) |
| `readyForReviewLeavesAReadyPullRequestAlone` (490) | a ready PR leads to no GraphQL | no (client-side) |
| `readyForReviewFailsWhenNothingChanged` (498) | the mutation answers `isDraft: true` and the call fails with "still a draft" | no (client-side) |
| `checksAnswerRunsWhereStatusesAreForbidden` (510) | statuses 403 gives "1 passed" plus `statuses_note` | no (but M11's 403 tolerance: yes) |
| `mergesWhenEverythingIsGreen` (560) | exactly one merge, body `{merge_method: squash, sha: head, commit_title: "One (#50)"}`, the answer names the merge SHA | **proxy** |
| `mergeCountsReadableStatuses` (570) | a `success` status merges; a `pending` status is refused with "ci/x is pending" and no merge sent | **proxy** (M11) |
| `mergeRefusesUnlessEveryGuardHolds` (581) | each refused with no merge sent: draft ("is a draft", even with mergeable_state `draft`); closed ("is closed"); base `release` ("not AttilaTheFun/oss's default branch main"); fork ("in someone/oss"); behind ("pr_update_branch"); blocked, dirty, unstable ("mergeable_state is …"); a check in_progress ("linux is in_progress"); failure ("linux concluded failure"); a re-run queued ("linux is queued"); no check runs ("no check runs"); rebase not allowed ("doesn't allow rebase") | **proxy** (M2, M3, M6, M8-M11) |
| `mergeRefusedWhenTheHeadChanged` (622) | a 409 or 405 from the merge is Refused with GitHub's "modified" message; `sha` was sent | **proxy** (M13) |
| `updateBranchSendsTheExpectedHead` (632) | `PUT …/50/update-branch` with exactly `{expected_head_sha: head}`; a fork's PR is refused with no PUT | **proxy** (W11, M3) |
| `codeOwnersMatchAsGitHubDoes` (661) | with `guardrails`, **owned**: `.github/workflows/ci.yml`, `.github/CODEOWNERS`, `AGENTS.md`, `swift_ffi/AGENTS.md`, `LICENSE`, `tools/signing/sign.sh`, `tools/ci/publish_from_ci.sh`, `docs/a/b/secret.md`, `docs/secret.md`. **Free**: `Sources/main.swift`, `README.md`, `swift_ffi/LICENSE`, `tools/ci/container_build.sh`, `github/x`, `tools/signing/README.md` (an owner-less last rule wins), `AGENTS.md.bak`, `x/.github/y`. `* @someone` owns `a/b/c` | **proxy** (M12 matcher) |
| `mergeRefusesProtectedFilesWithoutTheOwnersApproval` (684) | `.github/workflows/ci.yml` changed is refused, naming the path and `@AttilaTheFun`, for: no review; approved an older head; someone else approved; approved then CHANGES_REQUESTED | **proxy** (M12) |
| `mergeAllowsUnprotectedFilesAndApprovedProtectedOnes` (703) | unprotected files merge; `AGENTS.md` approved by `attilathefun` (lowercase) on the head merges, with another user's COMMENTED ignored | **proxy** (M12) |
| `rerunRunsAFailedPullRequestRunAtItsHead` (751) | POSTs only `…/77/rerun-failed-jobs` with no body; the PR lookup query is `head=AttilaTheFun:feature`, `state=open`; the answer has the run URL and "a merge waits for them to pass" | **proxy** (RR5, W13) |
| `rerunFailedOnlyPicksThePath` (763) | `failed_only: false` on a success run POSTs `/rerun`; `true` POSTs `/rerun-failed-jobs` | **proxy** (path choice; RR8 only on failed-jobs) |
| `rerunRunsAPushRunAtItsBranchTip` (776) | a push run reads `git/ref/heads/feature` and makes one POST | **proxy** (RR6) |
| `rerunRefusedUnlessEveryGuardHolds` (785) | each refused with no POST: PR head moved ("only the head's runs"); branch tip moved for a push; in_progress or queued ("is … , not completed"); release or schedule ("is a release run" / "is a schedule run"); fork ("in someone/oss"); no open PR ("no pull request from feature is open"); branch gone ("no longer a branch"); success ("no job failed") | **proxy** (RR1-RR8) |
| `cancelCancelsARunStillGoing` (813) | in_progress and queued POST `/cancel` with no body; "asynchronously" | **proxy** (W14) |
| `cancelRefusedForAReleaseOrACompletedRun` (824) | release ("its publishing must finish") and completed ("already completed") refused with no POST | **proxy** (C1, C2) |
| `rerunRunsADispatchedRunAtItsBranchTip` (838) | a workflow_dispatch run is re-run at its branch tip; refused once the branch moved | **proxy** (RR2, RR6, RR7) |
| `dispatchRunsAWorkflowOnABranchAndNamesItsRun` (853) | `ci.yml` resolves to id 12; POST `/workflows/12/dispatches` with `{ref: feature, inputs: {kind: quick}}`; the answer names run 901, the head's 12-character SHA, `kind=quick` | **proxy** (W15, D5, D6; the answer via `return_run_details`) |
| `dispatchRefusesWhatItShouldNot` (873) | Invalid: `refs/tags/v1`, `../x.yml`, inputs that aren't JSON, an input with two lines. Refused: an inactive workflow (`disabled_manually`), no such branch (`gone`). No POST in any case | **proxy** (W15, D3, D5, D6; the proxy sees an id, not `../x.yml`) |

**`policyRefusesWhatGoesThroughLogan`, line by line** (Tests:329-392; `sha` is
40 `a`s).

**Refused:**

| Request | Line |
| --- | --- |
| `PUT …/pulls/3/merge` with no body | 338 |
| …with only `merge_method` | 339 |
| …with `sha: "main"` | 340 |
| …with `merge_method: fast-forward` | 341 |
| …with `admin: true` | 342 |
| …with `delete_branch: true` | 343 |
| `POST …/pulls/3/merge` | 344 |
| a merge on another repository | 345 |
| `POST …/merges` | 346 |
| `update-branch` with no body | 347 |
| `update-branch` with `update_method: rebase` | 348 |
| `PATCH …/pulls/3 {state: closed}` | 349 |
| `PATCH …/issues/3 {state: closed}` | 350 |
| a review with `APPROVE` | 351 |
| a review with `REQUEST_CHANGES` | 352 |
| a release with `draft: false` | 353 |
| `PATCH …/releases/9 {draft: false}` | 354 |
| `PATCH …/releases/9 {make_latest}` | 355 |
| `DELETE …/git/refs/heads/x` | 356 |
| `DELETE …/issues/comments/5` | 357 |
| `POST …/git/refs` for a tag | 358 |
| `rerun-failed-jobs` with `enable_debug_logging` | 359 |
| `rerun` with `enable_debug_logging` | 360 |
| `force-cancel` | 361 |
| `runs/1/approve` | 362 |
| `actions/jobs/1/rerun` | 363 |
| `DELETE …/runs/1` | 364 |
| `DELETE …/runs/1/logs` | 365 |
| `PUT …/actions/permissions` | 366 |
| a cancel on another repository | 367 |
| `runs/main/rerun` (not numeric) | 368 |
| a dispatch by `ci.yml` in the path | 369 |
| a dispatch with `ref: refs/tags/v1` | 370 |
| a dispatch with `return_run_details` | 371 |
| `PUT …/branches/main/protection` | 372 |
| `PUT …/actions/secrets/X` | 373 |
| `PATCH /repos/… {private: false}` | 374 |
| GraphQL `mergePullRequest` | 375 |
| a GET on another repository | 376 |
| an issue on another repository | 377 |

**Allowed:**

| Request | Line |
| --- | --- |
| `GET …/pulls/3/comments` | 379 |
| a COMMENT review | 380 |
| `PATCH …/issues/3 {title, labels}` | 381 |
| a reply to an inline comment | 382 |
| the ready-for-review GraphQL | 383 |
| a merge with sha, method, title and message | 384-385 |
| `update-branch` with `expected_head_sha` | 386 |
| `rerun-failed-jobs`, `rerun` and `cancel` with no body | 387-389 |
| a dispatch on id 12 with `{ref: main, inputs}` | 390 |

And `Policy.never` doesn't contain the bare string "merge a pull request"
(391).

For the proxy, port the whole table as request→verdict cases. Change
line 371 (`return_run_details`) to allowed if §4.2 is adopted, and turn line
375 into whichever of §3.2's two choices is taken for `mergePullRequest`.
