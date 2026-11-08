# Agents' inboxes and outboxes (design)

Logan, 7 Nov 2026: "Instead of your messages being interleaved with the
user's messages I'd like agents to have an inbox and an outbox. When they
send a message with the visor mcp it is still delivered through the clients
but a copy is retained on both the source and target servers (which may be
the same) once it is delivered. … Ideally this doesn't have to be a message
in the transcript and the agent can be notified."

## Decided (Logan, 7 Nov)

- **A notice turn for every agent** (channels were the plan for Claude,
  dropped on 8 Nov: "Telling the agent"). The agent is told only how many
  messages are unread ("You have 4 unread messages"), never their text, so
  as not to fill its context: it reads them with `read_inbox`.
- **The boxes keep their messages for the session's lifetime**, as its
  transcript is kept.

## Today

- `send_message(session, server, text)` from Visor's MCP server
  (docs/protocol.md, "Sessions messaging each other"). To a session on the
  same server, the message is delivered at once. To another server, it waits
  in this server's relay outbox until a client connected to both carries it
  (`POST /api/relay/deliver`), and the receipt comes back the same way.
- Delivered, it is a **new turn of the user's**, headed `[Message from the
  Visor session … — not from the user. To answer, use send_message …]`,
  queued while the agent works. It sits in the transcript among the
  person's own messages, and nothing keeps it apart from them.
- Neither end keeps the message once it is delivered; the relay keeps only
  what became of it (two days), for `message_status`.

## The model

- **Every session has an inbox and an outbox**, kept by its server with the
  session (in the server's store, as its rows are) for as long as the
  session is kept, and deleted with it.
  - **Outbox:** each message the session sent: its id, to whom (server,
    session, their names), text, when sent, and what became of it
    (`waiting`, `delivered`, `read`, `failed`, `expired`).
  - **Inbox:** each message it was sent: its id, from whom, text, when
    delivered, and whether the agent has read it.
- **Delivery is as today**: on one server at once, between servers through
  the clients (the relay, unchanged on the wire). Once delivered, a copy is
  in the target's inbox and the source's outbox; when both are one server,
  that server keeps both.
- **The message is not a turn of the user's.** The agent is told it has
  mail (below) and reads it with a tool. In Visor's chat it shows as a row
  of its own, "✉ From Isomer: …", which opens the message, and never as the
  person's bubble.
- **The person sees both boxes**: in the session's inspector, an Inbox and
  an Outbox, each message with its sender or recipient, its state, and its
  text.

## Telling the agent

- **Every agent: a notice turn.** Visor starts a turn whose whole input is
  one line, `[Visor: you have 4 unread messages in your inbox; read them
  with read_inbox]`, queued while the agent works, as other messages are.
  The messages themselves stay in the inbox. Visor knows the notice by its
  form and shows it as the mail row, not as the person's. An agent may also
  look at its inbox when it likes (`read_inbox`).
- **Messages arriving together are one notice**: one waiting while the
  agent works counts what is unread when its turn comes.
- **No channel** (Logan, 8 Nov 2026). Claude Code's channel notification
  (`notifications/claude/channel`, a meta prompt rather than the user's
  turn) was the plan for Claude. It is dropped: Codex has no such thing, and
  Claude Code 2.1.318 takes a channel only with `--channels <server>`, managed
  settings saying `channelsEnabled: true` and the server on
  `allowedChannelPlugins` (its one way around them,
  `--dangerously-load-development-channels`, asks for a confirmation at
  startup, so not headless). It isn't worth managed settings on every Mac
  and container for one agent of two.

## The MCP tools

- `send_message(session, server, text)`: as now; the message goes in the
  sender's outbox at once (`waiting`), its id in the answer.
- `read_inbox(unread_only = true, count = 10)`: the inbox's messages, newest
  last, each with its id, sender and text; those read are marked read, and
  the sender's outbox learns it (`read`), through the relay when it is
  another server.
- `read_outbox(count = 10)`: what the session sent and what became of each.
- `message_status(message_id)`: as now, from the outbox.
- `list_sessions`, `read_messages`: as now.

## The wire

- **Same server:** delivered in the server; both boxes written; the target's
  agent told.
- **Across servers:** the relay's `RelayMessage` and `RelayReceipt` as now.
  The receipt's `outcome` gains `delivered` (in the inbox) and, later,
  `read`. A read receipt is a relay message of its own (`kind: receipt`),
  from the target's server to the source's.
- **Servers from before** take the message as today's turn. The relay's
  `kind` tells a new server apart, and a new server sending to an old one
  gets `queued` or `sent` back as now.

## Steps

1. This design.
2. The boxes in the server's store, `read_inbox`, `read_outbox`, and
   same-server delivery into them; the notice turn for every agent. Built:
   a message carried from another server goes into the inbox too, and a
   message sent to one waits in the outbox until the relay's receipt says
   it was delivered (or failed, or expired). An agent an earlier launch
   left running may have no `read_inbox`: it is handed messages as turns
   until its MCP server says `version` `"mail"` or its agent is made again.
3. The relay's `delivered` and read receipts across servers. Built: the
   sender's server takes `sent` and `queued` as delivered, so the receipt's
   outcomes are as before; a read receipt is a relay message of its own
   (`kind: receipt`), sent only to a server reported at 0.47 or later.
4. ~~Claude's channel~~: dropped (Logan, 8 Nov 2026; "Telling the agent").
5. The client: the mail row in the chat, and the inspector's Inbox and
   Outbox. Built: the inspector's boxes (#281) and the mail row (#282, on
   AgentUI 0.47.0's MailRow).

## Later

- Writing into an agent's inbox from the inspector, apart from the chat, if
  wanted.
