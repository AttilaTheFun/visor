// The `visor` command, as Node runs it: the script itself, kept here so
// every build of the server has it. The server writes it among Visor's
// tools for containers (ContainerTools), which each container sees on its
// path, and puts that folder on the path of its agents here too.

enum VisorCommandScript {
    static let source = #"""
#!/usr/bin/env node
// visor: what a session asks of the Visor server that runs it. Machines,
// leased from the server's oss (OS Server): macOS, Linux and Windows VMs,
// iOS simulators, Android emulators. The server leases them in this
// session's name with oss's token, which the session never holds, and
// shows them with the session.
//
//   visor machine status                         what can be leased, and how much is
//   visor machine lease <platform> [--config=NAME] [--minutes=N] [--wait] [--server=NAME]
//                                                macos | linux | windows | ios | android; from the
//                                                nearest oss with room, or the one NAME names
//   visor machine list                           this session's machines
//   visor machine show <id>
//   visor machine renew <id> [--minutes=N]
//   visor machine release <id>
//   visor machine ssh <id> [command …]           a VM's shell (this session's SSH key)
//   visor machine screenshot <id> <out.png>
//   visor machine simctl <id> <arguments …>      a simulator: install <.app>, launch <bundle id>, …
//   visor machine adb <id> <arguments …>         an emulator: install <.apk>, shell …, …
//   visor machine upload <id> <file>             a file for the lease's commands (@name)
//
// Local paths among simctl's and adb's arguments are sent first (a folder,
// such as an .app, zipped). Add --json to see what the server answered.
//
// Env: VISOR_PORT, VISOR_TOKEN, VISOR_SESSION; VISOR_URL in a container.
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const base = (process.env.VISOR_URL || `ws://127.0.0.1:${process.env.VISOR_PORT || "7433"}`).replace(/^ws/, "http").replace(/\/+$/, "");
const token = process.env.VISOR_TOKEN || "";
const session = process.env.VISOR_SESSION || "";

const usage = `usage: visor machine <status | lease <platform> | list | show <id> | renew <id> | release <id> |
       ssh <id> [command …] | screenshot <id> <out.png> | simctl <id> … | adb <id> … | upload <id> <file>> [--json]`;

function fail(message) {
  process.stderr.write(`visor: ${message}\n`);
  process.exit(1);
}

async function call(method, route, body) {
  if (!token || !session) fail("this is not a Visor session (VISOR_TOKEN and VISOR_SESSION are not set)");
  const query = method === "GET" || method === "DELETE" ? `${route.includes("?") ? "&" : "?"}session=${encodeURIComponent(session)}` : "";
  let response;
  try {
    response = await fetch(`${base}/api/machines${route}${query}`, {
      method,
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify({ session, ...body }),
    });
  } catch (error) {
    fail(`could not reach the Visor server at ${base}: ${error.cause ? error.cause.message : error.message}`);
  }
  const text = await response.text();
  let answer;
  try { answer = JSON.parse(text); } catch { answer = { message: text }; }
  if (!response.ok) fail(answer.message || answer.error || `${response.status}`);
  return answer;
}

function minutesLeft(expires) {
  const minutes = Math.round((expires * 1000 - Date.now()) / 60000);
  return minutes <= 0 ? "expired" : `${minutes} min left`;
}

function describe(lease) {
  const lines = [`${lease.id}  ${lease.platform} (${lease.config})  ${lease.state}  ${minutesLeft(lease.expires)}`];
  if (lease.error) lines.push(`  error: ${lease.error}`);
  if (lease.sshPort) lines.push(`  ssh:  ssh -p ${lease.sshPort} ${lease.sshUser || "runner"}@${lease.host}   (visor machine ssh ${lease.id})`);
  if (lease.vncPort) lines.push(`  vnc:  ${lease.host}:${lease.vncPort}${lease.vncPassword ? `  password ${lease.vncPassword}` : ""}`);
  if (lease.adbPort) lines.push(`  adb:  adb connect ${lease.host}:${lease.adbPort}   (visor machine adb ${lease.id} …)`);
  if (lease.udid) lines.push(`  simulator ${lease.udid}   (visor machine simctl ${lease.id} …)`);
  return lines.join("\n");
}

function publicKey() {
  for (const name of ["id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"]) {
    const file = path.join(os.homedir(), ".ssh", name);
    if (fs.existsSync(file)) return fs.readFileSync(file, "utf8").trim();
  }
  return undefined;
}

// A local path sent to the lease first: a folder zipped (with its own name
// at the top, as an .app must be), named @<its name> in the command.
async function sendPaths(id, args) {
  const sent = [];
  for (const argument of args) {
    const looksLocal = argument.includes("/") || /\.(app|apk|ipa)$/.test(argument);
    if (!looksLocal || !fs.existsSync(argument)) { sent.push(argument); continue; }
    const name = path.basename(argument.replace(/\/+$/, ""));
    let upload = name;
    let data;
    if (fs.statSync(argument).isDirectory()) {
      const zip = path.join(os.tmpdir(), `visor-${process.pid}-${name}.zip`);
      const script = "import shutil, sys, os; shutil.make_archive(sys.argv[1][:-4], 'zip', os.path.dirname(os.path.abspath(sys.argv[2])), os.path.basename(os.path.abspath(sys.argv[2])))";
      const made = spawnSync("python3", ["-c", script, zip, argument], { stdio: ["ignore", "ignore", "inherit"] });
      if (made.status !== 0) fail(`could not zip ${argument}`);
      data = fs.readFileSync(zip);
      fs.rmSync(zip, { force: true });
      upload = `${name}.zip`;
    } else {
      data = fs.readFileSync(argument);
    }
    process.stderr.write(`visor: sending ${argument} (${Math.round(data.length / 1048576)} MB)\n`);
    await call("POST", `/${id}/upload`, { name: upload, data: data.toString("base64") });
    sent.push(`@${name}`);
  }
  return sent;
}

async function main() {
  const argv = process.argv.slice(2);
  const json = argv.includes("--json");
  const [noun, verb, ...after] = argv.filter((arg) => arg !== "--json");
  // Options (--config=…) before or after the machine, but not among what
  // is passed on to ssh, simctl or adb after it.
  const passedOn = verb === "ssh" || verb === "simctl" || verb === "adb";
  const options = {};
  const positional = [];
  for (const arg of after) {
    const match = /^--([a-z]+)(?:=(.*))?$/.exec(arg);
    if (match && !(passedOn && positional.length > 0)) options[match[1]] = match[2] === undefined ? true : match[2];
    else positional.push(arg);
  }
  const [id, ...rest] = positional;
  const say = (answer, text) => process.stdout.write(`${json ? JSON.stringify(answer, null, 2) : text}\n`);
  if (noun !== "machine" && noun !== "machines") { process.stderr.write(`${usage}\n`); process.exit(2); }
  switch (verb) {
    case "status": {
      const status = await call("GET", "/status");
      const lines = [];
      // Each server that answered, nearest first (a machine comes from the
      // nearest with room for it).
      for (const server of status.servers || [status]) {
        lines.push(`oss at ${server.server}${server.distance ? ` (${server.name}, ${server.distance})` : ""}`);
        for (const c of server.capacity) if (c.platform !== "container") lines.push(`  ${c.platform}: ${c.leased} of ${c.limit} leased`);
        const configs = {};
        for (const b of server.bases) if (b.platform !== "container") (configs[b.platform] = configs[b.platform] || []).push(b.config);
        for (const [platform, list] of Object.entries(configs)) lines.push(`  ${platform} configs: ${list.join(", ")}`);
      }
      return say(status, lines.join("\n"));
    }
    case "lease": {
      if (!id) fail("lease what? macos, linux, windows, ios or android");
      if (options.wait) process.stderr.write("visor: waiting for a machine to be free…\n");
      const lease = await call("POST", "", {
        platform: id, config: typeof options.config === "string" ? options.config : undefined,
        minutes: options.minutes ? Number(options.minutes) : undefined, wait: Boolean(options.wait), key: publicKey(),
        server: typeof options.server === "string" ? options.server : undefined,
      });
      return say(lease, describe(lease));
    }
    case "list": {
      const answer = await call("GET", "");
      return say(answer, answer.leases.length ? answer.leases.map(describe).join("\n") : "This session leases no machines.");
    }
    case "show": {
      if (!id) fail("show which?");
      const lease = await call("GET", `/${id}`);
      return say(lease, describe(lease));
    }
    case "renew": {
      if (!id) fail("renew which?");
      const lease = await call("POST", `/${id}/renew`, { minutes: options.minutes ? Number(options.minutes) : undefined });
      return say(lease, describe(lease));
    }
    case "release": {
      if (!id) fail("release which?");
      return say(await call("DELETE", `/${id}`), `Released ${id}.`);
    }
    case "ssh": {
      if (!id) fail("ssh to which?");
      const lease = await call("GET", `/${id}`);
      if (!lease.sshPort) fail(`${id} is not reached over SSH (${lease.platform})`);
      const known = path.join(os.homedir(), ".ssh", `visor_known_hosts_${id}`);
      fs.mkdirSync(path.dirname(known), { recursive: true });
      const command = rest[0] === "--" ? rest.slice(1) : rest;
      const ran = spawnSync("ssh", ["-p", String(lease.sshPort), "-o", "StrictHostKeyChecking=accept-new", "-o", `UserKnownHostsFile=${known}`,
        `${lease.sshUser || "runner"}@${lease.host}`, ...command], { stdio: "inherit" });
      process.exit(ran.status === null ? 1 : ran.status);
    }
    case "screenshot": {
      if (!id || !rest[0]) fail("usage: visor machine screenshot <id> <out.png>");
      const answer = await call("GET", `/${id}/screenshot`);
      fs.writeFileSync(rest[0], Buffer.from(answer.png, "base64"));
      return say({ wrote: rest[0] }, `Wrote ${rest[0]}.`);
    }
    case "simctl":
    case "adb": {
      if (!id) fail(`${verb} on which?`);
      const result = await call("POST", `/${id}/command`, { arguments: await sendPaths(id, rest) });
      if (json) return say(result, "");
      if (result.output) process.stdout.write(result.output.endsWith("\n") ? result.output : `${result.output}\n`);
      if (result.error) process.stderr.write(result.error.endsWith("\n") ? result.error : `${result.error}\n`);
      process.exit(result.status);
    }
    case "upload": {
      if (!id || !rest[0]) fail("usage: visor machine upload <id> <file>");
      const sent = await sendPaths(id, [rest[0].includes("/") ? rest[0] : `./${rest[0]}`]);
      return say({ uploaded: sent[0] }, `Sent as ${sent[0]}.`);
    }
    default:
      process.stderr.write(`${usage}\n`);
      process.exit(2);
  }
}

main().catch((error) => fail(error.message));
"""#
}
