// transcript_layout_check.js <site dir> — what a transcript lays out wider
// than a phone, on the web: in a phone-wide headless Chrome, the web client
// is served by stub_server.py (the page finds the server at its own origin)
// and two of its sessions are opened.
// - "Long lines": a code block (a connection code, one word of 220
//   characters, and a line of words) wraps, as AgentUI's MarkdownText has
//   it since 48cf89b: within the window, the lines wrapping needs, nothing
//   to scroll sideways.
// - "Pictures": four phone screenshots in your message are wider together
//   than it, so they are a carousel within the window (AgentUI 9f9f753's
//   ViewThatFits; as wide as the thread since 54eb84d), with its words still
//   on screen; two in another fit, so they are a row on your messages'
//   side, nothing to scroll.
// Fails on an uncaught exception or a console error too (a picture's bytes,
// which the stub does not serve, aside). The stub and Chrome (a profile of
// its own) are gone at the end; LAYOUT_SHOTS=<dir> keeps screenshots.
//
//   bazel build -c opt //applications/visor_web:visor_web_site
//   node tools/isomer/e2e/transcript_layout_check.js "$(bazel cquery -c opt --output=files //applications/visor_web:visor_web_site)"
const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const site = process.argv[2];
if (!site) { console.error("usage: transcript_layout_check.js <site dir>"); process.exit(2); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const CODE_START = "vsr1-eyJ2Ijox";
const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const profile = fs.mkdtempSync("/tmp/transcript-layout-check-");
const sitePort = 8600 + Math.floor(Math.random() * 400);
const stub = spawn("python3", [path.join(__dirname, "stub_server.py"), path.resolve(site), String(sitePort)], { stdio: "ignore" });
let proc = null;
const finish = (code) => {
  if (proc) proc.kill();
  stub.kill();
  try { fs.rmSync(profile, { recursive: true, force: true }); } catch (_) {}
  process.exit(code);
};

(async () => {
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
    // A picture's bytes are not served by the stub: its 404 is expected.
    if (m.method === "Log.entryAdded" && p.entry.level === "error" && !/favicon\.ico|\/Users\/stub\/shots\/|status of 404/.test((p.entry.url || "") + " " + p.entry.text)) problems.push(`console: ${p.entry.text}`);
  };
  const send = (method, params = {}) => new Promise((r) => { const n = ++id; pending.set(n, r); ws.send(JSON.stringify({ id: n, method, params })); });
  const evaluate = async (expression) => ((await send("Runtime.evaluate", { expression, returnByValue: true })).result || {}).result?.value;
  // Headless Chrome draws (and the reactor lays out) when a frame is asked for.
  const frame = () => send("Page.captureScreenshot", { format: "png" });
  const waitFor = async (expression, ms) => {
    for (let waited = 0; waited < ms; waited += 500) { await frame(); await sleep(500); const v = await evaluate(expression); if (v) return v; }
    return null;
  };
  const shot = async (name) => {
    if (!process.env.LAYOUT_SHOTS) return;
    const image = await frame();
    fs.writeFileSync(path.join(process.env.LAYOUT_SHOTS, name + ".png"), Buffer.from(image.result.data, "base64"));
  };
  const results = [];
  const check = (name, ok, got) => {
    results.push(ok);
    console.log((ok ? "[layout] ok    " : "[layout] FAIL  ") + name + (ok ? "" : `: got ${JSON.stringify(got)}`));
  };
  await send("Page.enable"); await send("Runtime.enable"); await send("Log.enable");
  // A phone's width (an iPhone's 390 points): headless Chrome's window is
  // never narrower than 500, where four thumbnails fit the thread.
  await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 3, mobile: true });

  // Opens a session from the list, the page loaded afresh.
  const open = async (title) => {
    await send("Page.navigate", { url: `http://127.0.0.1:${sitePort}/` });
    const row = await waitFor(`(() => {
      const el = [...document.querySelectorAll("body *")].find((e) => e.childElementCount === 0 && (e.textContent || "").trim() === ${JSON.stringify(title)});
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
    })()`, 45000);
    if (!row) return false;
    for (const type of ["mousePressed", "mouseReleased"]) await send("Input.dispatchMouseEvent", { type, x: row.x, y: row.y, button: "left", clickCount: 1 });
    return true;
  };
  // What scrolls sideways above an element (a carousel), if anything.
  const SIDEWAYS = `(el) => { for (let a = el.parentElement; a; a = a.parentElement) {
      const x = getComputedStyle(a).overflowX;
      if ((x === "auto" || x === "scroll") && a.scrollWidth > a.clientWidth + 1) return a;
    } return null; }`;

  // 1. A code block's long lines wrap.
  if (!(await open("Long lines"))) {
    check("\"Long lines\" is in the sessions list", false, null);
  } else {
    const code = await waitFor(`(() => {
      const holders = [...document.querySelectorAll("body *")].filter((e) => (e.textContent || "").includes(${JSON.stringify(CODE_START)}));
      const el = holders.find((e) => ![...e.children].some((c) => (c.textContent || "").includes(${JSON.stringify(CODE_START)})));
      if (!el) return null;
      const r = el.getBoundingClientRect();
      const size = parseFloat(getComputedStyle(el).fontSize) || 13;
      const sideways = (${SIDEWAYS})(el);
      return { left: r.left, right: r.right, height: r.height, lines: Math.round(r.height / (size * 1.25)),
               innerWidth, pageWidth: document.documentElement.scrollWidth, sideways: sideways && sideways.tagName };
    })()`, 30000);
    await shot("code-block");
    if (!code) {
      check("the code block shows in \"Long lines\"", false, null);
    } else {
      check("the code block keeps within the window", code.left >= 0 && code.right <= code.innerWidth + 0.5, code);
      check("its long lines wrap (the code word and the line of words take several lines)", code.lines >= 6, code);
      check("nothing scrolls sideways (no scroller around it, the page no wider than the window)",
        !code.sideways && code.pageWidth <= code.innerWidth, code);
    }
  }

  // 2. Pictures wider than their message are a carousel; ones that fit, a row.
  if (!(await open("Pictures"))) {
    check("\"Pictures\" is in the sessions list", false, null);
  } else {
    const pictures = await waitFor(`(() => {
      // The ones drawn: a candidate not chosen (a ViewThatFits' other view)
      // is in the page too, undrawn.
      const drawn = (e) => e.getClientRects().length > 0;
      const four = [...document.querySelectorAll('[data-testid^="attachment-four-"]')].filter(drawn);
      const two = [...document.querySelectorAll('[data-testid^="attachment-two-"]')].filter(drawn);
      const words = [...document.querySelectorAll("body *")].find((e) => e.childElementCount === 0 && (e.textContent || "").trim() === "Four screenshots of the sign-in screen.");
      const answer = [...document.querySelectorAll("body *")].find((e) => e.childElementCount === 0 && (e.textContent || "").trim() === "And the two that changed.");
      if (four.length < 4 || two.length < 2 || !words || !answer) return null;
      const sideways = ${SIDEWAYS};
      const carousel = sideways(four[0]);
      const rect = (e) => { const r = e.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top, width: r.width }; };
      return {
        innerWidth, pageWidth: document.documentElement.scrollWidth,
        carousel: carousel ? { ...rect(carousel), scrollWidth: carousel.scrollWidth, clientWidth: carousel.clientWidth, holdsAll: four.every((e) => carousel.contains(e)) } : null,
        words: rect(words), answer: rect(answer),
        two: two.map(rect), twoSideways: two.some((e) => sideways(e) !== null),
      };
    })()`, 30000);
    await shot("pictures");
    if (!pictures) {
      check("the pictures show in \"Pictures\"", false, null);
    } else {
      const c = pictures.carousel;
      check("four pictures wider than the message are a carousel", !!c && c.holdsAll && c.scrollWidth > c.clientWidth, pictures);
      check("  within the window", !!c && c.left >= 0 && c.right <= pictures.innerWidth + 0.5, c);
      check("  and the message's words still on screen", pictures.words.left >= 0 && pictures.words.right <= pictures.innerWidth + 0.5, pictures.words);
      check("two that fit are a row, nothing to scroll", !pictures.twoSideways && pictures.two.every((r) => r.left >= 0 && r.right <= pictures.innerWidth + 0.5), pictures.two);
      check("  on your messages' side (trailing, with its words)", Math.abs(pictures.two[1].right - pictures.answer.right) <= 20, { two: pictures.two[1], answer: pictures.answer });
      check("the page no wider than the window", pictures.pageWidth <= pictures.innerWidth, pictures.pageWidth);
    }
  }

  for (const p of problems) console.log("[layout] FAIL  " + p);
  const failed = results.some((ok) => !ok) || problems.length > 0;
  console.log(failed ? "[layout] FAILED" : "[layout] all passed");
  finish(failed ? 1 : 0);
})().catch((error) => { console.error(error); finish(1); });
