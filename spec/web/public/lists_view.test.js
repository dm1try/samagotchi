import { canon, htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  allCountText, allViewFamilies, cardHtml, matchesFilter, stripCountText, stripOrder, stripPillHtml, stripTileHtml,
} from "../../../lib/samagotchi/web/public/lists_view.js";
import { families } from "../../../lib/samagotchi/web/public/sessions_list.js";
import { stripShowParts } from "../../../lib/samagotchi/web/public/strip.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";

// A builder's markup as the DOM holds it: a string parsed, a lit template
// rendered (marker comments dropped), so the same expected markup holds for
// either.
const markupOf = (out) => {
  if (typeof out === "string") return canon(out);
  const frag = document.createDocumentFragment();
  render(out, frag);
  return htmlOf(frag);
};

// No timestamps: a card's time line depends on the clock.
const sess = (id, extra = {}) => ({ id, short_id: id.slice(0, 8), status: "idle", first_preview: `${id} work`, ...extra });
const del = (id, parent, extra = {}) => sess(id, { parent_id: parent, delegate: true, ...extra });
const ids = (fams) => fams.map((f) => f.head.id);

// ── The lists' orders ────────────────────────────────────────────────────

test("stripOrder: a family is one card in its first-listed member's place; waiting ones first", () => {
  const list = [sess("a"), del("c1", "p"), sess("p"), sess("w", { pending_question: { id: "q", kind: "question" } })];
  const fams = stripOrder(list, list);
  assert.deepEqual(ids(fams), ["w", "a", "p"]);
  assert.deepEqual(fams[2].members.map((m) => m.session.id), ["c1"]);
});

test("stripOrder: a family whose delegate waits comes first", () => {
  const list = [sess("a"), sess("p"), del("c1", "p", { pending_question: { id: "q", kind: "approval" } })];
  assert.deepEqual(ids(stripOrder(list, list)), ["p", "a"]);
});

test("stripOrder: a chain folds into its latest link's card", () => {
  const list = [sess("d2", { continues: "d1" }), sess("d1"), sess("x")];
  const fams = stripOrder(list, list);
  assert.deepEqual(ids(fams), ["d2", "x"]);
  assert.deepEqual(fams[0].chain.links.map((s) => s.id), ["d1", "d2"]);
});

test("allViewFamilies: a search matching a delegate brings its parent's card, with the match marked", () => {
  const list = [sess("p", { first_preview: "parent" }), del("c1", "p", { first_preview: "needle here" }), sess("o", { first_preview: "other" })];
  const q = "needle";
  const { all, shown, delegates } = allViewFamilies(list, list, { query: q, matches: (s) => matchesFilter(s, q, s.first_preview) });
  assert.deepEqual(ids(all), ["p", "o"]);
  assert.deepEqual(ids(shown), ["p"]);
  assert.deepEqual([...shown[0].matchIds], ["c1"]);
  assert.equal(delegates, 1);
});

test("allViewFamilies: no search shows every family, waiting first; a search unfolds chains", () => {
  const list = [sess("d2", { continues: "d1" }), sess("d1"), sess("w", { pending_card: { id: "c", bundle: "b" } })];
  assert.deepEqual(ids(allViewFamilies(list, list).shown), ["w", "d2"]);
  const q = "d1";
  const searched = allViewFamilies(list, list, { query: q, matches: (s) => matchesFilter(s, q, s.first_preview) });
  assert.deepEqual(ids(searched.all).sort(), ["d1", "d2", "w"]);
  assert.deepEqual(ids(searched.shown), ["d1"]);
});

test("matchesFilter: title, first preview, ids, status and the waiting words", () => {
  const s = sess("abcdef0123", { status: "running", first_preview: "First", pending_question: { id: "q", kind: "approval" } });
  for (const q of ["title", "first", "abcdef01", "0123", "running", "approval"]) assert.ok(matchesFilter(s, q, "The Title"), q);
  assert.ok(!matchesFilter(s, "nothing", "The Title"));
});

// ── Counts ───────────────────────────────────────────────────────────────

test("allCountText: the total with its delegates, or shown / total under a search", () => {
  assert.equal(allCountText(14, 14, 7), "14 (+7 delegates)");
  assert.equal(allCountText(2, 2, 1), "2 (+1 delegate)");
  assert.equal(allCountText(3, 3, 0), "3");
  assert.equal(allCountText(3, 14, 7), "3 / 14");
});

test("stripCountText: the strip's sessions, or how many are archived when all are", () => {
  assert.equal(stripCountText(1, 4), "1 session");
  assert.equal(stripCountText(5, 9), "5 sessions");
  assert.equal(stripCountText(0, 3), "3 archived");
  assert.equal(stripCountText(0, 0), "0 sessions");
});

// ── Markup ───────────────────────────────────────────────────────────────

test("stripTileHtml and stripPillHtml", () => {
  assert.equal(markupOf(stripTileHtml("3 sessions")), canon(
    `<div class="strip-side"><button type="button" class="card" id="allTile" title="All sessions, with search">All sessions →<span class="count">3 sessions</span></button><button type="button" class="strip-toggle" id="stripHide" title="Hide the latest sessions">hide ▴</button></div>`,
  ));
  const list = [sess("a", { owner: "worker" }), sess("b", { pending_question: { id: "q", kind: "question" } })];
  assert.equal(markupOf(stripPillHtml(stripShowParts(list))), canon(
    `<span class="pill-arrow" aria-hidden="true">▾</span> 2 sessions · <span class="live"><span class="live-dot" aria-hidden="true"></span>1 live</span> · <span class="waiting"><span class="waiting-dot" aria-hidden="true"></span>1 waiting</span>`,
  ));
  assert.equal(markupOf(stripPillHtml(stripShowParts([]))), canon(`<span class="pill-arrow" aria-hidden="true">▾</span> sessions`));
});

test("cardHtml: a bare strip card", () => {
  const s = sess("0123456789", { first_preview: "<b>hi</b>" });
  assert.equal(markupOf(cardHtml(s, {}, { title: "<b>hi</b>" })), canon(
    `<div class="card" data-id="0123456789" title="0123456789 · updated  · idle"><div class="preview">&lt;b&gt;hi&lt;/b&gt;</div>` +
    `<div class="meta"><span class="status dot idle" title="idle" aria-label="idle"></span><span class="ctx" title="No request in this session yet">ctx ?</span></div></div>`,
  ));
});

test("cardHtml: an all-sessions card with its tools, owner, recap, memories, folder and archived badge", () => {
  const s = sess("0123456789", {
    owner: "worker", archived: true, recap: "did it", used_memory_names: ["a", "b"], working_directory: "/w/other",
  });
  assert.equal(markupOf(cardHtml(s, { deletable: true, archivable: true }, { title: "T", projectName: "proj" })), canon(
    `<div class="card archived" data-id="0123456789" title="0123456789 · updated  · idle · mem: a, b">` +
    `<div class="preview">T</div><div class="recap" title="did it">did it</div>` +
    `<div class="meta"><span class="status dot idle" title="idle" aria-label="idle"></span><span class="ctx" title="No request in this session yet">ctx ?</span>` +
    `<span class="folder" title="/w/other">other</span>` +
    `<span class="owner worker" title="A worker runs this session; a terminal joins with: chi --attach 0123456789">live</span>` +
    `<span class="archived-badge" title="Archived: hidden from the lists, kept for good">archived</span></div>` +
    `<div class="card-tools"><button type="button" class="card-arch" data-arch="0123456789" title="Unarchive: back to the lists" aria-label="Unarchive session 01234567"></button>` +
    `<button type="button" class="card-del" data-del="0123456789" title="Delete session" aria-label="Delete session 01234567">✕</button></div></div>`,
  ));
});

test("cardHtml: select mode's checkbox and skip reason instead of the tools", () => {
  const s = sess("0123456789");
  const html = markupOf(cardHtml(s, { selectable: true, picked: true, skipReason: "busy" }, { title: "T" }));
  assert.equal(html, canon(
    `<div class="card picked" data-id="0123456789" title="0123456789 · updated  · idle"><div class="preview">T</div>` +
    `<div class="meta"><span class="status dot idle" title="idle" aria-label="idle"></span><span class="ctx" title="No request in this session yet">ctx ?</span></div>` +
    `<div class="skip-reason">skipped: busy</div><input type="checkbox" class="card-pick" aria-label="Select session 01234567" checked=""></div>`,
  ));
});

test("cardHtml: a waiting session wears the attention badge, not its stop", () => {
  const s = sess("w1", { pending_question: { id: "q", kind: "approval" }, last_turn: { outcome: "stopped" } });
  const html = markupOf(cardHtml(s, {}, { title: "T" }));
  assert.match(html, /^<div class="card waiting"/);
  assert.match(html, /<span class="status dot idle waiting" title="Waiting for your approval"/);
  assert.match(html, /<span class="attn attn-approval" title="Waiting for your approval">approval<\/span>/);
  assert.doesNotMatch(html, /stopped-badge/);
});

test("cardHtml: a delegate's parent chip", () => {
  const s = del("c1", "parent99");
  const html = markupOf(cardHtml(s, {}, { title: "T", parent: sess("parent99", { first_preview: "The parent" }) }));
  assert.match(html, /<span class="parent" title="[^"]*The parent[^"]*">↳ parent99<\/span>/);
});

test("cardHtml: a family's card: its chip, members, rows when open in all sessions, the open session's row marked", () => {
  const list = [sess("p"), del("c1", "p", { status: "running", owner: "worker" }), del("c2", "p", { pending_question: { id: "q", kind: "question" } })];
  const fam = families(list)[0];
  const strip = markupOf(cardHtml(fam.head, { family: fam, open: false }, { title: "T" }));
  assert.match(strip, /^<div class="card waiting" data-id="p" data-members="c1 c2"/);
  assert.match(strip, /<button type="button" class="family-chip waiting" aria-expanded="false"/);
  assert.doesNotMatch(strip, /family-rows/);
  const all = markupOf(cardHtml(fam.head, { family: fam, open: true, rows: true, deletable: true, archivable: true }, { title: "T", activeId: "c1" }));
  assert.match(all, /^<div class="card waiting family-open"/);
  assert.match(all, /aria-expanded="true"/);
  assert.match(all, /<div class="family-rows" role="list"><div class="family-row active" data-id="c1"/);
  assert.match(all, /data-arch="c1"/);
  // Select mode: the rows have no archive buttons.
  const picking = markupOf(cardHtml(fam.head, { family: fam, open: true, rows: true, selectable: true }, { title: "T" }));
  assert.doesNotMatch(picking, /data-arch="c1"/);
});

test("cardHtml: a chain's card carries its day chip and its links as members", () => {
  const list = [sess("d2", { continues: "d1" }), sess("d1")];
  const [fam] = stripOrder(list, list);
  const html = markupOf(cardHtml(fam.head, { family: fam }, { title: "T", chainOpen: true }));
  assert.match(html, /data-members="d1"/);
  assert.match(html, /<button type="button" class="chain-chip" aria-expanded="true"[^>]*><span class="cc-arrow" aria-hidden="true">↩<\/span>day 2<\/button>/);
});
