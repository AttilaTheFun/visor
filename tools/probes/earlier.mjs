// Subscribes to a session, then asks for rows before the first one shown, twice.
import { execSync } from 'node:child_process';
const PW = execSync('defaults read com.LoganShire.Visor.MenuBar visor.password').toString().trim();
const id = process.argv[2];
const ws = new WebSocket('ws://127.0.0.1:7433');
let first = null, pages = 0;
ws.onopen = () => ws.send(JSON.stringify({ type: 'login', password: PW, client: 'probe-earlier' }));
ws.onmessage = ev => {
  const e = JSON.parse(ev.data);
  if (e.type === 'welcome') { ws.send(JSON.stringify({ type: 'subscribe', session: id })); return; }
  if (e.type === 'transcript') { first = e.entries[0]; console.log('transcript rows', e.entries.length, 'more', e.more, 'first', first?.id.slice(0, 20), JSON.stringify((first?.text ?? '').slice(0, 40))); ws.send(JSON.stringify({ type: 'earlier', session: id, before: first.id })); return; }
  if (e.type === 'earlier') { pages++; const f = e.entries[0]; console.log('earlier page', pages, 'rows', e.entries.length, 'more', e.more, 'first', f?.id.slice(0, 20), JSON.stringify((f?.text ?? '').slice(0, 40)), 'last', JSON.stringify((e.entries.at(-1)?.text ?? '').slice(0, 30)));
    if (pages < 2 && e.more && f) ws.send(JSON.stringify({ type: 'earlier', session: id, before: f.id })); else { ws.close(); process.exit(0); } }
};
setTimeout(() => { console.log('timeout'); process.exit(1); }, 15000);
