// Visor's MCP server, run by every agent session the menu bar app starts.
// Its tools let a session see the other sessions on this computer, message
// them, and read what they said. In manual mode Claude also calls
// `approve` (--permission-prompt-tool mcp__visor__approve) whenever a tool
// needs permission, which the phone shows until the user taps Allow or
// Deny. Every call goes to the menu bar app over its WebSocket.
//
// Env: VISOR_PORT, VISOR_TOKEN (the app's agent-side secret), VISOR_SESSION,
// VISOR_APPROVALS ("1" in manual mode: offer `approve`).
const port = process.env.VISOR_PORT || "7433";
const token = process.env.VISOR_TOKEN || "";
const session = process.env.VISOR_SESSION || "";
const approvals = process.env.VISOR_APPROVALS === "1";

const tools = [
  {
    name: "list_sessions",
    description: "Lists the other agent sessions Visor runs on this computer: id, title, agent, whether it is working, and its folder.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "send_message",
    description: "Sends a message to another Visor session, as a new turn for that agent. It is marked as coming from this session, not the user. If the session is working, the message waits for its turn to end.",
    inputSchema: {
      type: "object",
      properties: {
        session: { type: "string", description: "The session's id, from list_sessions." },
        text: { type: "string", description: "What to say." },
      },
      required: ["session", "text"],
    },
  },
  {
    name: "read_messages",
    description: "Reads the latest messages of another Visor session (the user's, the agent's and tool results), oldest first.",
    inputSchema: {
      type: "object",
      properties: {
        session: { type: "string", description: "The session's id, from list_sessions." },
        count: { type: "number", description: "How many messages, 1 to 50. Defaults to 10." },
      },
      required: ["session"],
    },
  },
];
const approveTool = {
  name: "approve",
  description: "Asks the Visor user to allow or deny a tool call.",
  inputSchema: { type: "object", properties: { tool_name: { type: "string" }, input: { type: "object" }, tool_use_id: { type: "string" } } },
};

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
    send({ jsonrpc: "2.0", id, result: { protocolVersion: params?.protocolVersion || "2024-11-05", capabilities: { tools: {} }, serverInfo: { name: "visor", version: "1.0" } } });
  } else if (method === "tools/list") {
    send({ jsonrpc: "2.0", id, result: { tools: approvals ? [approveTool, ...tools] : tools } });
  } else if (method === "tools/call" && params?.name !== "approve") {
    const args = params?.arguments || {};
    const mode = { list_sessions: "sessions", send_message: "send", read_messages: "read" }[params?.name];
    if (!mode) {
      send({ jsonrpc: "2.0", id, result: { isError: true, content: [{ type: "text", text: `No tool ${params?.name}` }] } });
      return;
    }
    call({ mode, session: args.session, text: args.text, rows: args.count === undefined ? undefined : Math.round(Number(args.count)) })
      .then(({ ok, text }) => send({ jsonrpc: "2.0", id, result: { isError: !ok, content: [{ type: "text", text }] } }));
  } else if (method === "tools/call") {
    ask(params?.arguments || {}).then((allow) => {
      const decision = allow
        ? { behavior: "allow", updatedInput: params?.arguments?.input || {} }
        : { behavior: "deny", message: "The user denied this from Visor." };
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
    try { ws = new WebSocket(`ws://127.0.0.1:${port}`); } catch { resolve({ ok: false, text: "Visor is not reachable." }); return; }
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
    try { ws = new WebSocket(`ws://127.0.0.1:${port}`); } catch { resolve(false); return; }
    const done = (allow) => { try { ws.close(); } catch {} resolve(allow); };
    ws.onopen = () => ws.send(JSON.stringify({
      type: "approval_request", token, session, id: requestID,
      text: args.tool_name || "tool", prompt: summary(args.input),
    }));
    ws.onmessage = (m) => {
      let e; try { e = JSON.parse(m.data); } catch { return; }
      if (e.type === "approval_result" && e.id === requestID) done(e.busy === true);
      if (e.type === "error") done(false);
    };
    ws.onerror = () => done(false);
    ws.onclose = () => resolve(false);
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
