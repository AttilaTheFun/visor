import { execSync } from 'node:child_process';
// The server's port: the installed one's, or a staging server's (VISOR_PORT).
const PORT = Number(process.env.VISOR_PORT ?? 7433);
const PW = process.env.VISOR_ADMIN_TOKEN || (() => { console.error('VISOR_ADMIN_TOKEN is unset: give the server\'s admin token (or a staging server\'s password). A session\'s own VISOR_TOKEN is for its own actions only.'); process.exit(2); })();
const id = process.argv[2]; if (!id) { console.error('usage: node ephemeral.mjs <visor session id>'); process.exit(2); }
const ws = new WebSocket(`ws://127.0.0.1:${PORT}`);
ws.onopen = () => ws.send(JSON.stringify({ type: 'login', password: PW, client: 'probe-eph' }));
ws.onmessage = ev => {
  const e = JSON.parse(ev.data);
  if (e.type === 'welcome') { ws.send(JSON.stringify({ type: 'subscribe', session: id })); return; }
  if (e.type === 'ephemeral') {
    console.log('busy', e.busy, 'activity', JSON.stringify(e.activity), 'status', (e.status ?? []).length, 'streams', (e.streams ?? []).length);
    for (const s of e.streams ?? []) console.log('  stream', s.id, JSON.stringify(s.text.slice(0, 80)), 'len', s.text.length);
    ws.close(); process.exit(0);
  }
};
setTimeout(() => { console.log('timeout'); process.exit(1); }, 8000);
