// The stage perf probe (script/stage-perf-probe; docs/testing.md): a session
// of 300 finished turns with 100 cards (session.rb), opened in chi web with
// the page's probe on (stage_probe.js, ?stage_probe=1), then
// one turn that asks a question and an approval (the e2e fake model), a
// reload while the question waits, both answered. It prints the numbers:
// stage:refresh n/p50/p95/max, the session's open, tap→settled per card,
// reload→card drawn, the JS heap (after a GC) before the open, after
// it and after the turn, and the cards as data (card_registry.js): each
// event's apply, each read's seed, the registry's entries and bytes.
//
// Isolated: HOME and XDG_* under tmp/stage-probe-<stamp>/ in the checkout,
// removed after (--keep leaves it). Time-bounded: the generation must finish
// within 60 s, the browser run within 180 s, and the whole probe is cut at
// 300 s. It stops only what it started: chi web and the fake model by their
// own child handles, the session's worker through chi web's stop route.
import { execFileSync, spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "@playwright/test";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CHECKOUT = path.resolve(HERE, "../..");
const GENERATE_MS = 60_000;
const RUN_MS = 180_000;
const HARD_MS = 300_000;
const keep = process.argv.includes("--keep");
const headed = process.argv.includes("--headed");
// web.reload_check on: the turn's hand-off read again and compared, timed
// (reload_check.js: reload:compare, reload:posted) and its counts kept.
const reloadCheck = process.argv.includes("--reload-check");

const started = Date.now();
const root = path.join(CHECKOUT, "tmp", `stage-probe-${process.pid}-${started.toString(36)}`);
const dirs = { home: path.join(root, "home"), config: path.join(root, "home", ".config"), state: path.join(root, "state"),
  fake: path.join(root, "fake"), project: path.join(root, "project") };
const children = [];
let browser = null;
let base = null;
let sessionId = null;
let runTimer = null;

const SCRIPT = {
  delay: 0.01,
  iterations: [
    { text: "Two files could answer it: README.md describes the project, Gemfile lists its gems.",
      tools: [{ name: "ask_user_question", arguments: { question: "Which file should I read?", options: ["README.md", "Gemfile"] } }] },
    { text: "Running the command that needs approval.", tools: [{ name: "execute", arguments: { command: "echo PROBE_APPROVED" } }] },
    { text: "The approved command ran. **Done**." },
  ],
};

function config(fakePort) {
  return `default:
  model: fake-script
hosts:
  main:
    url: http://127.0.0.1:${fakePort}/v1
    api: openai
retry:
  max: 0
recap: false
update:
  notify: off
guardrails:
  rules:
    - id: probe-ask
      tool: shell
      command: 'echo PROBE_APPROVED'
      verdict: ask
      reason: the stage probe's approval
${reloadCheck ? "web:\n  reload_check: true\n" : ""}`;
}

function freePort() {
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

async function waitFor(url, what, proc, timeoutMs = 30_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (proc.exitCode !== null) throw new Error(`${what} exited (${proc.exitCode})`);
    try {
      if ((await fetch(url)).ok) return;
    } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error(`${what} did not answer ${url} within ${timeoutMs} ms`);
}

const exited = (proc, ms) => new Promise((resolve) => {
  if (proc.exitCode !== null || proc.signalCode !== null) return resolve(true);
  const timer = setTimeout(() => resolve(false), ms);
  proc.once("exit", () => { clearTimeout(timer); resolve(true); });
});

// Only what this probe started: the worker through chi web, then chi web
// and the fake by their own handles.
async function cleanup() {
  try { await browser?.close(); } catch { /* gone */ }
  if (base && sessionId) {
    try { await fetch(`${base}/api/sessions/${sessionId}/stop`, { method: "POST" }); } catch { /* chi web gone */ }
  }
  for (const proc of children.reverse()) {
    if (proc.exitCode !== null || proc.signalCode !== null) continue;
    proc.kill("SIGINT");
    if (!(await exited(proc, 5000))) {
      proc.kill("SIGKILL");
      await exited(proc, 2000);
    }
  }
  let left = [];
  try {
    left = execFileSync("pgrep", ["-f", root], { encoding: "utf8" }).split("\n").filter(Boolean);
  } catch { /* none */ }
  if (left.length) console.error(`stage probe: processes still name ${root} (not killed): ${left.join(" ")}`);
  if (keep || left.length) console.error(`stage probe: kept ${root}`);
  else fs.rmSync(root, { recursive: true, force: true });
}

const hard = setTimeout(async () => {
  console.error(`stage probe: cut at ${HARD_MS / 1000} s`);
  await cleanup();
  process.exit(2);
}, HARD_MS);

function stats(list) {
  if (!list.length) return { n: 0 };
  const sorted = [...list].sort((a, b) => a - b);
  const at = (q) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))];
  const r = (ms) => Math.round(ms * 1000) / 1000;
  return { n: sorted.length, p50: r(at(0.5)), p95: r(at(0.95)), max: r(sorted[sorted.length - 1]) };
}

async function heap(cdp) {
  await cdp.send("HeapProfiler.collectGarbage");
  const { usedSize } = await cdp.send("Runtime.getHeapUsage");
  return Math.round(usedSize / 1024);
}

const measures = (page, name) => page.evaluate((name) => performance.getEntriesByName(name).map((m) => m.duration), name);
const refreshes = (page) => measures(page, "stage:refresh");
// The cards as data (card_registry.js, globalThis.chiCardRegistry while
// probing): its entries and their JSON bytes.
const registrySize = (page) => page.evaluate(() => {
  const r = globalThis.chiCardRegistry;
  if (!r) return null;
  const entries = r.size();
  const bytes = r.bytes();
  return { entries, bytes, bytes_per_entry: entries ? Math.round(bytes / entries) : null };
});

// Picks +option+ (none: the first) and taps Submit on the stage's waiting
// card; the time until the card is answered (the server's event back).
const tapSettled = (page, option) => page.evaluate(async (option) => {
  const card = document.querySelector("#turnStage .bubble.question:not(.answered)");
  const input = [...card.querySelectorAll(".question-option input")].find((i) => !option || i.value === option);
  input.click();
  const t0 = performance.now();
  const done = new Promise((resolve) => {
    const seen = () => card.classList.contains("answered");
    new MutationObserver((_, obs) => { if (seen()) { obs.disconnect(); resolve(); } })
      .observe(card, { attributes: true, attributeFilter: ["class"] });
  });
  card.querySelector(".question-submit").click();
  await done;
  return performance.now() - t0;
}, option);

async function main() {
  for (const d of [path.join(dirs.config, "samagotchi"), dirs.state, dirs.fake, dirs.project]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(dirs.project, "README.md"), "# probe project\n");
  fs.writeFileSync(path.join(dirs.fake, "mode"), "script\n");
  fs.writeFileSync(path.join(dirs.fake, "script.json"), JSON.stringify(SCRIPT));
  const fakePort = await freePort();
  fs.writeFileSync(path.join(dirs.config, "samagotchi", "config.yml"), config(fakePort));
  const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("SAMAGOTCHI_") && !k.startsWith("XDG_")));
  Object.assign(env, { HOME: dirs.home, XDG_CONFIG_HOME: dirs.config, XDG_STATE_HOME: dirs.state, SAMAGOTCHI_ENV: "test" });

  const fake = spawn("python3", [path.join(CHECKOUT, "spec/e2e/support/fake_openai.py"), String(fakePort), dirs.fake, "none"],
    { stdio: ["ignore", "ignore", fs.openSync(path.join(root, "fake.log"), "a")] });
  children.push(fake);
  await waitFor(`http://127.0.0.1:${fakePort}/v1/models`, "fake_openai.py", fake);

  const genAt = Date.now();
  sessionId = execFileSync("ruby", [path.join(HERE, "session.rb"), dirs.project], { env, encoding: "utf8", timeout: GENERATE_MS }).trim();
  const generateMs = Date.now() - genAt;

  const webPort = await freePort();
  const web = spawn(path.join(CHECKOUT, "bin", "chi"), ["web", "--port", String(webPort)],
    { cwd: dirs.project, env, stdio: ["ignore", "ignore", fs.openSync(path.join(root, "web.log"), "a")] });
  children.push(web);
  base = `http://127.0.0.1:${webPort}`;
  await waitFor(`${base}/api/models`, "chi web", web);

  const runAt = Date.now();
  runTimer = setTimeout(() => { console.error(`stage probe: the run passed ${RUN_MS / 1000} s`); }, RUN_MS);
  browser = await chromium.launch({ headless: !headed });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const reloadPosts = [];
  page.on("request", (req) => { if (req.method() === "POST" && req.url().endsWith("/reload_check")) reloadPosts.push(req.postDataJSON()); });
  page.setDefaultTimeout(60_000);
  const cdp = await page.context().newCDPSession(page);
  // The probe on for the tab (stage_probe.js): kept over the hash jump and the reload.
  await page.goto(`${base}/?stage_probe=1`);
  await page.locator("#prompt").waitFor();
  const heapBefore = await heap(cdp);

  // The open: the hash names the session, until the last turn's answer is drawn.
  const openMs = await page.evaluate(async (id) => {
    const t0 = performance.now();
    location.hash = `#/s/${encodeURIComponent(id)}`;
    await new Promise((resolve, reject) => {
      const drawn = () => [...document.querySelectorAll("#history .bubble.output")].some((el) => el.textContent.includes("(299)"));
      const tick = () => {
        if (drawn()) return resolve();
        if (performance.now() - t0 > 60_000) {
          const hist = document.querySelector("#history");
          return reject(new Error(`the session's history wasn't drawn in 60 s: ${hist.children.length} children, ends ${JSON.stringify(hist.lastElementChild?.outerHTML.slice(0, 300))}, hash ${location.hash}`));
        }
        setTimeout(tick, 16);
      };
      tick();
    });
    return performance.now() - t0;
  }, sessionId);
  // What the open drew: every answer and plugin card, but only the answered
  // questions CardStore keeps (its cap: 20 cards and questions together, the
  // newest; a finished turn's question is drawn from that list alone).
  const drawnCounts = await page.evaluate(() => ({
    outputs: document.querySelectorAll("#history .bubble.output").length,
    cards: document.querySelectorAll("#history .plugin-card").length,
    questions: document.querySelectorAll("#history .bubble.question").length,
  }));
  const heapOpen = await heap(cdp);
  const registryOpen = await registrySize(page);
  const seedOpen = await measures(page, "cards:seed");

  await page.locator("#prompt").fill("Probe: read a file of my choice");
  await page.locator("#actionBtn").click();
  const waitingQuestion = page.locator("#turnStage .ts-extras .bubble.question:not(.answered)");
  await waitingQuestion.waitFor();
  const beforeReload = await refreshes(page);
  const appliesBefore = await measures(page, "cards:apply");

  // A reload while the question waits: until its card is drawn again.
  const reloadAt = Date.now();
  await page.reload();
  await page.locator("#turnStage .ts-extras .bubble.question:not(.answered)").waitFor();
  const reloadMs = Date.now() - reloadAt;

  const questionMs = await tapSettled(page, "README.md");
  await page.locator('#turnStage .bubble.question[data-kind="approval"]:not(.answered)').waitFor();
  const approvalMs = await tapSettled(page, null);
  await page.locator("#history .bubble.output", { hasText: "The approved command ran" }).waitFor();
  await page.mouse.move(0, 0);
  await page.locator("#turnStage").waitFor({ state: "hidden" });
  if (reloadCheck) await page.waitForFunction(() => performance.getEntriesByName("reload:posted").length > 0, null, { timeout: 15_000 });
  const reloadMeasures = { compare: await measures(page, "reload:compare"), posted: await measures(page, "reload:posted") };
  const heapTurn = await heap(cdp);
  const afterReload = await refreshes(page);
  const appliesAfter = await measures(page, "cards:apply");
  const seedReload = await measures(page, "cards:seed");
  const registryTurn = await registrySize(page);
  const report = await page.evaluate(() => globalThis.chiStageProbe?.report() || null);
  clearTimeout(runTimer);
  const runMs = Date.now() - runAt;

  const out = {
    machine: process.env.PROBE_MACHINE || null,
    session: { turns: 300, cards: 60, questions: 40, drawn: drawnCounts,
      why: "a finished turn's answered question is drawn from CardStore's list only (its cap: the newest 20 cards and questions)" },
    generate_ms: generateMs,
    run_ms: runMs,
    "stage:refresh": stats([...beforeReload, ...afterReload]),
    "stage:refresh after the reload (chiStageProbe.report)": report?.["stage:refresh"] || null,
    open_ms: Math.round(openMs),
    tap_settled_ms: { question: Math.round(questionMs), approval: Math.round(approvalMs) },
    reload_card_ms: reloadMs,
    heap_kb: { before_open: heapBefore, after_open: heapOpen, after_turn: heapTurn },
    "cards:apply": stats([...appliesBefore, ...appliesAfter]),
    "cards:seed": stats([...seedOpen, ...seedReload]),
    registry: { after_open: registryOpen, after_turn: registryTurn },
    ...(reloadCheck ? { reload_check: { "reload:compare": stats(reloadMeasures.compare), "reload:posted": stats(reloadMeasures.posted), posts: reloadPosts } } : {}),
  };
  console.log(JSON.stringify(out, null, 2));
  if (generateMs > GENERATE_MS || runMs > RUN_MS) {
    console.error("stage probe: over its time budget");
    process.exitCode = 1;
  }
}

try {
  await main();
} catch (e) {
  console.error(`stage probe: ${e.stack || e.message}`);
  process.exitCode = 1;
} finally {
  clearTimeout(hard);
  clearTimeout(runTimer);
  await cleanup();
}
