#!/bin/bash
# Run inside a session's container (a second command on its socket, beside
# the session's agent): Claude Code with Visor's arguments added one at a
# time, each given one message on a held-open stdin and 40 s to answer, to
# find which of them keeps it from answering there.
#   oss machine exec --socket=<the lease's socket> --env-file=<the session's .env> -- bash -s < tools/probes/claude_variants.sh
# Each line: the variant, how long it took, and its result (or NO RESULT).
message='{"type":"user","message":{"role":"user","content":"Reply with exactly the word CONTAINED and nothing else."}}'
mcp='{"mcpServers":{"visor":{"command":"node","args":["/opt/visor/visor_mcp.js"],"env":{"VISOR_URL":"'"${VISOR_URL:-}"'","VISOR_TOKEN":"'"${VISOR_TOKEN:-}"'","VISOR_SESSION":"'"${VISOR_SESSION:-}"'","VISOR_APPROVALS":"1"}}}}'
base=(-p --input-format stream-json --output-format stream-json --verbose)

run() {
  local name="$1"; shift
  local started=$SECONDS
  local result
  # The result line (its "result" may come before or after its "type").
  result=$( { echo "$message"; sleep 45; } | timeout 40 claude "$@" 2>&1 | grep '"type":"result"' | grep -o '"result":"[^"]*"' | head -1 )
  echo "$name: $((SECONDS - started)) s ${result:-NO RESULT}"
}

run base "${base[@]}"
run partial "${base[@]}" --include-partial-messages
run bypass "${base[@]}" --permission-mode bypassPermissions
run mcp "${base[@]}" --mcp-config "$mcp"
run prompt-tool "${base[@]}" --mcp-config "$mcp" --permission-prompt-tool mcp__visor__approve
run visor "${base[@]}" --include-partial-messages --mcp-config "$mcp" --permission-mode bypassPermissions \
  --permission-prompt-tool mcp__visor__approve
