import VisorProtocol

/// What the MCP server offers an agent, as the Node script did: its tools
/// (the other sessions: list, message, read, a message's fate), `approve`
/// for Claude's permission prompt, and the words `initialize` gives, which
/// Claude Code puts in its system prompt.
enum MCPTools {
    /// The words of `initialize`. In a container the agent is told what is
    /// its own and what is the computer's.
    static func instructions(contained: Bool) -> String {
        var lines = [
            "You run under Visor: the person follows this session in Visor on a phone or a Mac, not in a terminal.",
            "An image you read with the Read tool (a screenshot, say) is shown in the chat: to show the person an image, read it.",
        ]
        if contained {
            lines += [
                "You run in a Linux container on the computer, and see of it only the session's folder, at the same path: files meant for the person go there, not in this container's /tmp, which they cannot open.",
                "Bazel's output in this container is its own: a checkout's bazel-bin links are the computer's builds, not yours. Find what you built with `bazel cquery --output=files <target>`.",
            ]
        }
        return lines.joined(separator: "\n")
    }

    /// The tool a call to the server is, by the tool's name.
    static let modes = ["list_sessions": "sessions", "send_message": "send", "read_messages": "read", "message_status": "status",
                        "read_inbox": "inbox", "read_outbox": "outbox"]

    /// The session tools, every agent's.
    static let sessions: [JSONValue] = parseJSON(#"""
    [
      {
        "name": "list_sessions",
        "description": "Lists the other agent sessions Visor runs on this computer, and those on the other computers a Visor client connected to this one reports (the phone or Mac the user runs Visor on): id, title, agent, whether it is working; each computer with its name and server id.",
        "inputSchema": { "type": "object", "properties": {} }
      },
      {
        "name": "send_message",
        "description": "Sends a message to another Visor session, named by its session id and its computer's server id (both from list_sessions). It goes into that session's inbox, with this session's name, id and computer, so the other agent knows exactly who sent it and how to answer, and that it is not from the user; that agent is told it has mail and reads it with read_inbox. A copy stays in this session's outbox (read_outbox). A session on another computer is reached through a Visor client connected to both: the answer says whether it was taken, or that it waits for such a client (kept for a day). The answer gives a message id for message_status.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session": { "type": "string", "description": "The session's id, from list_sessions." },
            "server": { "type": "string", "description": "The server id of the computer the session is on, from list_sessions (this computer's too). When answering a message, the server its header names." },
            "text": { "type": "string", "description": "What to say." }
          },
          "required": ["session", "server", "text"]
        }
      },
      {
        "name": "read_messages",
        "description": "Reads the latest messages of another Visor session (the user's, the agent's and tool results), oldest first. On another computer, the read is carried by a Visor client connected to both; if none carries it within a few seconds, the answer gives a message id for message_status.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "session": { "type": "string", "description": "The session's id, from list_sessions." },
            "server": { "type": "string", "description": "The server id of the computer the session is on, from list_sessions (this computer's too)." },
            "count": { "type": "number", "description": "How many messages, 1 to 50. Defaults to 10." }
          },
          "required": ["session", "server"]
        }
      },
      {
        "name": "message_status",
        "description": "Tells what became of a message (or read) this session sent: in the other session's inbox unread, read, waiting for a Visor client connected to both computers, not taken, or expired after a day; for a read of another computer's session, what it found.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "message_id": { "type": "string", "description": "The message id send_message or read_messages gave." }
          },
          "required": ["message_id"]
        }
      },
      {
        "name": "read_inbox",
        "description": "Reads the messages other Visor sessions sent this one, oldest first, each with its message id, who sent it (session and computer, by name and id) and how to answer. Those read are marked read, and their senders can see it. Visor tells this session when it has unread messages, with how many.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "unread_only": { "type": "boolean", "description": "Only the unread messages (the default); false for the latest ones, read or not." },
            "count": { "type": "number", "description": "How many messages, 1 to 50. Defaults to 10." }
          }
        }
      },
      {
        "name": "read_outbox",
        "description": "Lists the messages this session sent to other Visor sessions, oldest first, and what became of each: in their inbox unread, read, waiting to be carried to another computer, not taken, or expired.",
        "inputSchema": {
          "type": "object",
          "properties": {
            "count": { "type": "number", "description": "How many messages, 1 to 50. Defaults to 10." }
          }
        }
      }
    ]
    """#)?.array ?? []

    /// Claude's permission prompt (--permission-prompt-tool mcp__visor__approve).
    static let approve: JSONValue = parseJSON(#"""
    {
      "name": "approve",
      "description": "Asks the Visor user to allow or deny a tool call.",
      "inputSchema": { "type": "object", "properties": { "tool_name": { "type": "string" }, "input": { "type": "object" }, "tool_use_id": { "type": "string" } } }
    }
    """#) ?? .null

    /// A line of a tool call's input for the prompt: its command, file,
    /// pattern or the like, else its first string.
    static func summary(_ input: JSONValue) -> String {
        guard let fields = input.object else { return "" }
        func line(_ text: String) -> String { String((text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "").prefix(200)) }
        for key in ["command", "file_path", "path", "pattern", "query", "url", "description", "prompt"] {
            if let text = fields[key]?.string, !text.isEmpty { return line(text) }
        }
        let first = fields.keys.sorted().lazy.compactMap { fields[$0]?.string }.first
        return first.map(line) ?? ""
    }
}
