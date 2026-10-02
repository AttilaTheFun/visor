// Lifecycle check on the staging server: interrupt mid-turn, carry on, switch to a terminal and back, end.
import http from 'node:http';
const PORT = Number(process.env.VISOR_PORT ?? 7533), PW = process.env.VISOR_TOKEN ?? 'staging';
const AGENT = process.env.AGENT ?? 'claude';
const id = crypto.randomUUID().toUpperCase();
const t0 = Date.now(); const log = (...a) => console.log(((Date.now() - t0) / 1000).toFixed(2).padStart(6), ...a);
const rest = (method, path, body) => new Promise((resolve, reject) => {
  const data = body ? JSON.stringify(body) : '';
  const req = http.request({ host: '127.0.0.1', port: PORT + 1, path: '/api' + path, method, agent: false,
    headers: { Authorization: 'Bearer ' + PW, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } }, res => { let s = ''; res.on('data', d => s += d); res.on('end', () => resolve(s)); });
  req.on('error', reject); if (data) req.write(data); req.end(); });
let busy = null, failures = [], tty = 0, mode = null;
const ws = new WebSocket(`ws://127.0.0.1:${PORT}`); const send = o => ws.send(JSON.stringify(o));
await new Promise(r => ws.onopen = r);
send({ type: 'login', password: PW, client: 'probe-life' });
ws.onmessage = ev => { const e = JSON.parse(ev.data);
  if (e.type === 'sessions' || e.type === 'welcome') { const s = (e.sessions ?? []).find(s => s.id === id); if (s) { mode = JSON.stringify(s.mode); } return; }
  if (e.session && e.session !== id) return;
  if (e.type === 'busy') { busy = e.busy; log('busy', e.busy); }
  else if (e.type === 'failure' || e.type === 'error') { failures.push(e.message ?? e.error); log('FAILURE', JSON.stringify(e).slice(0, 200)); }
  else if (e.type === 'tty') tty += (e.data ?? '').length; };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (f, limit) => { const end = Date.now() + limit; while (!f() && Date.now() < end) await sleep(50); return f(); };
await sleep(300);
await rest('POST', '/sessions', { id, agent: AGENT, cwd: '/tmp/visor-probe', title: 'probe-life', skipPermissions: true });
send({ type: 'subscribe', session: id });
await sleep(500);
send({ type: 'send', session: id, text: 'Count slowly from 1 to 400, one number per line, with a short sentence about each number.' });
await until(() => busy === true, 10000); await sleep(5000);
log('interrupt'); send({ type: 'stop', session: id });
log('idle after interrupt:', await until(() => busy === false, 15000));
busy = null;
send({ type: 'send', session: id, text: 'Reply with exactly the word AFTER.' });
await until(() => busy === true, 10000); log('idle after second turn:', await until(() => busy === false, 60000));
const rows = JSON.parse(await rest('GET', `/sessions/${id}/transcript?since=0`)).entries ?? [];
log('rows:', rows.map(r => `${r.role}:${JSON.stringify((r.text ?? '').slice(0, 14))}`).join(' | '));
if (process.env.TUI) {
  log('to terminal'); send({ type: 'mode', session: id, mode: 'tui', controller: 'probe-life', cols: 100, rows: 30 });
  await sleep(8000); log('mode', mode, 'tty bytes', tty);
  log('to chat'); send({ type: 'mode', session: id, mode: 'chat' });
  await sleep(5000); log('mode', mode);
  busy = null; send({ type: 'send', session: id, text: 'Reply with exactly the word BACK.' });
  await until(() => busy === true, 10000); log('idle after third turn:', await until(() => busy === false, 60000));
  const again = JSON.parse(await rest('GET', `/sessions/${id}/transcript?since=0`)).entries ?? [];
  log('last row:', JSON.stringify(again.at(-1)?.text?.slice(0, 20)));
}
if (process.env.MCP) {
  // The agent's own road to the server: Visor's MCP tools, and with them
  // a tool call the client is asked to approve (manual permissions).
  busy = null; send({ type: 'send', session: id, text: 'Call the visor MCP tool list_sessions once and reply with exactly the word LISTED if it answered, or FAILED if it did not.' });
  await until(() => busy === true, 10000); log('idle after MCP turn:', await until(() => busy === false, 90000));
  const listed = JSON.parse(await rest('GET', `/sessions/${id}/transcript?since=0`)).entries ?? [];
  log('MCP answer:', JSON.stringify(listed.at(-1)?.text?.slice(0, 20)));
  const manual = crypto.randomUUID().toUpperCase();
  await rest('POST', '/sessions', { id: manual, agent: AGENT, cwd: '/tmp/visor-probe', title: 'probe-approve', skipPermissions: false });
  let asked = null, done = null;
  ws.addEventListener('message', ev => { const e = JSON.parse(ev.data); if (e.session !== manual) return;
    if (e.type === 'approval' && e.approval) asked = e.approval; if (e.type === 'busy') done = e.busy; });
  send({ type: 'subscribe', session: manual });
  await sleep(500);
  send({ type: 'send', session: manual, text: 'Run the shell command `python3 -c "print(40 + 2)"` with your Bash tool and reply with exactly what it printed.' });
  log('asked to approve:', (await until(() => asked !== null, 60000)) ? asked.tool : 'NOTHING ASKED');
  if (asked) send({ type: 'approve', session: manual, id: asked.id, allow: true });
  await until(() => done === false, 60000);
  const approved = JSON.parse(await rest('GET', `/sessions/${manual}/transcript?since=0`)).entries ?? [];
  log('after approval:', JSON.stringify(approved.at(-1)?.text?.slice(0, 20)));
  await rest('DELETE', `/sessions/${manual}`);
}
log('end', (await rest('DELETE', `/sessions/${id}`)).slice(0, 30)); log('failures', failures.length); ws.close(); process.exit(0);
