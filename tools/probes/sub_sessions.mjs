// Sub-sessions probe (docs/sub-sessions.md), against a staging server: a
// throwaway Claude session told two words, then asked on the side which
// (answered beside the conversation, which does not grow), forked (the
// fork knows both, under an id of its own) and branched at its first reply
// (the branch knows only the first), then sends a subagent off (listed, its
// conversation readable) and, once it has finished, goes on with it as a
// session of its own (which knows its conversation). Ends them all.
//   VISOR_PORT=7633 VISOR_TOKEN=<password> [AGENT=codex] node tools/probes/sub_sessions.mjs
// (Codex: no branch at a reply, which it can't make.)
import http from 'node:http';
const PORT = Number(process.env.VISOR_PORT ?? 7633);
const PW = process.env.VISOR_TOKEN;
if (!PW) { console.error('VISOR_TOKEN: the staging server\'s password'); process.exit(2); }
const AGENT = process.env.AGENT ?? 'claude';
const MODEL = process.env.MODEL ?? (AGENT === 'claude' ? 'haiku' : '');
const id = crypto.randomUUID().toUpperCase();
const t0 = Date.now();
const log = (...a) => console.log(((Date.now() - t0) / 1000).toFixed(2).padStart(6), ...a);
let failures = 0;
const check = (ok, what) => { log(ok ? 'ok:' : 'FAILED:', what); if (!ok) failures++; };

function rest(method, path, body) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : '';
    const req = http.request({ host: '127.0.0.1', port: PORT, path: '/api' + path, method, agent: false,
      headers: { Authorization: 'Bearer ' + PW, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(data) } }, res => {
      let s = ''; res.on('data', d => s += d); res.on('end', () => resolve(s));
    });
    req.on('error', reject); if (data) req.write(data); req.end();
  });
}
const sessions = async () => JSON.parse(await rest('GET', '/sessions')).sessions ?? [];
const info = async (sid) => (await sessions()).find(s => s.id === sid);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (what, test, limit = 120000) => {
  const end = Date.now() + limit;
  while (Date.now() < end) { const v = await test(); if (v) return v; await sleep(500); }
  check(false, 'timed out: ' + what); return null;
};
const idle = sid => until(sid.slice(0, 8) + ' idle', async () => { const s = await info(sid); return s && !s.busy && !(s.queued ?? []).length; });
const rows = async sid => JSON.parse(await rest('GET', `/sessions/${sid}/transcript?since=-1`)).entries ?? [];
const lastReply = async sid => (await rows(sid)).filter(r => r.role === 'assistant').at(-1)?.text ?? '';
const send = async (sid, text) => { await rest('POST', `/sessions/${sid}/send`, { text }); await sleep(1500); await idle(sid); };

log('start', id.slice(0, 8));
await rest('POST', '/sessions', { id, agent: AGENT, cwd: '/tmp/visor-probe-sub', title: 'probe-sub', skipPermissions: true });
if (MODEL) await rest('POST', `/sessions/${id}/settings`, { model: MODEL });
await send(id, 'Remember the word PELICAN. Reply with just OK.');
await send(id, 'Also remember the word OTTER. Reply with just OK.');
const before = await rows(id);
const firstReply = before.find(r => r.role === 'assistant')?.id;
log('rows', before.map(r => `${r.role}:${r.id.slice(0, 16)}`).join(' | '));

// A side question: answered on the session, not in its conversation.
await rest('POST', `/sessions/${id}/side`, { id: 'side-1', text: 'Which words did I ask you to remember? Just the words.' });
const side = await until('side answer', async () => (await info(id))?.side?.find(q => q.answer || q.failure));
log('side', JSON.stringify(side));
check(/PELICAN/i.test(side?.answer ?? '') && /OTTER/i.test(side?.answer ?? ''), 'the side answer knows both words');
check((await rows(id)).length === before.length, 'the conversation did not grow');
await rest('POST', `/sessions/${id}/endSide`, {});
check(((await info(id))?.side ?? []).length === 0, 'the side questions ended');

// A fork, started on its prompt.
const fork = crypto.randomUUID().toUpperCase();
await rest('POST', `/sessions/${id}/fork`, { id: fork, origin: 'fork', text: 'Which words did I ask you to remember? Just the words.' });
await sleep(1500); await idle(fork);
const forkInfo = await info(fork);
log('fork', forkInfo?.title, forkInfo?.resumeCommand, '←', (await info(id))?.resumeCommand);
check(forkInfo?.parent === id && forkInfo?.origin === 'fork', 'the fork names its parent');
check(forkInfo?.resumeCommand && forkInfo.resumeCommand !== (await info(id))?.resumeCommand, 'the fork is a conversation of its own');
const forkReply = await lastReply(fork);
log('fork says', JSON.stringify(forkReply));
check(/PELICAN/i.test(forkReply) && /OTTER/i.test(forkReply), 'the fork knows both words');

// A branch at the first reply (Claude Code's alone).
const branch = crypto.randomUUID().toUpperCase();
if (AGENT === 'claude') {
  await rest('POST', `/sessions/${id}/fork`, { id: branch, origin: 'branch', at: firstReply });
  const branchRows = await rows(branch);
  check(branchRows.length === 2, `the branch shows the conversation through its first turn (${branchRows.length} rows)`);
  await send(branch, 'Which words did I ask you to remember? Just the words.');
  const branchReply = await lastReply(branch);
  log('branch says', JSON.stringify(branchReply));
  check(/PELICAN/i.test(branchReply) && !/OTTER/i.test(branchReply), 'the branch knows only the first word');
  check((await rows(id)).length === before.length, 'the parent is as it was');
}

// A subagent: listed once seen running, its conversation readable, then
// gone on with as a session of its own.
const [sendOff, described] = AGENT === 'claude'
  ? ['Use your Agent tool once, with subagent_type general-purpose and the description "Add two numbers", to ask a subagent what 2 + 2 is (it should answer with just the number). Then reply with just DONE.', 'Add two numbers']
  : ['Spawn one subagent with your spawn_agent tool, with the task name "arithmetic", and ask it what 2 + 2 is (it should answer with just the number). Wait for it, then reply with just DONE.', 'arithmetic'];
await send(id, sendOff);
const seen = await until('a subagent listed', async () => (await info(id))?.subagents?.[0]);
log('subagent', JSON.stringify(seen));
check(seen?.description === described, 'the subagent is listed with its description');
check(/DONE/.test(await lastReply(id)), "the session's turn ran to its end, past its subagent's");
const agentRows = JSON.parse(await rest('GET', `/sessions/${id}/subagents/${seen?.id}`)).entries ?? [];
log('subagent rows', agentRows.map(r => `${r.role}:${JSON.stringify((r.text ?? '').slice(0, 30))}`).join(' | '));
check(agentRows.some(r => r.role === 'assistant' && /4/.test(r.text ?? '')), 'its conversation has its answer');
check(!(await rows(id)).some(r => /^\s*4\s*$/.test(r.text ?? '') && r.role === 'assistant'), "its answer is not the session's own row");
const parentRows = (await rows(id)).length;
const onward = crypto.randomUUID().toUpperCase();
await rest('POST', `/sessions/${id}/fork`, { id: onward, origin: 'subagent', subagent: seen?.id,
  text: 'What exactly were you asked, and what did you answer? One line.' });
await sleep(1500); await idle(onward);
const onwardInfo = await info(onward);
log('onward', onwardInfo?.title, onwardInfo?.resumeCommand);
check(onwardInfo?.parent === id && onwardInfo?.origin === 'subagent', 'the session names the session that sent the subagent off');
check(onwardInfo?.title === described, 'it is titled with what the subagent was sent to do');
const onwardReply = await lastReply(onward);
log('onward says', JSON.stringify(onwardReply));
check(/4/.test(onwardReply), "it goes on with the subagent's conversation");
check(((await info(id))?.subagents ?? []).length === 0, "its row takes the subagent's place");
check((await rows(id)).length === parentRows, 'the parent is as it was');

for (const sid of [onward, branch, fork, id]) if (await info(sid)) await rest('DELETE', `/sessions/${sid}`);
log('failures', failures);
process.exit(failures ? 1 : 0);
