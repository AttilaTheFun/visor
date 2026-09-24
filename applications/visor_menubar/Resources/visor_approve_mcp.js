// Claude Code's permission prompt, answered from a Visor client. Claude runs
// this as an MCP server (--permission-prompt-tool mcp__visor__approve) and
// calls `approve` whenever a tool needs permission in manual mode; the call
// is forwarded to the menu bar app over its WebSocket, which shows it on the
// phone and answers when the user taps Allow or Deny.
//
// Env: VISOR_PORT, VISOR_TOKEN (the app's agent-side secret), VISOR_SESSION.
const port = process.env.VISOR_PORT || "7433";
const token = process.env.VISOR_TOKEN || "";
const session = process.env.VISOR_SESSION || "";

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
    send({ jsonrpc: "2.0", id, result: { tools: [{
      name: "approve",
      description: "Asks the Visor user to allow or deny a tool call.",
      inputSchema: { type: "object", properties: { tool_name: { type: "string" }, input: { type: "object" }, tool_use_id: { type: "string" } } },
    }] } });
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
