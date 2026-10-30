import { canon, htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  CARD_FADE_MS, allCountText, allViewFamilies, cardAnimStyle, cardTemplate, enteringCards, matchesFilter, stripCountText, stripOrder, stripPillTemplate, stripTileTemplate,
} from "../../../lib/samagotchi/web/public/lists_view.js";
import { families } from "../../../lib/samagotchi/web/public/sessions_list.js";
import { previewForCard } from "../../../lib/samagotchi/web/public/format.js";
import { stripStatusParts } from "../../../lib/samagotchi/web/public/strip.js";
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

test("matchesFilter: a session's own title (/title) matches through its card's title", () => {
  const s = sess("abcdef0123", { first_preview: "hey chi", title: "Coordinator" });
  assert.ok(matchesFilter(s, "coord", previewForCard(s)));
});

test("matchesFilter: title, first preview, ids, status and the waiting words", () => {
  const s = sess("abcdef0123", { status: "running", first_preview: "First", pending_question: { id: "q", kind: "approval" } });
  for (const q of ["title", "first", "abcdef01", "0123", "running", "approval"]) assert.ok(matchesFilter(s, q, "The Title"), q);
  assert.ok(!matchesFilter(s, "nothing", "The Title"));
});

// ── Counts ───────────────────────────────────────────────────────────────

test("allCountText: the total with its delegates, or shown / total under a search", () => {
  assert.equal(allCountText(14, 14, 7), "14 · 7 delegates");
  assert.equal(allCountText(2, 2, 1), "2 · 1 delegate");
  assert.equal(allCountText(3, 3, 0), "3");
  assert.equal(allCountText(0, 0, 0), "0");
  assert.equal(allCountText(3, 14, 7), "3 / 14");
});

test("stripCountText: the strip's sessions, or how many are archived when all are", () => {
  assert.equal(stripCountText(1, 4), "1 session");
  assert.equal(stripCountText(5, 9), "5 sessions");
  assert.equal(stripCountText(0, 3), "3 archived");
  assert.equal(stripCountText(0, 0), "0 sessions");
});

// ── Which cards fade in (no blink on a redraw) ───────────────────────────

test("enteringCards: a list's first draw fades every card in", () => {
  const { drawn, entering } = enteringCards(undefined, ["a", "b"], 1000);
  assert.deepEqual([...entering], [["a", 0], ["b", 0]]);
  assert.deepEqual([...drawn], [["a", 1000], ["b", 1000]]);
});

test("enteringCards: the same cards drawn again, or reordered, don't fade", () => {
  const first = enteringCards(undefined, ["a", "b"], 1000).drawn;
  const again = enteringCards(first, ["a", "b"], 1000 + CARD_FADE_MS);
  assert.equal(again.entering.size, 0);
  const reordered = enteringCards(again.drawn, ["b", "a"], 5000);
  assert.equal(reordered.entering.size, 0);
  assert.deepEqual([...reordered.drawn], [["b", 1000], ["a", 1000]]);
});

test("enteringCards: only a new card fades; a burst of redraws carries its fade on", () => {
  const first = enteringCards(undefined, ["a"], 1000).drawn;
  const added = enteringCards(first, ["n", "a"], 5000);
  assert.deepEqual([...added.entering], [["n", 0]]);
  // Drawn again 100 ms later: still entering, 100 ms into its fade (not from 0, not done).
  const burst = enteringCards(added.drawn, ["n", "a"], 5100);
  assert.deepEqual([...burst.entering], [["n", 100]]);
  // Past the fade: settled.
  assert.equal(enteringCards(burst.drawn, ["n", "a"], 5000 + CARD_FADE_MS).entering.size, 0);
});

test("enteringCards: a card no longer drawn is forgotten, and fades in again when it comes back", () => {
  const first = enteringCards(undefined, ["a", "b"], 1000).drawn;
  const gone = enteringCards(first, ["a"], 2000);
  assert.deepEqual([...gone.drawn.keys()], ["a"]);
  assert.deepEqual([...enteringCards(gone.drawn, ["a", "b"], 3000).entering.keys()], ["b"]);
});

test("cardAnimStyle: the fade's negative delay, nothing else (no status dots to pulse)", () => {
  assert.equal(cardAnimStyle(), "");
  assert.equal(cardAnimStyle({ enterMs: 0 }), "");
  assert.equal(cardAnimStyle({ enterMs: 120.4 }), "--enter-delay:-120ms");
});

test("cardTemplate and stripTileTemplate: entering and anim", () => {
  const out = markupOf(cardTemplate(sess("0123456789"), { entering: true, anim: "--enter-delay:-5ms" }, { title: "T" }));
  assert.match(out, /^<div class="card entering" data-id="0123456789" style="--enter-delay:-5ms" title=/);
  assert.match(markupOf(stripTileTemplate("1 session", { entering: true, anim: "--enter-delay:-3ms" })),
    /<button type="button" class="card entering" id="allTile" style="--enter-delay:-3ms" title="All sessions, with search">/);
});

// ── Markup ───────────────────────────────────────────────────────────────

test("stripTileTemplate and stripPillTemplate", () => {
  assert.equal(markupOf(stripTileTemplate("3 sessions")), canon(
    `<button type="button" class="card" id="allTile" title="All sessions, with search">All sessions →<span class="count">3 sessions</span></button>`,
  ));
  const list = [sess("a", { owner: "worker" }), sess("b", { pending_question: { id: "q", kind: "question" } })];
  assert.equal(markupOf(stripPillTemplate(stripStatusParts(list))), canon(
    `<span class="pill-count">2 sessions · </span><span class="live"><span class="live-dot" aria-hidden="true"></span>1 live</span> · <span class="waiting"><span class="waiting-dot" aria-hidden="true"></span>1 waiting</span>`,
  ));
  assert.equal(markupOf(stripPillTemplate(stripStatusParts([]))), canon(`<span class="pill-count">sessions</span>`));
});

test("cardTemplate: a bare strip card: untitled, its first message the line under it, no status dot", () => {
  const s = sess("0123456789", { first_preview: "<b>hi</b>" });
  assert.equal(markupOf(cardTemplate(s, {}, { title: "<b>hi</b>" })), canon(
    `<div class="card" data-id="0123456789" title="0123456789 · updated  · idle"><div class="preview untitled">Untitled</div>` +
    `<div class="recap" title="&lt;b&gt;hi&lt;/b&gt;">&lt;b&gt;hi&lt;/b&gt;</div>` +
    `<div class="meta"><span class="ctx" title="No request in this session yet">ctx ?</span></div></div>`,
  ));
});

test("cardTemplate: renamable puts a ✎ at the end of the title line; without it (the All list) none", () => {
  const s = sess("0123456789");
  assert.equal(markupOf(cardTemplate(s, { renamable: true }, { title: "T" })), canon(
    `<div class="card" data-id="0123456789" title="0123456789 · updated  · idle"><div class="preview-row"><div class="preview">T</div>` +
    `<button type="button" class="card-rename" title="Rename this session" aria-label="Rename this session" data-rename="0123456789">\u270e</button></div>` +
    `<div class="recap" title="0123456789 work">0123456789 work</div>` +
    `<div class="meta"><span class="ctx" title="No request in this session yet">ctx ?</span></div></div>`,
  ));
  assert.doesNotMatch(markupOf(cardTemplate(s, {}, { title: "T" })), /card-rename|preview-row/);
});

// The card's ctx tooltip has the session's side requests' line (the list
// row's saved side block).
test("cardTemplate: the ctx tooltip carries the side requests line", () => {
  const side = { requests: 1, prompt_sum: 300, completion_sum: 3, cost_sum: 0.0012, cost_estimate_sum: 0, by_kind: { btw: { requests: 1 } } };
  const out = markupOf(cardTemplate(sess("0123456789", { ctx_pct: 12, tokens: { prompt_sum: 500, completion_sum: 50 }, side }), {}, { title: "T" }));
  assert.ok(out.includes("side requests: 1 (btw) · 300 in / 3 out · $0.0012"));
});

test("cardTemplate: no recap line when the title is the recap's first sentence; shown under an auto title (D5)", () => {
  const recapLine = (s) => markupOf(cardTemplate(s, {}, { title: previewForCard(s) })).includes(`class="recap" title="${s.recap}"`);
  assert.equal(recapLine(sess("a1", { recap: "Fixed the parser.", first_preview: "fix it" })), false);
  assert.equal(recapLine(sess("a2", { recap: "Fixed the parser.", auto_title: "Parser fix" })), true);
  assert.equal(recapLine(sess("a3", { recap: "Fixed the parser.", title: "Parser" })), true);
  assert.equal(recapLine(sess("a4", { first_preview: "fix it" })), false);
});

test("cardTemplate: the line under the title, always: Untitled over the first message, else the recap, else the first message", () => {
  const lines = (s, title = previewForCard(s)) => {
    const out = markupOf(cardTemplate(s, {}, { title }));
    return [out.match(/<div class="(preview[^"]*)">([^<]*)<\/div>/).slice(1).join(":"), out.match(/<div class="recap"[^>]*>([^<]*)<\/div>/)?.[1] ?? null];
  };
  // Untitled: its first message (or last prompt) only.
  assert.deepEqual(lines(sess("u1", { first_preview: "fix the parser" })), ["preview untitled:Untitled", "fix the parser"]);
  assert.deepEqual(lines(sess("u2", { first_preview: null, last_prompt: "again" })), ["preview untitled:Untitled", "again"]);
  // No message at all: "—", as today, nothing under it.
  assert.deepEqual(lines(sess("u3", { first_preview: null })), ["preview:\u2014", null]);
  // Titled without a recap: its first message under the title.
  assert.deepEqual(lines(sess("t1", { title: "Parser", first_preview: "fix the parser" })), ["preview:Parser", "fix the parser"]);
  assert.deepEqual(lines(sess("t2", { auto_title: "Parser fix", first_preview: "fix the parser" })), ["preview:Parser fix", "fix the parser"]);
  // Titled by its recap: the first message under it.
  assert.deepEqual(lines(sess("r1", { recap: "Fixed the parser.", first_preview: "fix it" })), ["preview:Fixed the parser.", "fix it"]);
  // A chain link with its chain's title keeps it, and its opener isn't the line under it.
  assert.deepEqual(lines(sess("c2", { continues: "c1", first_preview: "Continue where we left off." }), "The chain's work"), ["preview:The chain's work", null]);
});

test("cardTemplate: an all-sessions card with its tools, owner, recap, memories, folder and archived badge", () => {
  const s = sess("0123456789", {
    owner: "worker", archived: true, title: "T", recap: "did it", used_memory_names: ["a", "b"], working_directory: "/w/other",
  });
  assert.equal(markupOf(cardTemplate(s, { deletable: true, archivable: true }, { title: "T", projectName: "proj" })), canon(
    `<div class="card archived" data-id="0123456789" title="0123456789 · updated  · idle · mem: a, b">` +
    `<div class="preview">T</div><div class="recap" title="did it">did it</div>` +
    `<div class="meta"><span class="ctx" title="No request in this session yet">ctx ?</span>` +
    `<span class="folder" title="/w/other">other</span>` +
    `<span class="owner worker" title="A worker runs this session; a terminal joins with: chi --attach 0123456789">live</span>` +
    `<span class="archived-badge" title="Archived: hidden from the lists, kept for good">archived</span></div>` +
    `<div class="card-tools"><button type="button" class="card-arch" data-arch="0123456789" title="Unarchive: back to the lists" aria-label="Unarchive session 01234567"></button>` +
    `<button type="button" class="card-del" data-del="0123456789" title="Delete session" aria-label="Delete session 01234567">✕</button></div></div>`,
  ));
});

test("cardTemplate: select mode's checkbox and skip reason instead of the tools", () => {
  const s = sess("0123456789");
  const html = markupOf(cardTemplate(s, { selectable: true, picked: true, skipReason: "busy" }, { title: "T" }));
  assert.equal(html, canon(
    `<div class="card picked" data-id="0123456789" title="0123456789 · updated  · idle"><div class="preview">T</div>` +
    `<div class="recap" title="0123456789 work">0123456789 work</div>` +
    `<div class="meta"><span class="ctx" title="No request in this session yet">ctx ?</span></div>` +
    `<div class="skip-reason">skipped: busy</div><input type="checkbox" class="card-pick" aria-label="Select session 01234567" checked=""></div>`,
  ));
});

test("cardTemplate: a waiting session wears the attention badge, not its stop, no dot and no live badge", () => {
  const s = sess("w1", { owner: "worker", pending_question: { id: "q", kind: "approval" }, last_turn: { outcome: "stopped" } });
  const html = markupOf(cardTemplate(s, {}, { title: "T" }));
  assert.match(html, /^<div class="card waiting"/);
  assert.match(html, /<span class="attn attn-approval" title="Waiting for your approval">approval<\/span>/);
  assert.doesNotMatch(html, /stopped-badge|class="status|class="owner/);
  // Not waiting, the worker's "live" badge is its one mark.
  assert.match(markupOf(cardTemplate(sess("w2", { owner: "worker" }), {}, { title: "T" })), /<span class="owner worker"[^>]*>live<\/span>/);
});

test("cardTemplate: an errored session says so in a badge; the other states are unmarked", () => {
  const out = markupOf(cardTemplate(sess("e1", { status: "error" }), {}, { title: "T" }));
  assert.match(out, /<div class="meta"><span class="error-badge" title="error">error<\/span>/);
  for (const status of ["idle", "running", "completed", "stopped"]) {
    assert.doesNotMatch(markupOf(cardTemplate(sess("x", { status }), {}, { title: "T" })), /error-badge|class="status/, status);
  }
});

test("cardTemplate: a delegate's parent chip", () => {
  const s = del("c1", "parent99");
  const html = markupOf(cardTemplate(s, {}, { title: "T", parent: sess("parent99", { first_preview: "The parent" }) }));
  assert.match(html, /<span class="parent" title="[^"]*The parent[^"]*">↳ parent99<\/span>/);
});

test("cardTemplate: a family's card: its chip, members, rows when open in all sessions, the open session's row marked", () => {
  const list = [sess("p"), del("c1", "p", { status: "running", owner: "worker" }), del("c2", "p", { pending_question: { id: "q", kind: "question" } })];
  const fam = families(list)[0];
  const strip = markupOf(cardTemplate(fam.head, { family: fam, open: false }, { title: "T" }));
  assert.match(strip, /^<div class="card waiting" data-id="p" data-members="c1 c2"/);
  assert.match(strip, /<button type="button" class="family-chip waiting" aria-expanded="false"/);
  assert.match(strip, /2 delegates<span class="fc-live"> · <span class="live-dot" aria-hidden="true"><\/span>1 live<\/span> · <span class="fc-waiting">1 waiting<\/span>/);
  assert.doesNotMatch(strip, /family-rows/);
  const all = markupOf(cardTemplate(fam.head, { family: fam, open: true, rows: true, deletable: true, archivable: true }, { title: "T", activeId: "c1" }));
  assert.match(all, /^<div class="card waiting family-open"/);
  assert.match(all, /aria-expanded="true"/);
  // Open, the chip is just the count: the rows carry the marks.
  assert.match(all, /<button type="button" class="family-chip" aria-expanded="true"[^>]*><span class="fc-arrow" aria-hidden="true">▸<\/span>2 delegates<\/button>/);
  assert.match(all, /<div class="family-rows" role="list"><div class="family-row active" data-id="c1"/);
  assert.match(all, /data-arch="c1"/);
  // Select mode: the rows have no archive buttons.
  const picking = markupOf(cardTemplate(fam.head, { family: fam, open: true, rows: true, selectable: true }, { title: "T" }));
  assert.doesNotMatch(picking, /data-arch="c1"/);
});

test("cardTemplate: a chain's card carries its #N chip and its links as members", () => {
  const list = [sess("d2", { continues: "d1" }), sess("d1")];
  const [fam] = stripOrder(list, list);
  const html = markupOf(cardTemplate(fam.head, { family: fam }, { title: "T", chainOpen: true }));
  assert.match(html, /data-members="d1"/);
  assert.match(html, /<button type="button" class="chain-chip" aria-expanded="true"[^>]*><span class="cc-arrow" aria-hidden="true">↩<\/span>#2<\/button>/);
});
