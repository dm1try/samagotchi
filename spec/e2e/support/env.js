// One isolated chi for the e2e suite: a temp HOME / XDG_CONFIG_HOME /
// XDG_STATE_HOME, the scripted fake OpenAI server (fake_openai.py, mode
// "script") as hosts.main, and `bin/chi web` on a free port. stop() kills
// the web server, every session worker and the fake, then removes the dirs,
// and throws if a process under the temp root survives.
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CHECKOUT = path.resolve(HERE, "../../..");
export const SCRIPTS = path.join(HERE, "scripts");

// The rule the approval scenario trips (scripts/approval.json runs this command).
export const APPROVAL_COMMAND = "echo E2E_APPROVED";
// The file whose edit asks (scripts/edit.json writes it, then edits it).
export const EDIT_ASK_FILE = "e2e-settings.conf";

// @param extra YAML appended (a scenario's own settings: useTurnLimit)
function config(fakePort, extra = "") {
  return `default:
  model: fake-script
hosts:
  main:
    url: http://127.0.0.1:${fakePort}/v1
    api: openai
retry:
  max: 0
recap: false
bundles:
  check-in:
    after: 3
    every: 100
web:
  markdown: true
guardrails:
  rules:
    - id: e2e-ask
      tool: shell
      command: '${APPROVAL_COMMAND}'
      verdict: ask
      reason: the e2e approval scenario
    - id: e2e-edit-ask
      tool: edit
      path: '**/${EDIT_ASK_FILE}'
      verdict: ask
      reason: the e2e edit preview scenario
${extra}`;
}

export function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

async function waitFor(url, what, proc, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (proc.exitCode !== null) throw new Error(`${what} exited (${proc.exitCode}) before it answered ${url}`);
    try {
      const res = await fetch(url);
      if (res.ok) return;
    } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`${what} did not answer ${url} within ${timeoutMs} ms`);
}

// Every process whose command line names the temp root: the fake server and
// the session workers (run_session_loop(..., state_dir: "<root>/state/...")).
function pidsUnder(root) {
  try {
    return execFileSync("pgrep", ["-f", root], { encoding: "utf8" }).split("\n").filter(Boolean).map(Number)
      .filter((pid) => pid !== process.pid);
  } catch {
    return []; // pgrep exits 1 when nothing matches
  }
}

function signal(pid, sig) {
  try { process.kill(pid, sig); } catch { /* already gone */ }
}

async function settle(check, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (check()) return true;
    await new Promise((r) => setTimeout(r, 100));
  }
  return check();
}

// This machine's private IPv4 address (RFC 1918) on an interface that is
// up, as chi web's `lan` looks for one; null when there is none (a CI
// runner may have only a public one): the LAN scenario is skipped then.
export function privateIPv4() {
  const skipped = /^(utun|bridge|docker|vboxnet|vmnet|llw)/;
  for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
    if (skipped.test(name)) continue;
    for (const a of addrs || []) {
      if (a.family !== "IPv4" || a.internal) continue;
      if (/^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(a.address)) return a.address;
    }
  }
  return null;
}

// @param lan chi web with --web-host lan: env.lanURL is its LAN address
//   (where the token is asked for; the loopback baseURL isn't) and
//   env.tokenPath its access token's file
// @param installed the newest chi chi web believes installed
//   (SAMAGOTCHI_INSTALLED_VERSION; null: what really is)
export async function startEnv({ lan = false, installed = null } = {}) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "chi-e2e-")));
  const dirs = {
    root,
    home: path.join(root, "home"),
    config: path.join(root, "home", ".config"),
    state: path.join(root, "state"),
    fake: path.join(root, "fake"),
    project: path.join(root, "project"),
  };
  for (const d of [path.join(dirs.config, "samagotchi"), dirs.state, dirs.fake, dirs.project]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(dirs.project, "README.md"), "# e2e project\n\nA file the scripted turns read.\n");
  fs.writeFileSync(path.join(dirs.fake, "mode"), "script\n");

  const env = { root, dirs, procs: [] };
  try {
    const fakePort = await freePort();
    env.fakePort = fakePort;
    fs.writeFileSync(path.join(dirs.config, "samagotchi", "config.yml"), config(fakePort));
    // No upstream: the error modes' /props and /models get a 404 here instead
    // of going to the smoke runs' LAN llama.cpp (unreachable on CI: each
    // probe stalled the turn's start).
    const fake = spawn("python3", [path.join(HERE, "fake_openai.py"), String(fakePort), dirs.fake, "none"],
      { stdio: ["ignore", "ignore", fs.openSync(path.join(root, "fake.log"), "a")] });
    env.procs.push(fake);
    await waitFor(`http://127.0.0.1:${fakePort}/v1/models`, "fake_openai.py", fake);

    // Nothing from the caller's chi settings leaks in (SAMAGOTCHI_WEB_PORT, …).
    const childEnv = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("SAMAGOTCHI_")));
    Object.assign(childEnv, {
      HOME: dirs.home,
      XDG_CONFIG_HOME: dirs.config,
      XDG_STATE_HOME: dirs.state,
      SAMAGOTCHI_ENV: "test",
    });
    // The check-in bundle (installed like a user would), for its scenario;
    // after: 3 leaves the other scripts' turns alone.
    execFileSync(path.join(CHECKOUT, "bin", "chi"), ["bundle", "install", "check-in"],
      { cwd: dirs.project, env: childEnv, stdio: "ignore" });
    // loop-guard (shipped), for the thinking-loop scenario; its thinking watch
    // must leave every other script's turn alone.
    execFileSync(path.join(CHECKOUT, "bin", "chi"), ["bundle", "install", "loop-guard"],
      { cwd: dirs.project, env: childEnv, stdio: "ignore" });
    // A test bundle whose plugin shows a warn card mid-turn (a read of
    // e2e-warn-card.txt only), for the warn_card scenario.
    execFileSync(path.join(CHECKOUT, "bin", "chi"), ["bundle", "install", path.join(CHECKOUT, "spec", "e2e", "support", "bundles", "e2e-warn-card")],
      { cwd: dirs.project, env: childEnv, stdio: "ignore" });
    const webPort = await freePort();
    const webLog = fs.openSync(path.join(root, "web.log"), "a");
    const webArgs = ["web", "--port", String(webPort), ...(lan ? ["--web-host", "lan"] : [])];
    const webEnv = installed ? { ...childEnv, SAMAGOTCHI_INSTALLED_VERSION: installed } : childEnv;
    env.baseURL = `http://127.0.0.1:${webPort}`;
    // (Re)starts chi web on the same port: open tabs reconnect to it.
    env.startWeb = async () => {
      const web = spawn(path.join(CHECKOUT, "bin", "chi"), webArgs,
        { cwd: dirs.project, env: webEnv, stdio: ["ignore", webLog, webLog] });
      env.procs.push(web);
      env.web = web;
      await waitFor(`${env.baseURL}/api/models`, "chi web", web);
    };
    await env.startWeb();
    if (lan) {
      const info = await (await fetch(`${env.baseURL}/api/info`)).json();
      if (!info.lan) throw new Error("chi web --web-host lan answers without a LAN address");
      env.lanURL = `http://${info.lan}:${webPort}`;
      env.tokenPath = path.join(dirs.state, "samagotchi", "web-token");
    }
    return env;
  } catch (e) {
    await stopEnv(env).catch(() => {});
    throw e;
  }
}

// The fake serves <fake dir>/script.json to every request: pick a scenario's
// script before its turn starts.
export function useScript(env, name) {
  fs.copyFileSync(path.join(SCRIPTS, `${name}.json`), path.join(env.dirs.fake, "script.json"));
}

// A turn's step limit (turn.max_iterations) for the next turns, or the
// default again with null: the workers read config.yml at each turn.
export function useTurnLimit(env, limit) {
  const extra = limit == null ? "" : `turn:\n  max_iterations: ${limit}\n`;
  fs.writeFileSync(path.join(env.dirs.config, "samagotchi", "config.yml"), config(env.fakePort, extra));
}

// The fake's mode (fake_openai.py's header: 500, stall, …); "script" plays
// the script again.
export function useMode(env, mode) {
  fs.writeFileSync(path.join(env.dirs.fake, "mode"), `${mode}\n`);
}

// Stops chi web (as Ctrl-C does) and starts it again on the same port; the
// session workers keep running.
export async function restartWeb(env) {
  const { web } = env;
  signal(web.pid, "SIGINT");
  if (!(await settle(() => web.exitCode !== null || web.signalCode !== null, 5000))) {
    throw new Error("chi web did not stop on SIGINT");
  }
  await env.startWeb();
}

export async function stopEnv(env) {
  if (!env?.root) return;
  const { root } = env;
  for (const p of env.procs) if (p.exitCode === null) signal(p.pid, "SIGTERM");
  for (const pid of pidsUnder(root)) signal(pid, "SIGTERM");
  let clean = await settle(() => env.procs.every((p) => p.exitCode !== null) && pidsUnder(root).length === 0, 5000);
  if (!clean) {
    for (const p of env.procs) if (p.exitCode === null) signal(p.pid, "SIGKILL");
    for (const pid of pidsUnder(root)) signal(pid, "SIGKILL");
    clean = await settle(() => pidsUnder(root).length === 0, 3000);
  }
  const left = pidsUnder(root);
  if (process.env.E2E_KEEP) console.log(`e2e: kept ${root}`);
  else fs.rmSync(root, { recursive: true, force: true });
  if (left.length) throw new Error(`e2e: processes under ${root} survived SIGKILL: ${left.join(" ")}`);
}
