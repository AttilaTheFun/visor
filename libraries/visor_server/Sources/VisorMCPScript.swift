// Visor's MCP server, as Node runs it: the script itself, kept here so
// every build of the server has it without a bundle to carry it in. The
// server writes it into its data directory and points the agents at that
// file (VisorMCP.swift).

enum VisorMCPScript {
    static let source = #"""
// Visor's MCP server, run by every agent session the menu bar app starts.
// Its tools let a session see the other sessions on this computer and on
// the computers Visor's clients report, message them, read what they said,
// and ask what became of a message sent to another computer (carried
// there by a client connected to both). In manual mode Claude also calls
// `approve` (--permission-prompt-tool mcp__visor__approve) whenever a tool
// needs permission, which the phone shows until the user taps Allow or
// Deny. Every call goes to the menu bar app over its WebSocket.
//
// Env: VISOR_PORT, VISOR_TOKEN (the app's agent-side secret), VISOR_SESSION,
// VISOR_APPROVALS ("1": offer `approve`; for Claude always, so that its
// questions (AskUserQuestion) come to the user, and in manual mode every
// tool call too), and VISOR_URL where the server is not this computer's
// own (an agent in a container on oss: ws://host:port).
//
// It also lists, beside its own, the tools of the MCP servers the computer
// passes on to this session (`<endpoint>__<tool>`), each call passed on by
// the server with the session's headers; it looks again every 30 s and
// tells the agent when they changed (tools/list_changed).
const port = process.env.VISOR_PORT || "7433";
const serverURL = process.env.VISOR_URL || `ws://127.0.0.1:${port}`;
const token = process.env.VISOR_TOKEN || "";
const session = process.env.VISOR_SESSION || "";
const approvals = process.env.VISOR_APPROVALS === "1";

// What the agent is told of where it runs: `initialize`'s instructions,
// which Claude Code puts in its system prompt. A container (VISOR_URL set)
// is told what is its own and what is the computer's.
const contained = !!process.env.VISOR_URL;
const instructions = [
  "You run under Visor: the person follows this session in Visor on a phone or a Mac, not in a terminal.",
  "An image you read with the Read tool (a screenshot, say) is shown in the chat: to show the person an image, read it.",
  "`visor` (on your path) leases machines from the OS Servers this computer knows: macOS, Linux and Windows VMs, iOS simulators, Android emulators. `visor machine status`, `visor machine lease <platform>`, and `visor` alone for the rest.",
  ...(contained ? [
    "You run in a Linux container on the computer, and see of it only the session's folder, at the same path: files meant for the person go there, not in this container's /tmp, which they cannot open.",
    "Bazel's output in this container is its own: a checkout's bazel-bin links are the computer's builds, not yours. Find what you built with `bazel cquery --output=files <target>`.",
  ] : []),
].join("\n");

const tools = [
  {
    name: "list_sessions",
    description: "Lists the other agent sessions Visor runs on this computer, and those on the other computers a Visor client connected to this one reports (the phone or Mac the user runs Visor on): id, title, agent, whether it is working; each computer with its name and server id.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "send_message",
    description: "Sends a message to another Visor session, named by its session id and its computer's server id (both from list_sessions), as a new turn for that agent. It is headed with this session's name, id and computer, so the other agent knows exactly who sent it and how to answer, and that it is not from the user. If the session is working, the message waits for its turn to end. A session on another computer is reached through a Visor client connected to both: the answer says whether it was taken, or that it waits for such a client (kept for a day), with a message id for message_status.",
    inputSchema: {
      type: "object",
      properties: {
        session: { type: "string", description: "The session's id, from list_sessions." },
        server: { type: "string", description: "The server id of the computer the session is on, from list_sessions (this computer's too). When answering a message, the server its header names." },
        text: { type: "string", description: "What to say." },
      },
      required: ["session", "server", "text"],
    },
  },
  {
    name: "read_messages",
    description: "Reads the latest messages of another Visor session (the user's, the agent's and tool results), oldest first. On another computer, the read is carried by a Visor client connected to both; if none carries it within a few seconds, the answer gives a message id for message_status.",
    inputSchema: {
      type: "object",
      properties: {
        session: { type: "string", description: "The session's id, from list_sessions." },
        server: { type: "string", description: "The server id of the computer the session is on, from list_sessions (this computer's too)." },
        count: { type: "number", description: "How many messages, 1 to 50. Defaults to 10." },
      },
      required: ["session", "server"],
    },
  },
  {
    name: "message_status",
    description: "Tells what became of a message (or read) sent to a session on another computer: waiting for a Visor client connected to both computers, sent, queued while that agent works, read (with what it found), not taken, or expired after a day.",
    inputSchema: {
      type: "object",
      properties: {
        message_id: { type: "string", description: "The message id send_message or read_messages gave." },
      },
      required: ["message_id"],
    },
  },
];
const approveTool = {
  name: "approve",
  description: "Asks the Visor user to allow or deny a tool call.",
  inputSchema: { type: "object", properties: { tool_name: { type: "string" }, input: { type: "object" }, tool_use_id: { type: "string" } } },
};

// The proxied tools, as last listed to the agent: what a later look is
// held against.
let listedProxied = null;
let watching = false;
const proxiedSignature = (list) => JSON.stringify(list.map((tool) => [tool.name, tool.description || "", tool.inputSchema || null]));

// The session's proxied tools, from the server; none when it can't say.
function proxiedTools() {
  return call({ mode: "mcp_tools" }).then(({ ok, text }) => {
    if (!ok) return [];
    try { const list = JSON.parse(text); return Array.isArray(list) ? list : []; } catch { return []; }
  });
}

// Every 30 s: the proxied tools as they are now, and a word to the agent
// when they differ from what it was last given.
function watchProxied() {
  if (watching) return;
  watching = true;
  setInterval(() => {
    proxiedTools().then((list) => {
      if (listedProxied !== null && proxiedSignature(list) !== listedProxied) {
        listedProxied = proxiedSignature(list);
        send({ jsonrpc: "2.0", method: "notifications/tools/list_changed" });
      }
    });
  }, 30000).unref();
}

let buffer = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let index;
  while ((index = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, index).trim();
    buffer = buffer.slice(index + 1);
    if (line) handle(line);
  }
});

function send(message) { process.stdout.write(JSON.stringify(message) + "\n"); }

function handle(line) {
  let request;
  try { request = JSON.parse(line); } catch { return; }
  const { id, method, params } = request;
  if (method === "initialize") {
    send({ jsonrpc: "2.0", id, result: { protocolVersion: params?.protocolVersion || "2024-11-05", capabilities: { tools: { listChanged: true } }, serverInfo: { name: "visor", version: "1.0" }, instructions } });
  } else if (method === "notifications/initialized") {
    watchProxied();
  } else if (method === "tools/list") {
    proxiedTools().then((proxied) => {
      listedProxied = proxiedSignature(proxied);
      send({ jsonrpc: "2.0", id, result: { tools: [...(approvals ? [approveTool] : []), ...tools, ...proxied] } });
    });
  } else if (method === "tools/call" && params?.name?.includes("__")) {
    // A proxied tool: the server passes it on, and its result comes back
    // as the endpoint gave it.
    call({ mode: "mcp_call", text: JSON.stringify({ tool: params.name, arguments: params?.arguments || {} }) }).then(({ ok, text }) => {
      if (!ok) { send({ jsonrpc: "2.0", id, result: { isError: true, content: [{ type: "text", text }] } }); return; }
      let result;
      try { result = JSON.parse(text); } catch { result = { content: [{ type: "text", text }] }; }
      send({ jsonrpc: "2.0", id, result });
    });
  } else if (method === "tools/call" && params?.name !== "approve") {
    const args = params?.arguments || {};
    const mode = { list_sessions: "sessions", send_message: "send", read_messages: "read", message_status: "status" }[params?.name];
    if (!mode) {
      send({ jsonrpc: "2.0", id, result: { isError: true, content: [{ type: "text", text: `No tool ${params?.name}` }] } });
      return;
    }
    // The names an agent reaches for when it has lost the schema
    // (session_id, server_id) are taken too; a session left out is said
    // plainly, not answered as one that does not exist.
    const session = args.session ?? args.session_id;
    const server = args.server ?? args.server_id;
    if ((mode === "send" || mode === "read") && !session) {
      send({ jsonrpc: "2.0", id, result: { isError: true, content: [{ type: "text", text: `${params.name} needs \`session\` and \`server\`: a session id and its computer's server id, from list_sessions.` }] } });
      return;
    }
    call({ mode, session, server, messageID: args.message_id ?? args.messageID, text: args.text ?? args.message,
           rows: args.count === undefined ? undefined : Math.round(Number(args.count)) })
      .then(({ ok, text }) => send({ jsonrpc: "2.0", id, result: { isError: !ok, content: [{ type: "text", text }] } }));
  } else if (method === "tools/call") {
    const args = params?.arguments || {};
    ask(args).then(({ allow, answers }) => {
      // A question's answers go back in the tool's own input, as Claude
      // Code takes them: { answers: { <question>: <answer> } }.
      const input = args.input || {};
      const decision = allow
        ? { behavior: "allow", updatedInput: answers ? { ...input, answers } : input }
        : { behavior: "deny", message: args.tool_name === "AskUserQuestion" ? "The user did not answer from Visor." : "The user denied this from Visor." };
      send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify(decision) }] } });
    });
  } else if (method === "ping") {
    send({ jsonrpc: "2.0", id, result: {} });
  } else if (id !== undefined) {
    send({ jsonrpc: "2.0", id, error: { code: -32601, message: `unknown method ${method}` } });
  }
}

// One request to the menu bar app about the other sessions.
function call(fields) {
  return new Promise((resolve) => {
    const requestID = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    let ws;
    try { ws = new WebSocket(serverURL); } catch { resolve({ ok: false, text: "Visor is not reachable." }); return; }
    let settled = false;
    const done = (result) => { if (settled) return; settled = true; try { ws.close(); } catch {} resolve(result); };
    ws.onopen = () => ws.send(JSON.stringify({ type: "agent", token, client: session, id: requestID, ...fields }));
    ws.onmessage = (m) => {
      let e; try { e = JSON.parse(m.data); } catch { return; }
      if (e.type === "agent_result" && e.id === requestID) done(e.error ? { ok: false, text: e.error } : { ok: true, text: e.text || "" });
    };
    ws.onerror = () => done({ ok: false, text: "Visor is not reachable." });
    ws.onclose = () => done({ ok: false, text: "Visor closed the connection." });
  });
}

function ask(args) {
  return new Promise((resolve) => {
    const requestID = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    let ws;
    const no = { allow: false };
    try { ws = new WebSocket(serverURL); } catch { resolve(no); return; }
    const done = (result) => { try { ws.close(); } catch {} resolve(result); };
    const questions = args.tool_name === "AskUserQuestion" ? args.input?.questions : undefined;
    ws.onopen = () => ws.send(JSON.stringify({
      type: "approval_request", token, session, id: requestID,
      text: args.tool_name || "tool", prompt: questions ? (questions[0]?.question || "") : summary(args.input),
      ...(questions ? { questions } : {}),
    }));
    ws.onmessage = (m) => {
      let e; try { e = JSON.parse(m.data); } catch { return; }
      if (e.type === "approval_result" && e.id === requestID) done({ allow: e.busy === true, answers: e.answers });
      if (e.type === "error") done(no);
    };
    ws.onerror = () => done(no);
    ws.onclose = () => resolve(no);
  });
}

function summary(input) {
  if (!input || typeof input !== "object") return "";
  for (const key of ["command", "file_path", "path", "pattern", "query", "url", "description", "prompt"]) {
    if (typeof input[key] === "string" && input[key]) return input[key].split("\n")[0].slice(0, 200);
  }
  const first = Object.values(input).find((v) => typeof v === "string");
  return first ? first.split("\n")[0].slice(0, 200) : "";
}
"""#
}
