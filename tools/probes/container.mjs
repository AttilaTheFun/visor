// Throwaway-session probe for a session in a container, end to end: started
// in a container on a folder (leased from this computer's OS Server), told
// to answer a word, then ended (its container released). Run it against a
// staging server beside the installed one, with OS Server 0.9 or later on
// the same Mac:
//   VISOR_STAGING_LAN=1 VISOR_STAGING_OSS=http://127.0.0.1:7480 \
//     VISOR_STAGING_OSS_TOKEN_FILE=<oss's token file> bazel run //tools/staging_server -- 7534
//   VISOR_PORT=7534 VISOR_TOKEN=staging node tools/probes/container.mjs <folder> [claude|codex|openrouter]
// It prints each step with its time, and exits 0 once the agent in the
// container has answered and the session has ended.
const PORT = Number(process.env.VISOR_PORT ?? 7533);
const PW = process.env.VISOR_TOKEN ?? 'staging';
const folder = process.argv[2];
if (!folder) { console.error('usage: node container.mjs <folder> [agent]'); process.exit(2); }
const agent = process.argv[3] ?? 'claude';
const id = crypto.randomUUID().toUpperCase();
const t0 = Date.now();
const log = (...a) => console.log(((Date.now() - t0) / 1000).toFixed(1).padStart(6), ...a);
let phase = 'signing in';
let answered = false;

const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
const send = o => ws.send(JSON.stringify(o));
const finish = () => {
  phase = 'ending';
  send({ type: 'end', session: id });
  // The container is released after the session goes.
  setTimeout(() => { log(answered ? 'done' : 'ended without an answer'); process.exit(answered ? 0 : 1); }, 5000);
};
ws.onopen = () => send({ type: 'login', password: PW, client: 'probe-container' });
ws.onmessage = ev => {
  const e = JSON.parse(ev.data);
  if (e.type === 'welcome') {
    log('signed in; containers on offer:', e.container === true);
    if (e.container !== true) { log('this server offers no containers'); process.exit(1); }
    phase = 'starting';
    send({ type: 'start', id, agent, cwd: folder, title: 'Container probe', skipPermissions: true, container: true });
    return;
  }
  if (e.type === 'error') { log('error:', e.message); return finish(); }
  if (e.type === 'sessions' && phase === 'starting') {
    const session = (e.sessions ?? []).find(s => s.id === id);
    if (!session?.container) return;
    log('in its container:', JSON.stringify(session.container));
    phase = 'asking';
    send({ type: 'subscribe', session: id });
    send({ type: 'send', session: id, text: 'Reply with exactly the word CONTAINED and nothing else.' });
    return;
  }
  if (e.session !== id) return;
  // The agent's own failure: it did not start (the transcript's error), or
  // it failed its turn (not signed in in the container, say).
  if (phase === 'asking' && (e.type === 'failure' || (e.type === 'transcript' && e.error))) {
    log('the agent failed:', e.message ?? e.error);
    return finish();
  }
  if (['transcript', 'entry'].includes(e.type)) {
    for (const row of e.entries ?? []) {
      if (row.role !== 'assistant' || !row.text || answered) continue;
      log('the agent:', JSON.stringify(row.text.slice(0, 200)));
      answered = true;
      finish();
    }
  }
};
setTimeout(() => { log('no answer in five minutes, while', phase); finish(); }, 300_000);
