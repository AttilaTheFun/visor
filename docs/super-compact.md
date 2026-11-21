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

The server's job, its endpoints and settings came first (0.64, PR A);
then the client's half and the cut-over (PR B): the session menu's Super
Compact…, the sheet that follows the job and shows HANDOFF.md for review,
and the cut-over, the server's, below.

## The endpoints

Admin-only, as every REST route (docs/protocol.md, "Who gets in").

| Request | Answer |
|---|---|
| `POST /api/sessions/<id>/super-compact` | `202` with the job (below): started on a snapshot of the session's conversation, the session running on meanwhile. When the session's last job failed, that one carries on from where it failed instead. `409` while any job runs on this server ("one at a time per server"); `400` for a session that isn't Claude's or has no conversation yet, or when `claude` isn't on this computer; `404` when its conversation file isn't here. |
| `GET /api/sessions/<id>/super-compact` | The session's job running, else its latest; `404` when it has had none. |
| `DELETE /api/sessions/<id>/super-compact` | Cancels the session's running job (its call under way is ended at once): the job, `phase` `cancelled`. A job done and waiting for its review has its handoff discarded instead (`discarded`, a time): nothing is cut over from it. `404` when there is neither. A cancelled job is over for good. |
| `GET /api/sessions/<id>/super-compact/handoff` | HANDOFF.md of the session's job that is done: `{"type":"handoff","text":…,"path":…}`. `409` while the job runs or when it ended otherwise, `404` without one. |
| `PUT /api/sessions/<id>/super-compact/handoff` | The person's edits, `{"text":…}`, saved in place of HANDOFF.md, and the check run again on them: the job, with its new `warnings`. At most 8 MiB (`413` past it); `409` once the handoff has been started from or discarded. |
| `POST /api/sessions/<id>/super-compact/cutover` | The cut-over (below): `{"type":"cutover","session":‹new id›,"cwd":…,"message":…,"sessions":[…]}`. `409` unless the job is done and waiting for its review, and while the session is mid-turn. |

The job (`type` `superCompact`, SuperCompactJob, kept as `job.json` in its
folder): `id`, `session`, `conversation` (Claude's id), `title`; `source`
and `sourceBytes`, the conversation's file and the snapshot; `folder`;
`phase` (`prefilter`, `map`, `merge`, `final`, `done`, `failed`,
`cancelled`) and, for one failed or cancelled, `failedIn`; `chunk` of
`chunks` (the map's progress) and `mergeStep` of `mergeSteps`;
`filteredCharacters`; `settings`, as it began with them; `error` (why it
failed, or the attempt that last had to be tried again); `warnings` (the
check's); `handoff` (HANDOFF.md's path, once written); `started`,
`updated`, `finished` (seconds since 1970); `continuedAs`, the session
started from it once it is cut over, and `discarded`, when its handoff was
thrown away instead.

## How it runs

Each job has a folder in the server's data folder,
`super-compact/<session>/<job>/`, each folder down to it its owner's alone
(0700, set again on one that was there already): they hold the
conversation's text, and the first lines of its tools' results can carry
tokens. Every step's output is a file there,
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

## The review

The session menu's **Super Compact…** (Claude's sessions, on a server
that has it) opens a sheet over the session (SuperCompactSheet, its
model SuperCompact in visor_client):

- **Start** begins the job (**Carry On** after a failed one). The sheet
  then follows it, asking every two seconds while it is open: the phase,
  the map's chunk n of N, the merge's step, the final step, a call that had
  to be tried again, and **Cancel Super Compact**. The job runs on the
  server whether the sheet is open or not; opened again, the sheet picks
  it up where it is.
- **Done**, it shows HANDOFF.md for review, as markdown, cut at its
  headings. Above it, a note: "This summary was written from the
  session's transcript. It may include secrets that appeared in tool
  output, so check before using it." Then the check's warnings, and:
  - **Edit**: HANDOFF.md in a text editor, saved with `PUT …/handoff`
    (the check runs again on the edit);
  - **Start New Session**: the cut-over;
  - **Discard**: the handoff thrown away (`DELETE`), and nothing changes.
- **Review is required.** Nothing is cut over on its own: only Start New
  Session, on a job that is done, does it.
- Once cut over, the sheet says so and the new session opens. The old
  session's chat shows a **Continued as “…”** row linking to the new one
  (`continued-as`), and the new one's a **Continued from “…”** row back
  (`continued-from`).

## The cut-over

`POST …/super-compact/cutover`, the server's alone, since only it can do
every step together. It is refused unless the session's latest job is
done, waiting for its review (not cut over, not discarded), and while the
session is mid-turn. Then:

1. **The new session**, started as a client's start makes one, in a fresh
   folder: the server's folder for each session (VISOR_SESSIONS_DIR's
   `<dir>/Claude/<id>`), else `Sessions/Claude/<id>` in its data folder, as
   a session moved here gets. Its agent, model, effort and permissions
   are the old one's, and its title the old one's with " (continued)".
2. **HANDOFF.md** (as reviewed and edited) is copied into that folder.
3. **Claude's project memory**, keyed by the folder (`memory` beside the
   old conversation, `~/.claude/projects/<old key>/memory/`, or under
   the project of the old session's folder), is copied under the new
   folder's project (`~/.claude/projects/<new key>/memory/`), as a move
   carries it (VisorServer+MigrationMemory), never over one that is there.
4. **Its first prompt:** "You're continuing session "‹old title›"
   (‹old id›). Read HANDOFF.md in this folder in full, in parts if it's
   long, before anything else, and treat its rules and decisions as the
   person's own."
5. **The old session is archived**, never deleted: its conversation stays
   where it is, exportable by copying its files by hand, as it is over the
   archive caps.
6. **Its inbox is forwarded.** The unread messages move to the new
   session's inbox, addressed to it, and its agent is told it has mail
   once its first turn ends; what was read stays. From then on, mail to
   the old id (`send_message`, a relayed message, or one written as
   `@@to`, by its id or name) goes to the new session. The forwarding
   entry is the old session's `continuedAs`, kept with it, and delivery
   follows a chain of them to its last session (A→B→C, after two
   cut-overs, goes to C); the sender is told it was forwarded, through how
   many continuations, and the final id to write to from then on. So that
   a mistaken `continuedAs` can never bounce a message for ever, the chain
   is followed at most 8 hops (`VisorServer.forwardingHops`) and never
   round a cycle (A→B→A, or a session carried on as itself): either, or a
   continuation to a session no longer on the server, refuses the message
   with a clear error to its sender, and nothing is delivered. A chain
   that ends at a session archived or ended by hand is refused the same
   way. Each forward and each refusal is logged.
7. **Each names the other:** `continuedAs` on the old session and
   `continuedFrom` on the new (SessionInfo), and the job's `continuedAs`.

The answer's `message` says what was copied (the memory's files) and how
many messages moved.

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
