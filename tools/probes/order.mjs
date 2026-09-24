// Throwaway-session probe: logs the server's transcript rows (order, revision,
// generation) and socket events around two sends, then ends the session.
import http from 'node:http';
import { execSync } from 'node:child_process';
const PW = execSync('defaults read com.LoganShire.Visor.MenuBar visor.password').toString().trim();
const id = crypto.randomUUID().toUpperCase();
const AGENT = process.env.AGENT ?? 'claude';
const t0 = Date.now();
const log = (...a) => console.log(((Date.now() - t0) / 1000).toFixed(2).padStart(6), ...a);
const M1 = process.argv[2] ?? 'Run the shell command `ls /tmp/visor-probe` using your Bash tool, then reply with exactly the word ONE.';
const M2 = process.argv[3] ?? 'Reply with exactly the word TWO and nothing else.';

function rest(method, path, body) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : '';
    const req = http.request({ host: '127.0.0.1', port: 7434, path: '/api' + path, method, agent: false,
      headers: { Authorization: 'Bearer ' + PW, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } }, res => {
      let s = ''; res.on('data', d => s += d); res.on('end', () => resolve(s));
    });
    req.on('error', reject); if (data) req.write(data); req.end();
  });
}
const rowsOf = e => (e.entries ?? []).map(r => `${r.role}:${r.id.slice(0, 14)}:${JSON.stringify((r.text ?? '').slice(0, 10))}`).join(' | ');

let busy = null; let done = false;
const ws = new WebSocket('ws://127.0.0.1:7433');
const wsSend = o => ws.send(JSON.stringify(o));
await new Promise(r => ws.onopen = r);
wsSend({ type: 'login', password: PW, client: 'probe-order' });
ws.onmessage = ev => {
  const e = JSON.parse(ev.data);
  if (e.session && e.session !== id) return;
  if (e.type === 'delta') return log('ws delta', e.id?.slice(0, 14), JSON.stringify(e.text));
  if (e.type === 'busy') { busy = e.busy; return log('ws busy', e.busy); }
  if (['transcript', 'ephemeral', 'entry'].includes(e.type)) return log('ws', e.type, 'rev', e.revision, 'gen', e.generation, '[', rowsOf(e), ']', e.streams ? 'streams=' + e.streams.length : '');
  if (e.type === 'status') return log('ws status', JSON.stringify((e.status ?? []).map(i => `${i.kind}:${i.running ? 'run' : 'done'}:${i.label.slice(0, 24)}`)));
  if (['activity', 'sessions', 'welcome'].includes(e.type)) return;
  log('ws', e.type, JSON.stringify(e).slice(0, 120));
};
await new Promise(r => setTimeout(r, 300));
log('start', await rest('POST', '/sessions', { id, agent: AGENT, cwd: '/tmp/visor-probe', title: 'probe-order', skipPermissions: true }).then(s => s.slice(0, 60)));
wsSend({ type: 'subscribe', session: id });

let revision = 0;
(async () => {
  while (!done) {
    try {
      const e = JSON.parse(await rest('GET', `/sessions/${id}/transcript?since=${revision}`));
      if (e.revision !== revision) { log('poll rev', e.revision, 'gen', e.generation, '[', rowsOf(e), ']'); revision = e.revision; }
    } catch (err) { log('poll error', err.message); await new Promise(r => setTimeout(r, 500)); }
  }
})();

const waitIdle = async (limit) => { const end = Date.now() + limit; while (busy !== false && Date.now() < end) await new Promise(r => setTimeout(r, 50)); busy = null; };
await new Promise(r => setTimeout(r, 1000));
log('SEND M1', JSON.stringify(M1)); wsSend({ type: 'send', session: id, text: M1 });
await new Promise(r => setTimeout(r, 500)); await waitIdle(60000);
log('SEND M2', JSON.stringify(M2)); wsSend({ type: 'send', session: id, text: M2 });
await new Promise(r => setTimeout(r, 500)); await waitIdle(60000);
await new Promise(r => setTimeout(r, 5000));
const full = JSON.parse(await rest('GET', `/sessions/${id}/transcript?since=-1`));
log('FINAL rev', full.revision, 'gen', full.generation, '[', rowsOf(full), ']');
await new Promise((resolve) => {
  const w2 = new WebSocket('ws://127.0.0.1:7433');
  w2.onopen = () => w2.send(JSON.stringify({ type: 'login', password: PW, client: 'probe-eph' }));
  w2.onmessage = ev => { const e = JSON.parse(ev.data);
    if (e.type === 'welcome') w2.send(JSON.stringify({ type: 'subscribe', session: id }));
    if (e.type === 'ephemeral') { log('EPHEMERAL busy', e.busy, 'streams', (e.streams ?? []).map(s => s.id.slice(0, 14) + ':' + JSON.stringify(s.text.slice(0, 20))).join(' | ')); w2.close(); resolve(); } };
});
done = true; log('end', (await rest('DELETE', `/sessions/${id}`)).slice(0, 40)); ws.close(); process.exit(0);
