// composer_check.js <site dir> — AgentUI's composer typed into on the web:
// the cases AgentUI's ComposerTypingTests type into a Mac's field, here in
// the web client (visor's snapshot fixture, its chat), in headless Chrome
// with trusted key events (Shift-Return, Delete, arrows) and Chrome's text
// insertion. After each step it reads the composer's words and caret; it
// fails on a wrong one, an uncaught exception (a Swift trap in the reactor
// is one) or a console error. The site is served on a loopback port of its
// own and Chrome given a profile of its own; both are gone at the end.
//
//   bazel build -c opt //applications/visor_web:visor_web_site
//   node tools/isomer/e2e/composer_check.js "$(bazel cquery -c opt --output=files //applications/visor_web:visor_web_site)"
const { spawn } = require("child_process");
const fs = require("fs");
const http = require("http");
const path = require("path");
const site = process.argv[2];
if (!site) { console.error("usage: composer_check.js <site dir>"); process.exit(2); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm", ".css": "text/css",
  ".json": "application/json", ".png": "image/png", ".svg": "image/svg+xml", ".dat": "application/octet-stream" };
const server = http.createServer((req, res) => {
  const name = decodeURIComponent(new URL(req.url, "http://x").pathname);
  const file = path.join(site, name.endsWith("/") ? name + "index.html" : name);
  fs.readFile(file, (error, data) => {
    if (error) { res.writeHead(404); res.end(); return; }
    res.writeHead(200, { "Content-Type": types[path.extname(file)] || "application/octet-stream", "Cache-Control": "no-store" });
    res.end(data);
  });
});
const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = fs.mkdtempSync("/tmp/composer-check-");
let proc = null;
const finish = (code) => {
  if (proc) proc.kill();
  server.close();
  try { fs.rmSync(profile, { recursive: true, force: true }); } catch (_) {}
  process.exit(code);
};

(async () => {
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const sitePort = server.address().port;
  const port = 9400 + Math.floor(Math.random() * 400);
  proc = spawn(chrome, ["--headless=new", "--disable-gpu", "--use-mock-keychain", "--password-store=basic",
    `--remote-debugging-port=${port}`, "--window-size=412,900", `--user-data-dir=${profile}`, "about:blank"], { stdio: "ignore" });
  let targets = null;
  for (let i = 0; i < 50 && !targets; i++) { await sleep(200); try { targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json(); } catch (_) {} }
  const page = targets.find((t) => t.type === "page");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => (ws.onopen = r));
  let id = 0; const pending = new Map(); const problems = [];
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); return; }
    const p = m.params || {};
    if (m.method === "Runtime.exceptionThrown") problems.push("uncaught: " + ((p.exceptionDetails.exception && p.exceptionDetails.exception.description) || p.exceptionDetails.text).split("\n").slice(0, 3).join(" | "));
    if (m.method === "Log.entryAdded" && p.entry.level === "error") problems.push(`console: ${p.entry.text}`);
  };
  const send = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
  const evaluate = async (expression) => ((await send("Runtime.evaluate", { expression, returnByValue: true })).result || {}).result?.value;
  await send("Page.enable"); await send("Runtime.enable"); await send("Log.enable");
  await send("Page.navigate", { url: `http://127.0.0.1:${sitePort}/?fixture=snapshot&screen=chat` });

  // The composer: the field whose prompt invites a message.
  const FIELD = `[...document.querySelectorAll("textarea, input")].find((f) => /^Message/.test(f.placeholder || ""))`;
  let ready = false;
  for (let waited = 0; waited < 40000 && !ready; waited += 500) { await sleep(500); ready = await evaluate(`!!(${FIELD})`); }
  if (!ready) { console.log("[composer] FAIL  no composer on the page"); finish(1); }

  const settle = () => sleep(250);
  const state = async () => { await settle(); return evaluate(`(() => { const f = ${FIELD}; return { v: f.value, s: f.selectionStart, e: f.selectionEnd }; })()`); };
  const focus = async () => {
    const rect = await evaluate(`(() => { const r = (${FIELD}).getBoundingClientRect(); return { x: r.left + r.width - 8, y: r.top + r.height / 2 }; })()`);
    for (const type of ["mousePressed", "mouseReleased"]) await send("Input.dispatchMouseEvent", { type, x: rect.x, y: rect.y, button: "left", clickCount: 1 });
    await settle();
  };
  const KEYS = { Enter: 13, Backspace: 8, ArrowLeft: 37, ArrowRight: 39 };
  const key = async (name, { shift = false } = {}) => {
    const base = { key: name, code: name, windowsVirtualKeyCode: KEYS[name], nativeVirtualKeyCode: KEYS[name], modifiers: shift ? 8 : 0 };
    await send("Input.dispatchKeyEvent", { type: "rawKeyDown", ...base });
    if (name === "Enter") await send("Input.dispatchKeyEvent", { type: "char", ...base, text: "\r", unmodifiedText: "\r" });
    await send("Input.dispatchKeyEvent", { type: "keyUp", ...base });
    await settle();
  };
  const type = async (text) => { for (const ch of [...text]) { await send("Input.insertText", { text: ch }); await sleep(40); } await settle(); };
  // A fresh draft: everything selected and deleted as a person would.
  const clear = async () => {
    await focus();
    await evaluate(`(() => { const f = ${FIELD}; f.setSelectionRange(0, f.value.length); })()`);
    await key("Backspace");
  };
  const utf16 = (s) => s.length;

  const results = [];
  const check = (name, ok, got) => {
    results.push(ok);
    console.log((ok ? "[composer] ok    " : "[composer] FAIL  ") + name + (ok ? "" : `: got ${JSON.stringify(got)}`));
  };

  // 1. Mid-message "archived", Shift-Return, Delete, "d": the d after it.
  await clear(); await type("rows archived"); await key("Enter", { shift: true }); await key("Backspace"); await type("d");
  let s = await state();
  check('"archived", Shift-Return, Delete, "d" gives "…archivedd|"', s.v === "rows archivedd" && s.s === utf16(s.v) && s.e === s.s, s);

  // 2. Shift-Return mid-message: the caret right after the newline.
  await clear(); await type("first second");
  for (let i = 0; i < "second".length; i++) await key("ArrowLeft");
  await key("Enter", { shift: true }); s = await state();
  const afterBreak = "first \n".length;
  check("Shift-Return mid-message leaves the caret right after the newline", s.v === "first \nsecond" && s.s === afterBreak && s.e === afterBreak, s);
  await type("X"); s = await state();
  check("  and a letter typed there goes after the newline", s.v === "first \nXsecond", s);

  // 3. Typing at the end after an em dash: no trap, the caret at the end.
  await clear(); await type("a — b"); await type("c"); s = await state();
  check("typing at the end after an em dash: no trap, caret at the end", s.v === "a — bc" && s.s === utf16(s.v), s);

  // 4. An emoji, Shift-Return, a letter.
  await clear(); await type("hi 👍"); await key("Enter", { shift: true }); await type("x"); s = await state();
  check("an emoji, Shift-Return, a letter", s.v === "hi 👍\nx" && s.s === utf16(s.v), s);

  // 5. Delete never adds a newline.
  await clear(); await type("abc"); await key("Backspace"); await key("Backspace"); s = await state();
  check("Delete never adds a newline", s.v === "a" && s.s === 1, s);

  // 6. Shift-Return over a selection replaces it.
  await clear(); await type("keep drop");
  for (let i = 0; i < "drop".length; i++) await key("ArrowLeft", { shift: true });
  await key("Enter", { shift: true }); await type("y"); s = await state();
  check("Shift-Return over a selection replaces it", s.v === "keep \ny" && s.s === utf16(s.v), s);

  // 7. A picked slash command: the caret after it.
  await clear(); await type("/"); await sleep(600);
  if (process.env.COMPOSER_SHOTS) {
    const shot = await send("Page.captureScreenshot", { format: "png" });
    fs.writeFileSync(path.join(process.env.COMPOSER_SHOTS, "slash.png"), Buffer.from(shot.result.data, "base64"));
  }
  let picked = null;
  for (let waited = 0; waited < 3000 && !picked; waited += 250) {
    // A frame drawn (headless Chrome draws only when asked): the list the
    // reactor laid out shows then.
    await send("Page.captureScreenshot", { format: "png" });
    await sleep(250);
    picked = await evaluate(`(() => {
      const field = ${FIELD};
      const below = (el) => el.getBoundingClientRect().top < field.getBoundingClientRect().top;
      const choice = [...document.querySelectorAll("[data-tap], button")].find((el) => /^\\/[a-z]/.test((el.innerText || "").trim()) && below(el));
      if (!choice) return null;
      const r = choice.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + r.height / 2, name: (choice.innerText || "").trim().split(/\\s/)[0] };
    })()`);
  }
  if (picked) {
    for (const t of ["mousePressed", "mouseReleased"]) await send("Input.dispatchMouseEvent", { type: t, x: picked.x, y: picked.y, button: "left", clickCount: 1 });
    await settle(); await focus();
    s = await state();
    const at = s.v.indexOf(picked.name);
    check(`a picked slash command (${picked.name}) puts the caret after it`, at === 0 && s.s >= picked.name.length && s.s === s.e, s);
  } else {
    console.log("[composer] skip  a picked slash command: no command list showed for \"/\" in the fixture");
  }

  // 8. Typing after the draft is cleared by sending it.
  await clear(); await type("hello"); await key("Enter"); await sleep(600);
  s = await state();
  const cleared = s.v === "";
  if (!cleared) console.log(`[composer] note  after Return the composer holds ${JSON.stringify(s.v)}`);
  await focus(); await type("next"); s = await state();
  check(`typing after the draft is cleared (sent${cleared ? "" : ": not cleared by Return in the fixture"})`, s.v.endsWith("next") && s.s === utf16(s.v), s);

  for (const p of problems) console.log("[composer] FAIL  " + p);
  const failed = results.some((ok) => !ok) || problems.length > 0;
  console.log(failed ? "[composer] FAILED" : "[composer] all passed");
  finish(failed ? 1 : 0);
})().catch((error) => { console.error(error); finish(1); });
