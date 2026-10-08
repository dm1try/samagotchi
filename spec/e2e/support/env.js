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
    // A fake gh (support/fake_gh.sh) for the github-pr bundle's line links:
    // first on PATH, so no scenario reaches GitHub.
    const bin = path.join(root, "bin");
    fs.mkdirSync(bin);
    fs.copyFileSync(path.join(HERE, "fake_gh.sh"), path.join(bin, "gh"));
    fs.chmodSync(path.join(bin, "gh"), 0o755);
    Object.assign(childEnv, {
      PATH: `${bin}${path.delimiter}${process.env.PATH}`,
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
    // A test bundle whose plugin sends a notice marked fallback_for: display
    // and a plain one after an E2E_FALLBACK answer, for that scenario.
    execFileSync(path.join(CHECKOUT, "bin", "chi"), ["bundle", "install", path.join(CHECKOUT, "spec", "e2e", "support", "bundles", "e2e-fallback-notice")],
      { cwd: dirs.project, env: childEnv, stdio: "ignore" });
    // github-pr (shipped), for the PR line links scenario: its gh is the fake.
    execFileSync(path.join(CHECKOUT, "bin", "chi"), ["bundle", "install", "github-pr"],
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

// A scenario's own settings (YAML appended to config.yml) for the next
// turns, or none again with null: the workers read config.yml at each turn.
// Each +key+ keeps its own (useTurnLimit's is "turn"), so they add up.
export function useConfigExtra(env, extra, key = "extra") {
  env.configExtras = { ...env.configExtras, [key]: extra ?? "" };
  fs.writeFileSync(path.join(env.dirs.config, "samagotchi", "config.yml"),
    config(env.fakePort, Object.values(env.configExtras).join("")));
}

// A turn's step limit (turn.max_iterations) for the next turns, or the
// default again with null.
export function useTurnLimit(env, limit) {
  useConfigExtra(env, limit == null ? null : `turn:\n  max_iterations: ${limit}\n`, "turn");
}

// A model note (model_notes_<name>, system scope) whose models: line
// matches the fake model, for the next prompt builds; null text removes it.
// @return the note's file
export function useModelNote(env, name, text) {
  const dir = path.join(env.dirs.config, "samagotchi", "memories");
  const file = path.join(dir, `model_notes_${name}.md`);
  if (text == null) {
    fs.rmSync(file, { force: true });
  } else {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(file, `models: fake-*\n${text}\n`);
  }
  return file;
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

// A parent and two delegates (delegate: true, parent_id) written straight
// into the state dir, as a worker saves them (tmp + rename): chi web's hub
// lists them within its next scan. No worker runs them, except with
// +waiting+: the second delegate has an open question, and a stand-in
// worker (a ruby holding its owner lock as kind "worker", OwnerLock) makes
// it live, which a question needs to count as open (Session#waiting_question).
// +parentMemories+ become the parent's used_memory_names.
// Returns their ids; remove() stops the stand-in and deletes the files (the
// hub drops them), so later scenarios of this worker don't see them.
export async function seedFamily(env, { waiting = false, tag = "Family", parentMemories = [] } = {}) {
  const dir = path.join(env.dirs.state, "samagotchi", "sessions");
  fs.mkdirSync(dir, { recursive: true });
  const stamp = `${Date.now().toString(16)}${Math.floor(Math.random() * 0xfff).toString(16)}`;
  const ids = { parent: `e2e-parent-${stamp}`, children: [`e2e-child-a-${stamp}`, `e2e-child-b-${stamp}`] };
  const now = new Date().toISOString();
  const session = (id, prompt, extra = {}) => ({
    metadata_version: 3, id, mode: "assist", model_name: "fake-script", model_typed: null,
    working_directory: env.dirs.project, messages: [{ role: "user", content: prompt }],
    created_at: now, updated_at: now, status: "idle", last_prompt: prompt, first_preview: prompt,
    test_run: false, pending_question: null, used_memory_names: [], project_root: env.dirs.project,
    preloaded_memory_names: [], muted_memory_names: [], parent_id: null, scratch: false, last_turn: null,
    delegate: false, ...extra,
  });
  const files = [
    session(ids.parent, `${tag} parent coordinates`, { used_memory_names: parentMemories }),
    session(ids.children[0], `${tag} child one fixes`, { parent_id: ids.parent, delegate: true }),
    session(ids.children[1], `${tag} child two documents`, {
      parent_id: ids.parent, delegate: true,
      ...(waiting ? { pending_question: { id: `q-${stamp}`, kind: "question", question: "Which one?" } } : {}),
    }),
  ];
  let holder = null;
  if (waiting) {
    const lockDir = path.join(dir, ids.children[1]);
    holder = spawn("ruby", ["-I", path.join(CHECKOUT, "lib"), "-rsamagotchi/owner_lock", "-e",
      "lock = Samagotchi::OwnerLock.acquire(ARGV[0], kind: 'worker') or abort('locked'); $stdout.puts('held'); $stdout.flush; $stdin.read",
      lockDir], { stdio: ["pipe", "pipe", "ignore"] });
    env.procs.push(holder);
    await new Promise((resolve, reject) => {
      holder.stdout.once("data", resolve);
      holder.once("exit", (code) => reject(new Error(`the owner lock stand-in exited (${code})`)));
    });
  }
  for (const s of files) {
    const file = path.join(dir, `${s.id}.json`);
    fs.writeFileSync(`${file}.tmp`, JSON.stringify(s, null, 2));
    fs.renameSync(`${file}.tmp`, file);
  }
  return {
    ...ids,
    remove() {
      if (holder && holder.exitCode === null) holder.stdin.end();
      for (const s of files) {
        fs.rmSync(path.join(dir, `${s.id}.json`), { force: true });
        fs.rmSync(path.join(dir, s.id), { recursive: true, force: true });
      }
    },
  };
}
