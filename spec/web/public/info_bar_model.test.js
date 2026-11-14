import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  BAR_ITEMS, barItemKeys, chainLinkView, infoBarModel, infoButtons, sessionBar, SPEED_NONE, workerBadgeFor,
} from "../../../lib/samagotchi/web/public/info_bar_model.js";
import { renderInfoBar } from "../../../lib/samagotchi/web/public/info_bar.js";
import { emptySessionState } from "../../../lib/samagotchi/web/public/session_state.js";

const ID = "0123456789abcdef";
const title = (s) => `title of ${s.id}`;

function args(over = {}) {
  return {
    id: ID, state: { ...emptySessionState(), status: "idle", model: "qwen", dir: "/p" }, sessions: [{ id: ID }],
    versions: { served: "1.0.0", installed: null }, cardTitle: title, continuing: new Set(), restarting: new Set(),
    streaming: false, running: false, ...over,
  };
}

test("no session: the buttons hidden, no line", () => {
  const { buttons, bar } = sessionBar(args({ id: null }));
  assert.equal(bar, null);
  assert.deepEqual([buttons.continue.shown, buttons.delete.shown, buttons.archive.shown, buttons.stop.shown], [false, false, false, false]);
  assert.equal(buttons.continue.text, "continue →");
});

test("a session's line: id, status, model, folder, no chain, parent or delegates", () => {
  const { bar, buttons } = sessionBar(args());
  assert.equal(bar.id, ID);
  assert.equal(bar.status, "idle");
  assert.equal(bar.model.text, "qwen");
  assert.equal(bar.dir, "/p");
  assert.deepEqual(bar.chain, { prev: null, next: null, pruned: false });
  assert.equal(bar.parent, null);
  assert.equal(bar.kids, null);
  assert.equal(bar.worker, null);
  assert.equal(bar.clock, "");
  assert.deepEqual([buttons.continue.shown, buttons.delete.shown, buttons.archive.shown, buttons.stop.shown], [true, true, true, false]);
});

test("a chain link: ← its previous, → its next (no continue then); the links' titles are the lists'", () => {
  const sessions = [
    { id: "prev0000", created_at: "2026-10-01T10:00:00Z", archived: true },
    { id: ID, continues: "prev0000", created_at: "2026-10-02T10:00:00Z" },
    { id: "next0000", continues: ID, created_at: "2026-10-03T10:00:00Z" },
  ];
  const { bar, buttons } = sessionBar(args({ sessions }));
  assert.equal(bar.chain.prev.id, "prev0000");
  assert.equal(bar.chain.prev.preview, "title of prev0000");
  assert.equal(bar.chain.prev.archived, true);
  assert.match(bar.chain.prev.date, /^2026-10-0[12]$/);
  assert.match(bar.chain.prev.stamp, /^2026-10-0[12] \d{2}:\d{2}$/);
  assert.equal(bar.chain.next.id, "next0000");
  assert.equal(buttons.continue.shown, false);
  assert.equal(chainLinkView(null, title), null);
  assert.deepEqual(chainLinkView({ id: "x" }, title), { id: "x", date: "", stamp: "", preview: "", archived: false });
});

test("a chain link's ← / → read its HH:MM when it started on the open link's day, else its date; the stamp is always both", () => {
  const local = (d, h, m) => new Date(2026, 9, d, h, m).toISOString();
  const link = (iso) => ({ id: "l", session: { id: "l", created_at: iso } });
  const same = chainLinkView(link(local(17, 14, 32)), title, local(17, 9, 12));
  assert.equal(same.date, "14:32");
  assert.equal(same.stamp, "2026-10-17 14:32");
  const other = chainLinkView(link(local(8, 14, 32)), title, local(17, 9, 12));
  assert.equal(other.date, "2026-10-08");
  assert.equal(other.stamp, "2026-10-08 14:32");
  // The open link's start unknown: its date, as before.
  assert.equal(chainLinkView(link(local(17, 14, 32)), title, null).date, "2026-10-17");
});

test("the info bar's links measure their day against the open session's created_at, its list entry's when the state has none", () => {
  const local = (d, h, m) => new Date(2026, 9, d, h, m).toISOString();
  const sessions = [
    { id: "prev0000", created_at: local(17, 9, 12) },
    { id: ID, continues: "prev0000", created_at: local(18, 8, 0) },
  ];
  // The open session's own created_at (the payload's) wins over the list's.
  const state = { ...emptySessionState(), createdAt: local(17, 15, 0) };
  assert.equal(sessionBar(args({ sessions, state })).bar.chain.prev.date, "09:12");
  // No createdAt in the state: the list's entry.
  assert.equal(sessionBar(args({ sessions })).bar.chain.prev.date, "2026-10-17");
  assert.equal(sessionBar(args({ sessions: [sessions[0], { ...sessions[1], created_at: local(17, 20, 0) }] })).bar.chain.prev.date, "09:12");
});

test("a delegate names its parent; a parent its delegates", () => {
  const sessions = [
    { id: ID, parent_id: "parent00", first_preview: "mine" },
    { id: "parent00", first_preview: "the parent" },
    { id: "kid00000", parent_id: ID, delegate: true, status: "running" },
  ];
  const { bar } = sessionBar(args({ sessions, state: { ...emptySessionState(), parentId: "parent00" } }));
  assert.equal(bar.parent.id, "parent00");
  assert.match(bar.parent.title, /parent00: the parent/);
  assert.equal(bar.kids.total, 1);
});

test("archive flips to unarchive; continue says continuing while one runs; a terminal's session has no continue", () => {
  const archived = sessionBar(args({ sessions: [{ id: ID, archived: true }] })).buttons.archive;
  assert.deepEqual([archived.archived, archived.text], [true, "unarchive"]);
  const busy = sessionBar(args({ continuing: new Set([ID]) })).buttons.continue;
  assert.deepEqual([busy.disabled, busy.text], [true, "continuing…"]);
  const tui = sessionBar(args({ state: { ...emptySessionState(), owner: "tui" } })).buttons;
  assert.equal(tui.continue.shown, false);
  assert.equal(tui.stop.shown, false);
});

test("stop while a worker runs it, or the page streams from one", () => {
  assert.equal(sessionBar(args({ state: { ...emptySessionState(), owner: "worker" } })).buttons.stop.shown, true);
  assert.equal(sessionBar(args({ streaming: true })).buttons.stop.shown, true);
  assert.equal(infoButtons({ id: null, state: emptySessionState(), chain: { next: null }, archived: false, continuing: false, streaming: true }).stop.shown, false);
});

test("an older worker's badge (with its Restart's busy state); none for a current one or a terminal's", () => {
  const state = { ...emptySessionState(), owner: "worker", workerVersion: "0.9.0", workerCompat: "restart_suggested",
                  workerFeatures: ["restart"] };
  const { bar } = sessionBar(args({ state, restarting: new Set([ID]) }));
  assert.equal(bar.worker.badge.restart, true);
  assert.equal(bar.worker.busy, true);
  assert.equal(workerBadgeFor(ID, { ...state, workerVersion: "1.0.0", workerCompat: "ok" }, { served: "1.0.0", installed: null }), null);
  assert.equal(workerBadgeFor(ID, { ...state, owner: "tui" }, { served: "1.0.0", installed: null }), null);
  assert.equal(workerBadgeFor(null, state, { served: "1.0.0", installed: null }), null);
});

test("the session clock while a turn runs; ctx and speed from the timing's tokens", () => {
  const state = {
    ...emptySessionState(),
    timing: { ...emptySessionState().timing, activeTurn: { started_at: new Date(Date.now() - 5000).toISOString() } },
  };
  const bar = infoBarModel({ id: ID, state, sessions: [], chain: { prev: null, next: null }, cardTitle: title, badge: null,
                             restarting: false, running: true });
  assert.match(bar.clock, /^\d+(\.\d+)?s$/);
  assert.equal(typeof bar.ctx.text, "string");
  // No generation yet: the speed chip's placeholder (it shows from the start).
  assert.deepEqual(bar.speed, { text: SPEED_NONE, tip: "Decode speed of the last generation: none yet", empty: true });
});

test("a session with no turn yet: the clock is the placeholder, not 0ms; a running first turn ticks from 0", () => {
  const base = (timing, running) => infoBarModel({ id: ID, state: { ...emptySessionState(), timing: { ...emptySessionState().timing, ...timing } },
                                                  sessions: [], chain: { prev: null, next: null }, cardTitle: title, badge: null,
                                                  restarting: false, running });
  // The server's duration of a session nobody has turned in yet: 0.
  assert.equal(base({ sessionDurationMs: 0 }, false).clock, "");
  assert.equal(base({ sessionDurationMs: null }, false).clock, "");
  // Its first turn running: the clock ticks, from 0 up.
  assert.match(base({ startedAt: new Date().toISOString(), sessionDurationMs: 0 }, true).clock, /^\d+(\.\d+)?(ms|s)$/);
  assert.equal(base({ startedAt: new Date(Date.now() - 15000).toISOString() }, true).clock, "15s");
  // A duration of its own, idle: still shown.
  assert.equal(base({ sessionDurationMs: 42000 }, false).clock, "42s");
});

test("the speed chip takes the last generation's speed, no longer empty", () => {
  const state = { ...emptySessionState(), timing: { ...emptySessionState().timing, tokens: { last_decode_tps: 42.4, avg_decode_tps: 40 } } };
  const bar = infoBarModel({ id: ID, state, sessions: [], chain: { prev: null, next: null }, cardTitle: title, badge: null,
                             restarting: false, running: false });
  assert.equal(bar.speed.text, "42 tok/s");
  assert.equal(bar.speed.empty, false);
  assert.match(bar.speed.tip, /session average 40 tok\/s$/);
});

// The ctx tooltip's side requests line, from the open session's timing.
test("the ctx tooltip carries the side requests line from the timing's side block", () => {
  const side = { requests: 2, prompt_sum: 9100, completion_sum: 210, by_kind: { recap: { requests: 2 } } };
  const timing = { ...emptySessionState().timing, tokens: { prompt_sum: 500, completion_sum: 100 }, side };
  const bar = infoBarModel({ id: ID, state: { ...emptySessionState(), timing, ctxPct: 50, ctxWindow: 1000 }, sessions: [],
                             chain: { prev: null, next: null }, cardTitle: title, badge: null, restarting: false, running: false, });
  assert.ok(bar.ctx.tip.includes("\nside requests: 2 (recap) · 9.1k in / 210 out\n"), bar.ctx.tip);
});

// The ctx tooltip waits for the next request only right after a /model
// whose new window didn't resolve (session_state.js ctxUnknownAfterSwitch);
// with a window that resolved and no count yet, it says the count is what
// waits (ctx.js ctxBarTip).
test("the ctx tooltip says the window is unknown, until the next request right after such a /model", () => {
  const timing = { ...emptySessionState().timing, tokens: { prompt_sum: 500, completion_sum: 100 } };
  const model = (fields) => infoBarModel({ id: ID, state: { ...emptySessionState(), timing, ...fields }, sessions: [],
                                           chain: { prev: null, next: null }, cardTitle: title, badge: null,
                                           restarting: false, running: false });
  assert.match(model({}).ctx.tip, /^Context window unknown\n/);
  assert.match(model({ ctxUnknownAfterSwitch: true }).ctx.tip, /^Context window unknown until the next request\n/);
  assert.equal(model({ ctxUnknownAfterSwitch: true }).ctx.text, "ctx ?");
  assert.match(model({ ctxWindow: 128000, ctxWindowSource: "server" }).ctx.tip,
    /^No context count yet: the next request counts it\n/);
});

// A turn in flight: the info bar's running flag rides in the tooltip's window
// (ctxBarTip), so the title is of this turn, not the last finished one.
test("the ctx tooltip of a running turn counts this turn, not the last one", () => {
  const timing = { ...emptySessionState().timing, tokens: { prompt_sum: 500, completion_sum: 100 } };
  const bar = (running) => infoBarModel({ id: ID, state: { ...emptySessionState(), timing, ctxPct: 30, ctxWindow: 1000 },
                                         sessions: [], chain: { prev: null, next: null }, cardTitle: title, badge: null,
                                         restarting: false, running }).ctx.tip;
  assert.match(bar(true), /^Context in use \(this turn so far\)\ncontext: ~300 of 1\.0k tokens\n/);
  assert.match(bar(false), /^Context used after the last turn\n/);
});

test("the status chip says waiting while a card blocks the running turn, and only then", () => {
  const running = { ...emptySessionState(), status: "running", model: "qwen", dir: "/p" };
  assert.equal(sessionBar(args({ state: running, running: true })).bar.status, "running");
  assert.equal(sessionBar(args({ state: running, running: true, waiting: true })).bar.status, "waiting");
  // A summary that hasn't caught up with the turn's end says nothing here.
  assert.equal(sessionBar(args({ waiting: true })).bar.status, "idle");
});

// The bar's items (BAR_ITEMS): one per key, each found by its selector.
const INDEX = readFileSync(new URL("../../../lib/samagotchi/web/public/index.html", import.meta.url), "utf8");
// index.html's #infoBar: its info line, context chips, the four buttons and ⋯.
function infoBarEl() {
  const start = INDEX.indexOf('<div id="infoBar"');
  const more = INDEX.indexOf('id="infoMoreBtn"', start);
  const end = INDEX.indexOf("</div>", INDEX.indexOf("</button>", more)) + "</div>".length;
  const host = document.createElement("div");
  host.innerHTML = INDEX.slice(start, end);
  return host.firstElementChild;
}

const allButtons = () => infoButtons({ id: ID, state: { owner: "worker" }, chain: { next: null }, archived: false, continuing: false, streaming: false });
// Every chip a bar can have; the working set stands in the memories' place,
// "earlier links pruned" in ←'s, so the second bar has those.
const fullBar = {
  id: ID, status: "running", model: { text: "qwen", title: "qwen", mismatch: false },
  chain: { prev: { id: "aaaaaaaa1", date: "10-09" }, next: { id: "bbbbbbbb2", date: "" } },
  parent: { id: "pppppppp9", title: "Delegated by pppppppp" },
  kids: { text: "2 delegates", title: "2 delegates", waitingText: null },
  settings: { thinking: { level: "low", source: "session", own: "low" }, reasoningHistory: null, llmContext: null },
  toolkit: { summary: null, defaultKit: null },
  notes: { text: "notes 1", title: "deepseek" }, memories: ["a"], workingSet: null,
  participants: { text: "1 participant", count: 1, present: false, title: "Participants: x" },
  dir: "/p", ctx: { text: "ctx 8%", tip: "t" }, speed: { text: "42 tok/s", tip: "s", empty: false }, clock: "5s",
  worker: { badge: { text: "chi 0.1", title: "older", restart: true }, busy: false },
};
const altBar = { ...fullBar, chain: { prev: null, next: null, pruned: true }, workingSet: { chip: { n: 1, changed: false } } };

test("BAR_ITEMS: one item per key, each with a rank and a phone place", () => {
  const keys = BAR_ITEMS.map((item) => item.key);
  assert.equal(new Set(keys).size, keys.length);
  for (const item of BAR_ITEMS) {
    assert.ok(item.rank === "pinned" || item.rank === "menu" || Number.isInteger(item.rank), item.key);
    assert.ok(["row", "menu"].includes(item.phone), item.key);
  }
  assert.deepEqual(BAR_ITEMS.filter((item) => item.compact).map((item) => item.key), ["settings"]);
});

test("BAR_ITEMS: every item the session's bar has is exactly one element of #infoBar; the chips it hasn't, none", () => {
  for (const bar of [fullBar, altBar]) {
    const el = infoBarEl();
    renderInfoBar(el.querySelector("#infoText"), bar);
    const present = barItemKeys(bar, allButtons());
    for (const item of BAR_ITEMS) {
      const found = el.querySelectorAll(item.selector).length;
      // The four buttons are in the markup always (app.js hides the ones not shown).
      if (present.includes(item.key) || item.group === "actions") assert.equal(found, 1, item.key);
      else assert.equal(found, 0, item.key);
    }
  }
  assert.deepEqual(barItemKeys(fullBar, allButtons()).filter((k) => !barItemKeys(altBar, allButtons()).includes(k)), ["prev", "next", "memories"]);
  assert.deepEqual(barItemKeys(altBar, allButtons()).filter((k) => !barItemKeys(fullBar, allButtons()).includes(k)), ["pruned", "workingSet"]);
});

test("barItemKeys: a bare session's keys; a button not shown is absent; no session, none", () => {
  const { buttons, bar } = sessionBar(args());
  assert.deepEqual(barItemKeys(bar, buttons), ["status", "ctx", "more", "id", "continue", "speed", "time", "model", "toolkit", "dir", "archive", "delete"]);
  const tui = sessionBar(args({ state: { ...emptySessionState(), owner: "tui", status: "idle", model: "qwen", dir: "/p" } }));
  assert.ok(!barItemKeys(tui.bar, tui.buttons).includes("continue"));
  assert.deepEqual(barItemKeys(null, buttons), []);
});
