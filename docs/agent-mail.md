# Agents' inboxes and outboxes (design)

Logan, 7 Nov 2026: "Instead of your messages being interleaved with the
user's messages I'd like agents to have an inbox and an outbox. When they
send a message with the visor mcp it is still delivered through the clients
but a copy is retained on both the source and target servers (which may be
the same) once it is delivered. … Ideally this doesn't have to be a message
in the transcript and the agent can be notified."

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
  session (in the server's store, as its rows are), until the session is
  deleted.
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

- **Claude: a channel notification.** Visor's MCP server
  (`visor-agent-host mcp`) declares Claude Code's channel capability
  (`experimental: {"claude/channel": {}}`) and, when the agent's inbox gets
  a message, sends `notifications/claude/channel` with a short notice and
  the message's id in `meta`. Claude Code takes a channel message as a meta
  prompt for its next turn (`origin: channel`, not the user's), starting one
  if the session is idle. The server tells the MCP server over the
  WebSocket it already holds (a subscription per session).
  - It needs Claude Code launched with `--channels visor`, and channels
    allowed by managed settings (`channelsEnabled: true`, and Visor's
    channel allowed, `allowedChannelPlugins`). In a container Visor writes
    those in its image's `/etc/claude-code/managed-settings.json`. On a Mac
    they are an administrator's: Visor says so in Settings, and until then
    falls back to the notice below. The fork's organisation decides its own.
  - **To verify first**, in a throwaway session: that a channel message
    wakes an idle stream-json session, how it lands in the session's file
    (Visor shows it as the mail row, not a user row), and whether
    `--dangerously-load-development-channels` asks for a confirmation
    headless.
- **Codex, and Claude without channels: a notice turn.** Codex's app server
  takes input only as the user's (`turn/start`, `turn/steer`). Visor starts
  a turn whose whole input is a one-line notice, `[Visor: a message from
  "Isomer" is in your inbox: read it with read_inbox]`, queued while the
  agent works, as today's messages are. The text itself stays in the inbox.
  Visor knows the notice by its form and shows it as the mail row, not as
  the person's.
- Either way, **several messages arriving together are one notice**.

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

1. This design, and the channel checks above in a throwaway session.
2. The boxes in the server's store, `read_inbox`, `read_outbox`, and
   same-server delivery into them; the notice turn for every agent.
3. The relay's `delivered` and read receipts across servers.
4. Claude's channel: Visor's MCP server's capability and notification,
   `--channels`, and the container image's managed settings.
5. The client: the mail row in the chat, and the inspector's Inbox and
   Outbox.

## Questions for Logan

1. **What the agent is told**: only that there is mail (it reads it with
   `read_inbox`, one more call), or the message itself in the notice (no
   call, but its text is then in the agent's context as a meta prompt)?
   Proposed: the message itself through Claude's channel, where it isn't a
   turn of the user's; only a notice for Codex, where it would be.
2. **How long the boxes keep messages**: with the session until it is
   deleted (proposed), or a cap (the last 500 of each)?
3. **Messages from the person**: should the person be able to write into an
   agent's inbox from the inspector, apart from the chat?
