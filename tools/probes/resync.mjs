// Whether a send makes the server replace a session's rows: a re-read of the agent's file whose rows
// differ from the ones built live, which the server broadcasts whole and a client then takes in place
// of every row it holds (the thread rebuilt, its place lost). Over REST only: polls the rows during
// the second of two turns in a throwaway session and reports rows from before the send that change
// id or go, and any change of generation.
//
//   VISOR_TOKEN=<token> node tools/probes/resync.mjs [idle seconds before the second send]
import http from 'node:http';
const PORT = Number(process.env.VISOR_PORT ?? 7433), PW = process.env.VISOR_TOKEN ?? 'staging';
const IDLE = Number(process.argv[2] ?? 0);
const t0 = Date.now(); const log = (...a) => console.log(((Date.now() - t0) / 1000).toFixed(2).padStart(7), ...a);
const rest = (method, path, body) => new Promise((resolve, reject) => {
  const data = body ? JSON.stringify(body) : '';
  const req = http.request({ host: '127.0.0.1', port: PORT, path: '/api' + path, method, agent: false,
    headers: { Authorization: 'Bearer ' + PW, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } }, res => { let s = ''; res.on('data', d => s += d); res.on('end', () => resolve(s)); });
  req.on('error', reject); if (data) req.write(data); req.end(); });
const sleep = ms => new Promise(r => setTimeout(r, ms));
const busy = async id => (JSON.parse(await rest('GET', '/sessions')).sessions.find(s => s.id === id) ?? {}).busy;
const untilIdle = async id => { await sleep(1500); for (let i = 0; i < 120 && await busy(id); i++) await sleep(1000); };
const rows = async id => JSON.parse(await rest('GET', `/sessions/${id}/transcript`));
const cwd = '/tmp/visor-probe-resync';
const id = JSON.parse(await rest('POST', '/sessions', { type: 'start', agent: 'claude', cwd, title: 'probe-resync', skipPermissions: true, model: 'haiku' })).sessions[0].id;
try {
  log('--- send 1');
  await rest('POST', `/sessions/${id}/send`, { type: 'send', text: 'Run the Bash command `date`, then write three short paragraphs about bananas.' });
  await untilIdle(id);
  if (IDLE) { log(`--- idle ${IDLE} s`); await sleep(IDLE * 1000); }
  const before = await rows(id);
  const held = before.entries.map(r => r.id);
  log(`before send 2: generation ${before.generation}, revision ${before.revision}, ${held.length} rows`);
  log('--- send 2');
  await rest('POST', `/sessions/${id}/send`, { type: 'send', text: 'Reply with exactly the word OK.' });
  let generation = before.generation, revision = before.revision, replaced = false;
  for (let i = 0; i < 100; i++) {
    await sleep(150);
    const now = await rows(id);
    const ids = new Set(now.entries.map(r => r.id));
    const gone = held.filter(r => !ids.has(r));
    if (now.generation !== generation) { log(`generation ${generation} -> ${now.generation}`); generation = now.generation; }
    if (now.revision !== revision) {
      log(`revision ${now.revision}: ${now.entries.length} rows${gone.length ? `, ${gone.length} rows from before the send gone: ${gone.slice(0, 4).join(' ')}` : ''}`);
      revision = now.revision;
      if (gone.length) replaced = true;
    }
    if (i > 20 && !now.busy && !(await busy(id))) break;
  }
  log(replaced ? 'RESULT: rows from before the send were replaced' : 'RESULT: rows from before the send kept their ids');
} finally {
  await rest('DELETE', `/sessions/${id}`);
  log('--- ended the session');
}
