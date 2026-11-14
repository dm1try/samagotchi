// The main page booted whole (index.html + app.js) in happy-dom, for
// viewer_boot.test.js: run as its own process (`node page_boot.js JSON`,
// JSON {can: [...], kind}), since app.js is the page's top-level module and
// would leave its globals, listeners and timers in the suite's one process.
// chi web is faked: fetch answers by route (the session show has a running
// turn, a question, a review participant's finished turn and a revisable
// answer), EventSource records its URL and never opens. Prints one JSON
// line: {requests: ["GET /api/…"], streams: ["/api/…"], controls: {name:
// "absent" | "hidden" | "shown"}, errors: [...]}.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { Window } from "happy-dom";

const args = JSON.parse(process.argv[2] || "{}");
const PUBLIC = fileURLToPath(new URL("../../../lib/samagotchi/web/public/", import.meta.url));
const SID = "11111111-1111-4111-8111-111111111111";
const errors = [];
const requests = [];
const streams = [];

const window = new Window({
  url: `http://127.0.0.1:4567/#/s/${SID}`,
  width: 1280,
  height: 900,
  settings: { disableJavaScriptFileLoading: true, disableJavaScriptEvaluation: true, disableCSSFileLoading: true },
});
const html = readFileSync(`${PUBLIC}index.html`, "utf8").replace(/<script type="module"[^>]*><\/script>/, "");
window.document.write(html);
const body = window.document.body;
const stamp = { "data-version": "0.0.0", "data-annotate-presets": "[]", "data-working-set": "1", "data-reload-check": "1",
                "data-viewer-kind": args.kind || "owner", "data-viewer-can": (args.can || []).join(" ") };
// A participant's page opens their grant's session (App#participant_index_data).
if (args.kind === "participant") Object.assign(stamp, { "data-session": SID, "data-session-title": "Fix the install notes" });
for (const [key, value] of Object.entries(stamp)) body.setAttribute(key, value);

// The page's globals: happy-dom's window's, where the process has none.
for (const key of Object.getOwnPropertyNames(window)) {
  if (key in globalThis) continue;
  try { globalThis[key] = window[key]; } catch (_) {}
}
for (const key of ["window", "document", "location", "history", "navigator", "localStorage", "sessionStorage", "CSS",
  "getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame", "matchMedia", "MutationObserver", "CustomEvent",
  "Event", "KeyboardEvent", "getSelection", "Node", "HTMLElement", "Element", "DocumentFragment", "DOMParser"]) {
  try { globalThis[key] = key === "window" ? window : window[key]; } catch (_) {}
}
globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} };
globalThis.IntersectionObserver = class { observe() {} unobserve() {} disconnect() {} };
window.HTMLElement.prototype.animate ??= () => ({ finished: Promise.resolve(), cancel() {}, playState: "finished" });
window.HTMLElement.prototype.scrollIntoView ??= () => {};
globalThis.confirm = () => false;
globalThis.alert = () => {};
window.confirm = globalThis.confirm;
window.alert = globalThis.alert;
process.on("uncaughtException", (e) => errors.push(String(e?.stack || e)));
process.on("unhandledRejection", (e) => errors.push(String(e?.stack || e)));

const AT = "2026-11-13T12:00:00Z";
// Two drawn turns from the shared scenario (a step text, a tool row, the
// answer): the owner's, and the same as a review participant's whose answer
// holds a fenced block a bundle's renderer would draw.
const scenario = JSON.parse(readFileSync(fileURLToPath(new URL("../../shared/turn_drawings/tools_answer.json", import.meta.url)), "utf8")).show;
const REVIEW = "turn-review";
const reviewed = (value) => JSON.parse(JSON.stringify(value).replaceAll("turn-tools", REVIEW));
const reviewMessages = reviewed(scenario.messages).map((m, i) => (i === 0
  ? { ...m, author: "p:p_0123abcd", author_name: "Alex", participant_mode: "review" }
  : m.content === "It says alpha, beta." ? { ...m, content: "It says:\n\n```mermaid\ngraph TD; A-->B\n```",
                                             html: '<p>It says:</p><pre data-lang="mermaid"><code>graph TD; A--&gt;B</code></pre>' } : m));
const reviewDrawing = reviewed(scenario.turn_drawings["turn-tools"]);
reviewDrawing.events.at(-1).text = "It says:\n\n```mermaid\ngraph TD; A-->B\n```";
const show = {
  session: { id: SID, status: "running", mode: "assist", model_name: "TestModel", working_directory: "/work", created_at: AT,
             updated_at: AT, bridge_up: true, worker_features: ["delivery", "revise", "verify", "task_stop"], owner: "worker",
             title: "Fix the install notes", first_preview: "look at a.txt",
             thinking: { level: "high", source: "session", own: "high" } },
  messages: [...scenario.messages, ...reviewMessages],
  turn_drawings: { ...scenario.turn_drawings, [REVIEW]: reviewDrawing },
  current_turn: { turn_id: "t3", prompt: "Now the changelog", status: "running", pending_question: null },
  replay: [{ type: "turn_started", turn_id: "t3", prompt: "Now the changelog", origin: null }],
  queued: [], queued_commands: [], cards: [], init_tasks: [], history: [],
  commands: [{ name: "/help", description: "Help" }, { name: "/model", description: "Model" }],
  pending_question: { id: "q1", status: "pending", question: "Which file?", options: ["README.md", "CHANGELOG.md"] },
  continue_offer: null, recap: null, saved_recap: null,
  capabilities: { display: true, editor: false }, editor_url: null,
  viewer: { kind: args.kind || "owner", id: null, name: null, can: args.can || [] },
  last_event_seq: 1, last_event_id: "1-1",
  timing: { turn_records: [], tool_records: [], turn_count: 2, active_turn: { id: "t3", started_at: AT }, active_tools: [] },
};
const ANSWERS = [
  [/^\/api\/sessions\/[^/]+$/, () => show],
  [/^\/api\/sessions$/, () => ({ sessions: [{ ...show.session }] })],
  [/^\/api\/models$/, () => ({ models: [], default: "TestModel" })],
  [/^\/api\/history$/, () => ({ entries: [] })],
  [/^\/api\/push$/, () => ({ enabled: false })],
  [/^\/api\/block_renderers$/, () => ({ renderers: [] })],
  [/^\/api\/render$/, () => ({ html: "<p>x</p>" })],
  [/\/context$/, () => ({ items: [] })],
  [/\/participants$/, () => ({ participants: [] })],
  [/\/working_set$/, () => ({ items: [] })],
];
function answer(path) {
  const found = ANSWERS.find(([pattern]) => pattern.test(path));
  return found ? found[1]() : {};
}
globalThis.fetch = window.fetch = async (input, init = {}) => {
  const url = new URL(String(input?.url || input), "http://127.0.0.1:4567");
  requests.push(`${(init.method || "GET").toUpperCase()} ${url.pathname}`);
  const json = answer(url.pathname);
  return new window.Response(JSON.stringify(json), { status: 200, headers: { "Content-Type": "application/json" } });
};
class FakeEventSource {
  constructor(url) {
    streams.push(String(url).replace(/\?.*$/, ""));
    this.url = url;
    this.readyState = 0;
  }

  addEventListener() {}
  removeEventListener() {}
  close() { this.readyState = 2; }
}
globalThis.EventSource = window.EventSource = FakeEventSource;

const settle = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
try {
  await import(`${PUBLIC}app.js`);
} catch (e) {
  errors.push(String(e?.stack || e));
}
await settle(400);
// The owner's composer would take a typed "/" line here; open the step texts
// and the stage's rows so their reads (POST /api/render) are asked.
for (const step of window.document.querySelectorAll("details")) step.open = true;
await settle(200);

const doc = window.document;
// What the viewer sees of a control: no element, an element hidden (by
// itself or a parent), or shown.
function state(selector) {
  const els = [...doc.querySelectorAll(selector)];
  if (!els.length) return "absent";
  return els.some((el) => !el.closest("[hidden], [data-withheld]") && el.style.display !== "none") ? "shown" : "hidden";
}
const CONTROLS = {
  newBtn: "#newBtn", scope: "#scope", topStrip: "#topStrip", stripStatus: "#stripStatus", stripGrip: "#stripGrip",
  notifyBtn: "#notifyBtn", titleRenameBtn: "#titleRenameBtn", modelPick: "#modelPick", attachBtn: "#attachBtn",
  infoMoreBtn: "#infoMoreBtn", infoStopBtn: "#infoStopBtn", infoContinueBtn: "#infoContinueBtn",
  infoArchiveBtn: "#infoArchiveBtn", infoDeleteBtn: "#infoDeleteBtn",
  stopTurn: ".ts-cancel", questionCard: ".bubble.question, details.question",
  applyRow: ".review-apply", reviseBtn: ".revise-btn", settingsChip: ".settings-chip",
};
const controls = Object.fromEntries(Object.entries(CONTROLS).map(([name, selector]) => [name, state(selector)]));
process.stdout.write(`${JSON.stringify({ requests: [...new Set(requests)].sort(), streams: [...new Set(streams)].sort(), controls, errors })}\n`);
process.exit(0);
