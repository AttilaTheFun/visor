# Sub-sessions (design)

A session can open sub-sessions: a fork of it, a branch of it, a side
question (`/btw`), or one of its agent's subagents. Each has a chat page
of its own, opened from its parent.
Status: 0.43. Built for Claude: forks, branches (`/branch`, and Branch
from Here under a reply), side questions, and subagents (listed, read,
messaged through the parent while they run, gone on with as sessions
once finished); for Codex, forks and branches. Still to come: Codex's
side questions and subagents, and Branch from Here on Codex.

## What each one is

**Fork**: `/fork <prompt>`. A copy of the conversation so far, which
starts on the prompt while the parent goes on with its own work.
- Claude: `--resume <parent> --fork-session`; the new id comes from
  `system/init`.
- Codex: `thread/fork`.

It is a session of its own: same folder, same computer or container,
same model and permissions. It carries `parent` and `origin: fork`.

**Branch**: `/branch [name]`, or Branch from Here under one of the
agent's replies, beside Copy and Share. A copy of the conversation up to
that point (through the reply's turn), idle, for the person to go on
from.
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
  `<session>/subagents/agent-*.jsonl`. They are kept out of the
  session's own status and context count.
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

## Talking to a subagent

- **Codex:** its subagents are threads, so a turn is started on one
  directly.
- **Claude, while the subagent runs:** Claude's `-p` mode drops a person's
  message aimed at a subagent (a user message with `parent_tool_use_id`),
  and only the parent agent reaches a running subagent, with its
  SendMessage tool. So a message from the subagent's page goes through
  the parent, which forwards it with SendMessage. It costs the parent's
  context and a turn.
- **Claude, once the subagent has finished:** it goes on as a session of
  its own, made from its transcript. The first message from its page
  makes it (`fork` with the `subagent` origin): the server copies the
  subagent's records into a session file of Claude Code's beside the
  parent's, no longer marked a sidechain, and resumes that. The new
  session is a child of the parent, titled with the subagent's
  description; its row and capsule take the subagent's place, and its
  chat takes the subagent page's.
