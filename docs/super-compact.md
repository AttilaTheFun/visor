# Super Compact

A session's conversation grown too big to move or back up (Isomer's is
2.3 GB; a move's and a backup's file cap is 2 GiB) is condensed into one
document, **HANDOFF.md**, that a new session reads in full before anything
else and carries the work on from. Logan, 20 Nov 2026: "some kind of
'super compact' where a haiku agent reads the entire transcript, writes
out an extensive summary of everything important in that session, and
then archive the original + start a new session with the super compact".

Decided (Logan, 20 Nov): a cascade of models, **Haiku → Sonnet → Opus**,
each a setting; the person reviews (and may edit) the handoff before
anything is cut over, which is always required; usage is no concern, but
the server runs **one compaction at a time**, for its disk and CPU.

This is the server's half (0.64, PR A): the job, its endpoints, its
settings. The client's (PR B) adds the session menu's Super Compact…, the
progress and review sheet, and the cut-over: a new session (the same
title with "(continued)", the same agent, model and effort, HANDOFF.md in
its folder, Claude's project memory copied, its first prompt to read
HANDOFF.md in full), the original archived and never deleted, and its
inbox forwarded to the new id.

## The endpoints

Admin-only, as every REST route (docs/protocol.md, "Who gets in").

| Request | Answer |
|---|---|
| `POST /api/sessions/<id>/super-compact` | `202` with the job (below): started on a snapshot of the session's conversation, the session running on meanwhile. When the session's last job failed, that one carries on from where it failed instead. `409` while any job runs on this server ("one at a time per server"); `400` for a session that isn't Claude's or has no conversation yet, or when `claude` isn't on this computer; `404` when its conversation file isn't here. |
| `GET /api/sessions/<id>/super-compact` | The session's job running, else its latest; `404` when it has had none. |
| `DELETE /api/sessions/<id>/super-compact` | Cancels the session's running job (its call under way is ended at once): the job, `phase` `cancelled`. `404` when none runs. A cancelled job is over for good. |

The job (`type` `superCompact`, SuperCompactJob, kept as `job.json` in its
folder): `id`, `session`, `conversation` (Claude's id), `title`; `source`
and `sourceBytes`, the conversation's file and the snapshot; `folder`;
`phase` (`prefilter`, `map`, `merge`, `final`, `done`, `failed`,
`cancelled`) and, for one failed or cancelled, `failedIn`; `chunk` of
`chunks` (the map's progress) and `mergeStep` of `mergeSteps`;
`filteredCharacters`; `settings`, as it began with them; `error` (why it
failed, or the attempt that last had to be tried again); `warnings` (the
check's); `handoff` (HANDOFF.md's path, once written); `started`,
`updated`, `finished` (seconds since 1970).

## How it runs

Each job has a folder in the server's data folder,
`super-compact/<session>/<job>/`, and every step's output is a file there,
written once it is whole. A step whose file is there is done, so a job
the server went away under (it halts the job when it steps aside or
quits) carries on when the server starts again, from its last finished
step: a 300-chunk map killed at chunk 120 maps chunk 120 again, not
chunk 1.

```
job.json              the job, after every step
chunks/0001.txt …     the prefilter's text, ~120k tokens each
map/0001.md …         each chunk's LEDGER and CHAPTER (Haiku)
merge/1-0001.md …     each merge's LEDGER and TIMELINE (Sonnet), by level
ledger.md             the merged ledger
timeline.md           the merged timeline
HANDOFF.md            the final step's (Opus)
```

1. **The snapshot.** The conversation is append-only, so the job takes its
   length in whole lines when it starts (`sourceBytes`) and reads no
   further: what the session writes on meanwhile is not in it. Only the
   JSONL is read; the folder beside it (subagents' conversations, long tool
   outputs Claude Code set aside) holds nothing the prefilter would keep,
   since a subagent's answer is in the conversation as its tool's result.
2. **The prefilter** (SuperCompactFilter, no model) streams the file 4 MB
   at a time, never reading it whole, and keeps, in order, each headed
   with its time (`[2026-11-20 14:05]`, UTC):
   - `PERSON:` the person's words (a slash command as typed, a message
     queued while the agent worked, the answers to its questions), up to
     20,000 characters each;
   - `AGENT:` the agent's text replies, likewise;
   - `CLAUDE'S COMPACTION SUMMARY:` Claude Code's own summary at each of its
     compactions (the user line marked `isCompactSummary`), whole, after
     the `compact_boundary` line's marker: dense summaries of all before
     them, which anchor the chronology;
   - `TOOL <name>: <key arguments>`, each call as a line (a command, a file
     path, a repository, a PR number, a title…);
   - `→ …`, each result's first four lines (400 characters at most), and
     how many more there were;
   - `MAIL FROM/TO …:` mail as a line, in each of its forms (a message
     headed with its sender, `@@from`, `@@to`, the inbox's notice, Visor's
     `send_message`);
   - task notifications, goals and titles as a line.

   Dropped: images (counted where they were), thinking, every system
   reminder, Claude Code's bookkeeping lines (API records, attachments,
   queue operations, …), subagents' sidechains, and the rest of each tool's
   output. The text is written in chunks of about `chunkTokens` (at four
   characters a token), never cutting an entry.
3. **The map (Haiku)**, a chunk at a time, in order: each call gets the
   chunk and the LEDGER the last one left, and answers the ledger updated
   and a dated CHAPTER of the chunk. The ledger's sections: rules and
   decisions (dated, verbatim where the wording matters, never dropped
   unless withdrawn), standing preferences, who's who, current state per
   area, open work and promises, waiting on others, gotchas and lessons,
   identifiers.
4. **The merge (Sonnet)**: the map's outputs in groups of `mergeGroup`, then
   the groups' outputs in groups, until one is left, each call answering
   one LEDGER (the rules unioned, the latest state winning) and one
   TIMELINE. Even a single chunk is merged once.
5. **The final step (Opus)** writes HANDOFF.md from the merged ledger and
   timeline: who's who, rules and decisions, current state per area, open
   work (prioritised), waiting on others, gotchas, a timeline, pointers.
   It may be longer than a context window: the new agent reads it in parts.
6. **The check**: each of the merged ledger's rules and decisions is
   reduced to its telling words and identifiers (`#474`, `0.64`); one whose
   identifiers aren't all in HANDOFF.md, or fewer than half its words, is
   named in the job's `warnings`, for the person reviewing it.

Each call is Claude Code headless, on the account Visor's sessions use
(no API key of its own), in the job's folder, the prompt on its standard
input:

```
claude -p --model <model> --output-format json --tools "" \
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --safe-mode --disable-slash-commands --no-session-persistence \
  --system-prompt <Super Compact's own>
```

No tools, no MCP servers, none of the computer's customizations (CLAUDE.md,
hooks, plugins, skills: `--safe-mode`), and nothing kept of the call, so it
never shows among the sessions to resume. A call that fails, answers in
another form than asked, or runs past an hour is tried again, three times
in all; then the job fails, saying why, and `POST` carries it on.

## Settings

`superCompact` in the server's settings (`settings.json` in its data
folder; ServerSettings.superCompact). None, the default:

```json
"superCompact": {
  "mapModel": "haiku",
  "mergeModel": "sonnet",
  "finalModel": "opus",
  "chunkTokens": 120000,
  "mergeGroup": 8
}
```

A model is whatever `claude --model` takes: Claude Code's alias for the
latest of a family, or a model's full id (`claude-opus-5-5`). Haiku's
window is 200,000 tokens, which a 120,000-token chunk, the ledger and the
prompt fit. A job keeps the settings it began with.

## Cost and time

A 2 GB conversation is mostly tool output and images: prefiltered, it is
likely 5–40M tokens, so 40–300 Haiku calls, one after another (the ledger
carries forward), about 30 minutes to 3 hours, then a few Sonnet calls
and one Opus call. It runs in the background on the server and doesn't
depend on any client.
