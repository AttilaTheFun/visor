// A server without any agent installed, checked over its own protocol: the REST side and the
// WebSocket answer, a terminal session runs the computer's shell — a line typed and drawn, a large
// output carried whole, Ctrl-C ending a job (the terminal is the shell's controlling terminal) — and
// is ended. What a Linux or Windows server is first tried with; QUIT=1 then stops the server through
// /api/quit, as `visor-server stop` does. VISOR_SHELL=powershell types PowerShell's commands (a
// Windows server's shell) instead of a POSIX shell's.
//   VISOR_PORT=7633 VISOR_TOKEN=<password> node tools/probes/terminal.mjs
import http from 'node:http';
const PORT = Number(process.env.VISOR_PORT ?? 7533), PW = process.env.VISOR_TOKEN ?? 'staging';
const t0 = Date.now(); const log = (...a) => console.log(((Date.now() - t0) / 1000).toFixed(2).padStart(6), ...a);
const failures = []; const check = (what, ok) => { log(what + ':', ok); if (!ok) failures.push(what); };
const rest = (method, path, body) => new Promise((resolve, reject) => {
  const data = body ? JSON.stringify(body) : '';
  const req = http.request({ host: '127.0.0.1', port: PORT + 1, path: '/api' + path, method, agent: false,
    headers: { Authorization: 'Bearer ' + PW, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } },
    res => { let s = ''; res.on('data', d => s += d); res.on('end', () => resolve({ status: res.statusCode, body: s })); });
  req.on('error', reject); if (data) req.write(data); req.end(); });
const sleep = ms => new Promise(r => setTimeout(r, ms));
// What is typed, in the server's shell: each prints its marker only by running.
const commands = process.env.VISOR_SHELL === 'powershell' ? {
  line: 'Write-Output "visor-term-$(40 + 2)"',
  many: '1..3000 | ForEach-Object { "row-$_-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }; "rows-done"',
  wait: 'Start-Sleep 20; "SLEPT"',
  after: 'Write-Output "after-ctrl-c-$(1 + 1)"',
} : {
  line: 'echo visor-term-$((40 + 2))',
  many: 'i=0; while [ $i -lt 3000 ]; do echo row-$i-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; i=$((i+1)); done; echo rows-done',
  wait: 'sleep 20; echo SLEPT',
  after: 'echo after-ctrl-c-$((1 + 1))',
};
const until = async (f, limit) => { const end = Date.now() + limit; while (!f() && Date.now() < end) await sleep(50); return f(); };

const listed = await rest('GET', '/sessions');
check('REST answers with the password', listed.status === 200 && Array.isArray(JSON.parse(listed.body).sessions));
const refused = await new Promise(resolve => http.get({ host: '127.0.0.1', port: PORT + 1, path: '/api/sessions',
  headers: { Authorization: 'Bearer wrong' } }, res => { res.resume(); resolve(res.statusCode); }));
check('REST refuses a wrong password', refused === 401);

let welcomed = false, screen = '';
const ws = new WebSocket(`ws://127.0.0.1:${PORT}`); const send = o => ws.send(JSON.stringify(o));
await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
ws.onmessage = ev => { const e = JSON.parse(ev.data);
  if (e.type === 'welcome') welcomed = true;
  if (e.type === 'tty') screen += Buffer.from(e.data ?? '', 'base64').toString('utf8'); };
send({ type: 'login', password: PW, client: 'probe-terminal' });
check('the WebSocket logs in', await until(() => welcomed, 5000));

const term = crypto.randomUUID().toUpperCase();
await rest('POST', '/sessions', { id: term, agent: 'shell', cwd: '~', title: 'probe-terminal' });
send({ type: 'subscribe', session: term });
send({ type: 'mode', session: term, mode: 'tui', cols: 100, rows: 30 });
const type = text => send({ type: 'input', session: term, data: Buffer.from(text).toString('base64') });
type(commands.line + '\r');
check('a line typed is run and drawn', await until(() => screen.includes('visor-term-42'), 10000));
// Large enough to need the WebSocket's 64-bit length, once the server batches it.
type(commands.many + '\r');
check('a large output arrives whole', await until(() => screen.includes('row-2999-') && screen.includes('rows-done'), 20000));
type(commands.wait + '\r'); await sleep(800); type('\x03'); await sleep(300);
type(commands.after + '\r');
check('Ctrl-C ends the job in the foreground', await until(() => screen.includes('after-ctrl-c-2'), 5000));
const ended = await rest('DELETE', `/sessions/${term}`);
check('the session ends', ended.status === 200);
ws.close();

if (process.env.QUIT) {
  const quit = await rest('POST', '/quit');
  check('asked to stop, it says so', quit.status === 200);
  await sleep(1500);
  const gone = await rest('GET', '/sessions').then(() => false, () => true);
  check('and stops', gone);
}
log(failures.length ? 'FAILED: ' + failures.join('; ') : 'failures 0');
process.exit(failures.length ? 1 : 0);
