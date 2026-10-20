import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  chainLinkView, infoBarModel, infoButtons, sessionBar, workerBadgeFor,
} from "../../../lib/samagotchi/web/public/info_bar_model.js";
import { emptySessionState } from "../../../lib/samagotchi/web/public/session_state.js";

const ID = "0123456789abcdef";
const title = (s) => `title of ${s.id}`;

function args(over = {}) {
  return {
    id: ID, state: { ...emptySessionState(), status: "idle", model: "qwen", dir: "/p" }, sessions: [{ id: ID }],
    versions: { served: "1.0.0", installed: null }, cardTitle: title, continuing: new Set(), restarting: new Set(),
    streaming: false, running: false, now: 10_000, ...over,
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
  assert.deepEqual(bar.chain, { prev: null, next: null });
  assert.equal(bar.parent, null);
  assert.equal(bar.kids, null);
  assert.equal(bar.worker, null);
  assert.equal(bar.clock, "");
  assert.equal(bar.copied, false);
  assert.deepEqual([buttons.continue.shown, buttons.delete.shown, buttons.archive.shown, buttons.stop.shown], [true, true, true, false]);
});

test("copied for 2 s after the copy", () => {
  const state = { ...emptySessionState(), attachCopiedAt: 9_000 };
  assert.equal(sessionBar(args({ state })).bar.copied, true);
  assert.equal(sessionBar(args({ state, now: 11_000 })).bar.copied, false);
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

test("rename (✎) for an open session but a plain terminal's", () => {
  assert.equal(sessionBar(args()).buttons.rename.shown, true);
  assert.equal(sessionBar(args({ state: { ...emptySessionState(), owner: "tui" } })).buttons.rename.shown, false);
  assert.equal(infoButtons({ id: null, state: emptySessionState(), chain: { next: null }, archived: false, continuing: false, streaming: false })
    .rename.shown, false);
});

test("stop while a worker runs it, or the page streams from one", () => {
  assert.equal(sessionBar(args({ state: { ...emptySessionState(), owner: "worker" } })).buttons.stop.shown, true);
  assert.equal(sessionBar(args({ streaming: true })).buttons.stop.shown, true);
  assert.equal(infoButtons({ id: null, state: emptySessionState(), chain: { next: null }, archived: false, continuing: false, streaming: true }).stop.shown, false);
});

test("an older worker's badge (with its Restart's busy state); none for a current one or a terminal's", () => {
  const state = { ...emptySessionState(), owner: "worker", workerVersion: "0.9.0", workerFeatures: ["restart"] };
  const { bar } = sessionBar(args({ state, restarting: new Set([ID]) }));
  assert.equal(bar.worker.badge.restart, true);
  assert.equal(bar.worker.busy, true);
  assert.equal(workerBadgeFor(ID, { ...state, workerVersion: "1.0.0" }, { served: "1.0.0", installed: null }), null);
  assert.equal(workerBadgeFor(ID, { ...state, owner: "tui" }, { served: "1.0.0", installed: null }), null);
  assert.equal(workerBadgeFor(null, state, { served: "1.0.0", installed: null }), null);
});

test("the session clock while a turn runs; ctx and speed from the timing's tokens", () => {
  const state = {
    ...emptySessionState(),
    timing: { ...emptySessionState().timing, activeTurn: { started_at: new Date(Date.now() - 5000).toISOString() } },
  };
  const bar = infoBarModel({ id: ID, state, sessions: [], chain: { prev: null, next: null }, cardTitle: title, badge: null,
                             restarting: false, running: true, now: Date.now() });
  assert.match(bar.clock, /^session /);
  assert.equal(typeof bar.ctx.text, "string");
  assert.equal(bar.speed, null);
});

// The ctx tooltip's side requests line, from the open session's timing.
test("the ctx tooltip carries the side requests line from the timing's side block", () => {
  const side = { requests: 2, prompt_sum: 9100, completion_sum: 210, by_kind: { recap: { requests: 2 } } };
  const timing = { ...emptySessionState().timing, tokens: { prompt_sum: 500, completion_sum: 100 }, side };
  const bar = infoBarModel({ id: ID, state: { ...emptySessionState(), timing, ctxPct: 50, ctxWindow: 1000 }, sessions: [],
                             chain: { prev: null, next: null }, cardTitle: title, badge: null, restarting: false, running: false,
                             now: Date.now() });
  assert.ok(bar.ctx.tip.includes("\nside requests: 2 (recap) · 9.1k in / 210 out\n"), bar.ctx.tip);
});

// The ctx tooltip waits for the next request only right after a /model
// whose new window didn't resolve (session_state.js ctxUnknownAfterSwitch).
test("the ctx tooltip says the window is unknown, until the next request right after such a /model", () => {
  const timing = { ...emptySessionState().timing, tokens: { prompt_sum: 500, completion_sum: 100 } };
  const model = (fields) => infoBarModel({ id: ID, state: { ...emptySessionState(), timing, ...fields }, sessions: [],
                                           chain: { prev: null, next: null }, cardTitle: title, badge: null,
                                           restarting: false, running: false, now: Date.now() });
  assert.match(model({}).ctx.tip, /^Context window unknown\n/);
  assert.match(model({ ctxUnknownAfterSwitch: true }).ctx.tip, /^Context window unknown until the next request\n/);
  assert.equal(model({ ctxUnknownAfterSwitch: true }).ctx.text, "ctx ?");
});
