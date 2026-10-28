# Sub-sessions (design)

A session can open sub-sessions: a fork of it, a branch of it, a side
question (`/btw`), or one of its agent's subagents. Each has a chat page
of its own, opened from its parent.
Status: proposed for 0.43. Nothing here is built yet.

## What each one is

**Fork**: `/fork <prompt>`. A copy of the conversation so far, which
starts on the prompt while the parent goes on with its own work.
- Claude: `--resume <parent> --fork-session`; the new id comes from
  `system/init`.
- Codex: `thread/fork`.

It is a session of its own: same folder, same computer or container,
same model and permissions. It carries `parent` and `origin: fork`.

**Branch**: `/branch [name]`, or Branch from Here on an earlier message
of the person's. A copy of the conversation up to that point, idle, for
the person to go on from.
- Claude adds `--resume-session-at <uuid>` to the fork.
- Codex: `thread/fork` with `lastTurnId`.

Otherwise it is a fork, with `origin: branch`.

**Side question**: `/btw <question>`. A question about the
conversation, answered without adding to it, even while the agent is
working.
- Claude: the `side_question` control request on the running process.
  It takes `{question, history}`, where history is the earlier questions
  and answers, and answers `{response}`. It uses no tools. Tried against
  Claude Code 2.1.306 in `-p` stream-json mode, mid-session.
- Codex: an ephemeral `thread/fork`, with a turn on it.

It is not a session of its own: the parent keeps its questions and
answers, on the server, until the person ends it.

**Subagent**: an Agent (Task) call, or a Codex `spawn_agent`. Its own
transcript, live.
- Claude: `--forward-subagent-text` marks a subagent's messages with
  `parent_tool_use_id` while it runs. Afterwards they are in
  `<session>/subagents/agent-*.jsonl`. Today Visor folds these messages
  into the main transcript's activity and status, and its context count
  too, which is wrong.
- Codex: the subagent's own thread (`parentThreadId`).

## How it looks

- **The parent's chat.** A sticky row above the composer for each open
  sub-session: its kind, its name, and its state (working, idle, waiting
  for an answer). Tapping a row opens it; its ✕ ends it.
- **The sessions list.** Under a session's card, a capsule for each open
  sub-session; tapping one opens it.
- **A sub-session's page.** The same chat page, with a way back to its
  parent ("Fork of …"). Its composer sends to the sub-session: on a side
  question's page, another side question.
- **Ending one.** A fork or branch ends as any session does. A side
  question's page and its answers go. A subagent's row goes when it
  finishes and has been opened, or when it is closed.

## Wire

- `SessionInfo` gains `parent` (a session id) and `origin` (`fork` or
  `branch`). The list shows a child under its parent, not as a card of
  its own.
- Side questions: a `side` message, `{session, id, question}`. The
  parent's `SessionInfo.side` lists `{id, question, answer?}`. `end`
  takes a side id.
- Subagents: `StatusItem`s of kind `subagent` already carry the tool use
  id. A subagent's transcript is read like a session's (pages, then
  deltas), by `session` plus `subagent`.
- `start` takes `parent`, `origin` and `at` (the message to branch at).
  The slash menu lists `/fork`, `/branch` and `/btw` as Visor's own, as
  it does `/login`.

## Order

1. The shared part: `parent`/`origin`, the sticky rows, the capsules,
   and a sub-session's page.
2. Side questions.
3. Fork and branch, then Branch from Here.
4. Subagents: their transcripts kept apart from the parent's, and their
   pages.
5. Talking to a subagent (below).

## Open

**Talking to a running subagent.**
- Codex's subagents are threads, so a turn can be started on one
  directly.
- Claude's `-p` mode drops a person's message aimed at a subagent (a
  user message with `parent_tool_use_id`). Only the parent agent reaches
  a running subagent, with its SendMessage tool.

So a message from a Claude subagent's page would either:
- go through the parent, which costs the parent's context and turn; or
- wait until the subagent finishes, then continue it as a session of its
  own, made from its transcript.
