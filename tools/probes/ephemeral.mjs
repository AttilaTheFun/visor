import { execSync } from 'node:child_process';
const PW = process.env.VISOR_TOKEN || execSync('security find-generic-password -s com.LoganShire.VisorServer.macOS -a password -w').toString().trim();
const id = process.argv[2]; if (!id) { console.error('usage: node ephemeral.mjs <visor session id>'); process.exit(2); }
const ws = new WebSocket('ws://127.0.0.1:7433');
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
