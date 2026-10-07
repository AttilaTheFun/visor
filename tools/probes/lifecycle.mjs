// Lifecycle check on the staging server: interrupt mid-turn, carry on, end. TERMINAL=1 adds a terminal
// session: taken by this client, a line typed and its output drawn, Ctrl-C ending a job (the terminal is
// the shell's controlling terminal), taken by another window (the same shell), ended.
import http from 'node:http';
const PORT = Number(process.env.VISOR_PORT ?? 7533), PW = process.env.VISOR_TOKEN ?? 'staging';
const AGENT = process.env.AGENT ?? 'claude';
const id = crypto.randomUUID().toUpperCase();
const t0 = Date.now(); const log = (...a) => console.log(((Date.now() - t0) / 1000).toFixed(2).padStart(6), ...a);
const rest = (method, path, body) => new Promise((resolve, reject) => {
  const data = body ? JSON.stringify(body) : '';
  const req = http.request({ host: '127.0.0.1', port: PORT, path: '/api' + path, method, agent: false,
    headers: { Authorization: 'Bearer ' + PW, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } }, res => { let s = ''; res.on('data', d => s += d); res.on('end', () => resolve(s)); });
  req.on('error', reject); if (data) req.write(data); req.end(); });
let busy = null, failures = [], tty = 0, mode = null, screen = '';
const ws = new WebSocket(`ws://127.0.0.1:${PORT}`); const send = o => ws.send(JSON.stringify(o));
await new Promise(r => ws.onopen = r);
send({ type: 'login', password: PW, client: 'probe-life' });
ws.onmessage = ev => { const e = JSON.parse(ev.data);
  if (e.type === 'sessions' || e.type === 'welcome') { const s = (e.sessions ?? []).find(s => s.id === id); if (s) { mode = JSON.stringify(s.mode); } return; }
  if (e.session && e.session !== id) return;
  if (e.type === 'busy') { busy = e.busy; log('busy', e.busy); }
  else if (e.type === 'failure' || e.type === 'error') { failures.push(e.message ?? e.error); log('FAILURE', JSON.stringify(e).slice(0, 200)); }
  else if (e.type === 'tty') tty += (e.data ?? '').length; };
ws.addEventListener('message', ev => { const e = JSON.parse(ev.data);
  if (e.type === 'tty' && e.session !== id) screen += Buffer.from(e.data ?? '', 'base64').toString('utf8'); });
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
if (process.env.TERMINAL) {
  const term = crypto.randomUUID().toUpperCase();
  await rest('POST', '/sessions', { id: term, agent: 'shell', cwd: '/tmp', title: 'probe-terminal' });
  send({ type: 'subscribe', session: term });
  log('take the terminal'); send({ type: 'mode', session: term, mode: 'tui', cols: 100, rows: 30 });
  send({ type: 'input', session: term, data: Buffer.from('echo visor-term-$((40 + 2))\r').toString('base64') });
  log('line ran:', await until(() => screen.includes('visor-term-42'), 10000));
  // The terminal is the shell's controlling terminal: Ctrl-C ends a job in the foreground.
  const typeLine = t => send({ type: 'input', session: term, data: Buffer.from(t).toString('base64') });
  typeLine('sleep 20; echo SLEPT\r'); await sleep(800); typeLine('\x03'); await sleep(300);
  typeLine('echo after-ctrl-c-$((1 + 1))\r');
  log('Ctrl-C ended the job:', await until(() => screen.includes('after-ctrl-c-2'), 5000));
  const listed = JSON.parse(await rest('GET', '/sessions')).sessions.find(s => s.id === term);
  log('terminal session:', listed?.agent, JSON.stringify(listed?.mode), 'busy', listed?.busy);
  // Another window takes it, over its own connection: it is sent the screen so far, then what the
  // shell draws; this client is sent nothing more.
  const other = new WebSocket(`ws://127.0.0.1:${PORT}`); let otherScreen = '', replayed = false;
  await new Promise(r => other.onopen = r);
  other.onmessage = ev => { const e = JSON.parse(ev.data); if (e.session !== term || e.type !== 'tty') return;
    if (e.cols) replayed = true; otherScreen += Buffer.from(e.data ?? '', 'base64').toString('utf8'); };
  other.send(JSON.stringify({ type: 'login', password: PW, client: 'probe-other-window' }));
  await sleep(500);
  other.send(JSON.stringify({ type: 'mode', session: term, mode: 'tui', cols: 80, rows: 24 }));
  log('the other window is sent the screen so far:', await until(() => replayed && otherScreen.includes('visor-term-42'), 5000));
  const before = screen.length;
  await rest('POST', `/sessions/${term}/send`, { text: 'echo for-the-other-window' });
  log('the other window sees the new line:', await until(() => otherScreen.includes('for-the-other-window'), 5000));
  await sleep(500); log('nothing sent here once another window has it:', screen.length === before);
  other.close();
  log('end terminal', (await rest('DELETE', `/sessions/${term}`)).slice(0, 30));
}
if (process.env.MCP) {
  // The agent's own path to the server: Visor's MCP tools, and with them
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
