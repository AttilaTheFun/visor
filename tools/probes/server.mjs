// A server without any agent installed, checked over its own protocol: the REST side and the
// WebSocket answer, the heartbeat is answered, and a throwaway session is started, followed and
// ended — nothing is sent to it, so no agent runs. What a Linux or Windows server is first tried
// with; QUIT=1 then stops the server through /api/quit, as `visor-server stop` does.
//   VISOR_PORT=7633 VISOR_TOKEN=<password> node tools/probes/server.mjs
import http from 'node:http';
const PORT = Number(process.env.VISOR_PORT ?? 7533), PW = process.env.VISOR_TOKEN ?? 'staging';
const t0 = Date.now(); const log = (...a) => console.log(((Date.now() - t0) / 1000).toFixed(2).padStart(6), ...a);
const failures = []; const check = (what, ok) => { log(what + ':', ok); if (!ok) failures.push(what); };
const rest = (method, path, body) => new Promise((resolve, reject) => {
  const data = body ? JSON.stringify(body) : '';
  const req = http.request({ host: '127.0.0.1', port: PORT, path: '/api' + path, method, agent: false,
    headers: { Authorization: 'Bearer ' + PW, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } },
    res => { let s = ''; res.on('data', d => s += d); res.on('end', () => resolve({ status: res.statusCode, body: s })); });
  req.on('error', reject); if (data) req.write(data); req.end(); });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (f, limit) => { const end = Date.now() + limit; while (!f() && Date.now() < end) await sleep(50); return f(); };

const listed = await rest('GET', '/sessions');
check('REST answers with the password', listed.status === 200 && Array.isArray(JSON.parse(listed.body).sessions));
const refused = await new Promise(resolve => http.get({ host: '127.0.0.1', port: PORT, path: '/api/sessions',
  headers: { Authorization: 'Bearer wrong' } }, res => { res.resume(); resolve(res.statusCode); }));
check('REST refuses a wrong password', refused === 401);

const id = crypto.randomUUID().toUpperCase();
let welcomed = false, ponged = false, followed = false, listedHere = false;
const ws = new WebSocket(`ws://127.0.0.1:${PORT}`); const send = o => ws.send(JSON.stringify(o));
await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
ws.onmessage = ev => { const e = JSON.parse(ev.data);
  if (e.type === 'welcome') welcomed = true;
  if (e.type === 'pong') ponged = true;
  if (e.type === 'sessions' && (e.sessions ?? []).some(s => s.id === id)) listedHere = true;
  if (e.type === 'transcript' && e.session === id) followed = true; };
send({ type: 'login', password: PW, client: 'probe-server' });
check('the WebSocket logs in', await until(() => welcomed, 5000));
send({ type: 'ping' });
check('the heartbeat is answered', await until(() => ponged, 5000));

const started = await rest('POST', '/sessions', { id, agent: 'claude', cwd: '~', title: 'probe-server' });
check('a session starts', started.status === 200 && JSON.parse(started.body).sessions?.[0]?.id === id);
check('and the socket is told', await until(() => listedHere, 5000));
send({ type: 'subscribe', session: id });
check('it is followed over the socket', await until(() => followed, 5000));
const ended = await rest('DELETE', `/sessions/${id}`);
check('the session ends', ended.status === 200 && !JSON.parse(ended.body).sessions.some(s => s.id === id));
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
