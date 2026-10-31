import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { CONTINUE_OPENER, allViewChains, chainChipTemplate, chainTitle, chainClock, chainDate, chainLinks, chainStamp, chainNeighbours, chainRowsTemplate, continueRefusal, continuedText, foldChains, freshLink, openChildrenTemplate, openerText, openerFill, openTitle, restoredComposer } from "../../../lib/samagotchi/web/public/chains.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";

// A template's markup as the page gets it (lit's marker comments dropped).
const markupOf = (template) => {
  const frag = document.createDocumentFragment();
  render(template, frag);
  return htmlOf(frag);
};
const chainChipHtml = (f, opts) => markupOf(chainChipTemplate(f, opts));
const chainRowsHtml = (f, opts) => markupOf(chainRowsTemplate(f, opts));
const openChildrenHtml = (...args) => markupOf(openChildrenTemplate(...args));
import { families, familyWaits, filterFamilies, waitingFirst } from "../../../lib/samagotchi/web/public/sessions_list.js";

// A chain of three days: d1 ← d2 ← d3 (d3 continues d2, which continues d1).
const at = (day, hh = "10") => `2026-10-0${day}T${hh}:00:00.000Z`;
const link = (id, day, extra = {}) => ({
  id, status: "idle", created_at: at(day), updated_at: at(day, "18"), first_preview: `${id} work`, continues: null, ...extra,
});
const d1 = link("d1", 7, { archived: true, recap: "Day one shipped the parser." });
const d2 = link("d2", 8, { continues: "d1", archived: true, recap: "Day two fixed the specs." });
const d3 = link("d3", 9, { continues: "d2" });
const lone = link("lone", 9);

test("chainLinks walks back through continues and forward to the link that continues it, earliest first", () => {
  const list = [d3, lone, d1, d2];
  for (const id of ["d1", "d2", "d3"]) assert.deepEqual(chainLinks(list, id).map((s) => s.id), ["d1", "d2", "d3"]);
  assert.deepEqual(chainLinks(list, "lone").map((s) => s.id), ["lone"]);
  assert.deepEqual(chainLinks(list, "nope"), []);
  // A link the list doesn't hold ends the walk there.
  assert.deepEqual(chainLinks([d3, d2], "d3").map((s) => s.id), ["d2", "d3"]);
});

test("chainLinks: a hand-edited loop ends where it started; a second continue of a link doesn't fork it (the first created wins)", () => {
  const x = link("x", 1, { continues: "y" });
  const y = link("y", 2, { continues: "x" });
  assert.deepEqual(chainLinks([x, y], "x").map((s) => s.id), ["y", "x"]);
  const late = link("late", 9, { continues: "d1", created_at: at(9, "23") });
  assert.deepEqual(chainLinks([late, d3, d2, d1], "d1").map((s) => s.id), ["d1", "d2", "d3"]);
});

test("chainNeighbours: the previous link (from the open session's own continues when the list lags) and the next one", () => {
  const list = [d3, d2, d1];
  assert.deepEqual(chainNeighbours(list, "d2"), { prev: { id: "d1", session: d1 }, next: { id: "d3", session: d3 } });
  assert.deepEqual(chainNeighbours(list, "d1"), { prev: null, next: { id: "d2", session: d2 } });
  assert.deepEqual(chainNeighbours(list, "d3"), { prev: { id: "d2", session: d2 }, next: null });
  // A new link the hub hasn't brought yet: its continues comes from the page.
  assert.deepEqual(chainNeighbours(list, "d4", { continues: "d3" }), { prev: { id: "d3", session: d3 }, next: null });
  // A deleted previous link: no ← link (it would open a not-found page).
  assert.deepEqual(chainNeighbours([d3], "d3"), { prev: null, next: null });
  assert.deepEqual(chainNeighbours([], "d4", { continues: "gone" }), { prev: null, next: null });
  assert.deepEqual(chainNeighbours([lone], "lone"), { prev: null, next: null });
});

test("chainDate is the local day the link started, as the carry note writes it", () => {
  const d = new Date(2026, 9, 8, 23, 30);
  assert.equal(chainDate(d.toISOString()), "2026-10-08");
  assert.equal(chainDate(""), "");
  assert.equal(chainDate("nonsense"), "");
});

test("chainClock is the local HH:MM the link started; chainStamp adds it only when another link shares the day", () => {
  const morning = new Date(2026, 9, 17, 9, 12).toISOString();
  const afternoon = new Date(2026, 9, 17, 14, 32).toISOString();
  const before = new Date(2026, 9, 16, 22, 5).toISOString();
  assert.equal(chainClock(afternoon), "14:32");
  assert.equal(chainClock(""), "");
  assert.equal(chainClock("nonsense"), "");
  assert.equal(chainStamp(afternoon, [morning, before]), "2026-10-17 14:32");
  assert.equal(chainStamp(before, [morning, afternoon]), "2026-10-16");
  assert.equal(chainStamp(afternoon, []), "2026-10-17");
  assert.equal(chainStamp("nonsense", [morning]), "");
});

test("foldChains folds the earlier links into the latest link's card, whatever their archived state, with their delegates", () => {
  const d1Live = { ...d1, archived: false, owner: "worker" }; // typed in: back in the lists
  const kid = link("kid", 7, { parent_id: "d1", delegate: true });
  const all = [d3, lone, d2, d1Live, kid];
  const fams = foldChains(families(all.filter((s) => !s.archived)), all);
  assert.deepEqual(fams.map((f) => f.head.id), ["d3", "lone"]);
  const chain = fams.find((f) => f.head.id === "d3").chain;
  assert.deepEqual(chain.links.map((s) => s.id), ["d1", "d2", "d3"]);
  assert.equal(chain.at, 2);
  assert.equal(fams.find((f) => f.head.id === "lone").chain, undefined);
  // The all view with archived ones: still one card for the chain.
  assert.deepEqual(foldChains(families(all), all).map((f) => f.head.id), ["d3", "lone"]);
});

test("foldChains: with the latest link not listed, an earlier one heads its own card, its chip counting the later links", () => {
  const all = [{ ...d3, archived: true }, { ...d2, archived: false }, d1];
  const fams = foldChains(families(all.filter((s) => !s.archived)), all);
  assert.deepEqual(fams.map((f) => [f.head.id, f.chain.at]), [["d2", 1]]);
  assert.match(chainChipHtml(fams[0]), />#2 of 3</);
});

// A archived with its archived delegate D; B continues A.
test("the all view finds an earlier link and its delegate: a search or include archived lists every link as a card", () => {
  const a = link("a", 7, { archived: true, first_preview: "triage the parser" });
  const d = link("d", 7, { archived: true, parent_id: "a", delegate: true, first_preview: "fix the lexer" });
  const b = link("b", 8, { continues: "a" });
  const all = [b, a, d];
  const search = (q, includeArchived) => {
    const listed = includeArchived ? all : all.filter((s) => !s.archived);
    const fams = allViewChains(families(listed), all, { query: q, includeArchived });
    return q ? filterFamilies(fams, (s) => (s.first_preview || "").includes(q)) : fams;
  };
  // Archived ones included: A heads its own card with D folded in, its chip "#1 of 2".
  const fams = search("", true);
  assert.deepEqual(fams.map((f) => [f.head.id, f.members.map((m) => m.session.id)]), [["b", []], ["a", ["d"]]]);
  assert.match(chainChipHtml(fams[1]), />#1 of 2</);
  assert.deepEqual(search("lexer", true).map((f) => f.head.id), ["a"]);
  assert.deepEqual(search("parser", true).map((f) => f.head.id), ["a"]);
  // Without them, no search: one card, folded.
  assert.deepEqual(search("", false).map((f) => [f.head.id, f.chain.folded]), [["b", true]]);
  // An unarchived earlier link (typed in) is found by a search.
  const typed = [b, { ...a, archived: false }, d];
  const found = filterFamilies(allViewChains(families(typed.filter((s) => !s.archived)), typed, { query: "parser" }),
    (s) => (s.first_preview || "").includes("parser"));
  assert.deepEqual(found.map((f) => f.head.id), ["a"]);
});

test("a chain's card doesn't wait for a link that is a card of its own", () => {
  const waitingD2 = { ...d2, archived: false, pending_question: { id: "q", kind: "question", question: "Which?" } };
  const all = [d3, waitingD2, d1];
  const fams = foldChains(families(all.filter((s) => !s.archived)), all, { fold: false });
  assert.deepEqual(fams.map((f) => [f.head.id, familyWaits(f)]), [["d3", false], ["d2", true]]);
});

// A continue moved A's open delegate M to B (the server's summaries carry
// parent.json's parent): it folds under B, its new parent, never under A.
test("a delegate a continue moved folds under the new link, archived links listed or not", () => {
  const a = link("a", 7, { archived: true });
  const done = link("done", 7, { archived: true, parent_id: "a", delegate: true });
  const b = link("b", 8, { continues: "a" });
  const m = link("m", 7, { parent_id: "b", delegate: true, status: "running" });
  const all = [b, m, a, done];
  const members = (fams) => fams.map((f) => [f.head.id, f.members.map((x) => x.session.id)]);
  assert.deepEqual(members(foldChains(families(all.filter((s) => !s.archived)), all)), [["b", ["m"]]]);
  assert.deepEqual(members(allViewChains(families(all), all, { query: "", includeArchived: true })), [["b", ["m"]], ["a", ["done"]]]);
});

test("foldChains hands back the same array when no session continues another", () => {
  const fams = families([lone, d1]);
  assert.equal(foldChains(fams, [lone, { ...d1, continues: null }]), fams);
});

test("a chain's card waits (and sorts first) when an earlier link waits on the user", () => {
  const waitingD2 = { ...d2, archived: false, pending_question: { id: "q", kind: "question", question: "Which?" } };
  const all = [lone, d3, waitingD2, d1];
  const fams = foldChains(families(all.filter((s) => !s.archived)), all);
  const chainFam = fams.find((f) => f.head.id === "d3");
  assert.equal(familyWaits(chainFam), true);
  assert.deepEqual(waitingFirst(fams).map((f) => f.head.id), ["d3", "lone"]);
  assert.match(chainChipHtml(chainFam), /class="chain-chip waiting"/);
  assert.match(chainChipHtml(chainFam), /1 waiting/);
});

test("chainChipTemplate: '#N' with the links in its tooltip, its live links, and nothing outside a chain", () => {
  const all = [d3, d2, { ...d1, owner: "worker" }];
  const [f] = foldChains(families([d3]), all);
  const html = chainChipHtml(f, { open: true });
  assert.match(html, /^<button type="button" class="chain-chip" aria-expanded="true"/);
  assert.match(html, />#3</);
  assert.match(html, /title="Session chain: link 3 of 3 \(2 earlier links\); open the list"/);
  assert.match(html, /1 live/);
  assert.equal(chainChipHtml(families([lone])[0]), "");
});

test("chainRowsTemplate lists the other links newest first: #N, date, recap's first sentence, archived; the open one active", () => {
  const all = [d3, d2, { ...d1, recap: null }];
  const [f] = foldChains(families([d3]), all);
  const html = chainRowsHtml(f, { activeId: "d2", now: Date.parse(at(9, "20")) });
  const ids = [...html.matchAll(/data-id="([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(ids, ["d2", "d1"]);
  assert.match(html, /class="family-row chain-row active archived" data-id="d2"/);
  assert.match(html, /<span class="cr-n">#2<\/span><span class="cr-date">2026-10-0[78]<\/span><span class="fr-preview">Day two fixed the specs\.<\/span>/);
  // No recap: its preview.
  assert.match(html, /<span class="fr-preview">d1 work<\/span>/);
  assert.equal((html.match(/archived-badge/g) || []).length, 2);
  // No status dot (the status is in the row's tooltip); an errored link says so.
  assert.doesNotMatch(html, /class="status|dot/);
  const [e] = foldChains(families([d3]), [d3, { ...d2, status: "error" }]);
  assert.match(chainRowsHtml(e), /<span class="error-badge" title="error">error<\/span>/);
  // Escaped.
  const [g] = foldChains(families([d3]), [d3, { ...d2, recap: "<b>x</b>" }]);
  assert.match(chainRowsHtml(g), /&lt;b&gt;x&lt;\/b&gt;/);
});

test("chainRowsTemplate: a row's date carries its HH:MM only when another link of the chain (the head too) started that day", () => {
  const local = (d, h, m) => new Date(2026, 9, d, h, m).toISOString();
  const e1 = link("e1", 7, { archived: true, created_at: local(16, 10, 0) });
  const e2 = link("e2", 7, { continues: "e1", archived: true, created_at: local(17, 9, 12) });
  const e3 = link("e3", 7, { continues: "e2", created_at: local(17, 14, 32) });
  const [f] = foldChains(families([e3]), [e3, e2, e1]);
  const html = chainRowsHtml(f);
  assert.match(html, /data-id="e2"[^]*?<span class="cr-n">#2<\/span><span class="cr-date timed">2026-10-17 09:12<\/span>/);
  assert.match(html, /data-id="e1"[^]*?<span class="cr-n">#1<\/span><span class="cr-date">2026-10-16<\/span>/);
});

const refused = (code, body, message = "refused") => Object.assign(new Error(message), { status: 409, code, body: { error: code, ...body } });

test("openerFill: an empty composer gets the opener; a draft of this session, the new link or unknown origin stays", () => {
  const created = { id: "new", opener: "Daily review." };
  const base = { continuedId: "old", linkId: "new", created };
  assert.deepEqual(openerFill({ ...base, text: "  ", hasChips: false, draftFrom: "other" }), { value: "Daily review.", displaced: null });
  for (const draftFrom of ["old", "new", undefined]) {
    assert.deepEqual(openerFill({ ...base, text: "mine", hasChips: false, draftFrom }), { value: null, displaced: null });
  }
});

test("openerFill: a draft from another session or the start page gives way to the opener and is displaced; chips alone stay beside it", () => {
  const base = { continuedId: "old", linkId: "new", created: { id: "new" } };
  for (const draftFrom of ["other", ""]) {
    assert.deepEqual(openerFill({ ...base, text: "shell setup", hasChips: true, draftFrom }), { value: CONTINUE_OPENER, displaced: "shell setup" });
  }
  assert.deepEqual(openerFill({ ...base, text: "", hasChips: true, draftFrom: "other" }), { value: CONTINUE_OPENER, displaced: null });
  assert.deepEqual(openerFill({ ...base, text: "", hasChips: true, draftFrom: "old" }), { value: null, displaced: null });
});

test("restoredComposer: the draft replaces an empty or untouched opener, else goes after a blank line", () => {
  assert.equal(restoredComposer({ current: "", opener: "Go on.", draft: "d" }), "d");
  assert.equal(restoredComposer({ current: "Go on.", opener: "Go on.", draft: "d" }), "d");
  assert.equal(restoredComposer({ current: "Go on. And X\n", opener: "Go on.", draft: "d" }), "Go on. And X\n\nd");
});

test("openerText: the continue's own opener (the previous link's first message), else the constant", () => {
  assert.equal(openerText({ id: "c", opener: "You are the coordinator again." }), "You are the coordinator again.");
  for (const created of [{ id: "c", opener: null }, { id: "c", opener: "  " }, { id: "c" }, null, undefined, { opener: 3 }]) {
    assert.equal(openerText(created), CONTINUE_OPENER);
  }
});

test("continueRefusal: continued already opens the next link", () => {
  assert.deepEqual(continueRefusal(refused("continued", { next_id: "d4" })), { kind: "open", id: "d4" });
});

test("continueRefusal: open delegates are named with their preview and state", () => {
  const kids = [
    { id: "aaaaaaaa-1", status: "running", first_preview: "fix the flaky spec" },
    { id: "bbbbbbbb-2", status: "idle", first_preview: "write docs", pending_question: { id: "q", kind: "question" } },
  ];
  const detail = "d3 has delegates still open that can't move to the next link: aaaaaaaa (older chi worker 0.46.1; restart it), cccccccc (open in a chi REPL; close it there); then continue (or wait for them, stop them or archive them)";
  const r = continueRefusal(refused("open_children", { ids: ["aaaaaaaa-1", "bbbbbbbb-2", "cccccccc-3", "dddddddd-4"] },
    detail), kids);
  assert.equal(r.kind, "children");
  assert.equal(r.text, detail);
  // Why: the server's word, else the state here; the preview when the list has it.
  assert.deepEqual(r.children, [
    { id: "aaaaaaaa-1", short: "aaaaaaaa", text: "fix the flaky spec (older chi worker 0.46.1; restart it)" },
    { id: "bbbbbbbb-2", short: "bbbbbbbb", text: "write docs (waiting)" },
    { id: "cccccccc-3", short: "cccccccc", text: "(open in a chi REPL; close it there)" },
    { id: "dddddddd-4", short: "dddddddd", text: "" },
  ]);
  const html = openChildrenHtml("d3d3d3d3-x", r.children, (id) => `#/s/${id}`);
  assert.match(html, /Can't continue d3d3d3d3: 4 open delegates can't move to the next link\. Do what each says, or wait for them, then continue\./);
  assert.match(html, /<a href="#\/s\/aaaaaaaa-1" class="cr-child">aaaaaaaa<\/a> fix the flaky spec \(older chi worker 0\.46\.1; restart it\)/);
  assert.match(openChildrenHtml("d3", r.children.slice(0, 1), (id) => id), /1 open delegate can't move to the next link\. Do what it says, or wait for it/);
});

test("continuedText: the attached context that moved and stayed (none from an older chi web)", () => {
  const created = { id: "e4e4e4e4-y", moved: [], moved_context: { moved: ["pr-412", "ci"], stayed: [{ name: "notes", why: "pushed" }] } };
  assert.equal(continuedText("d3d3d3d3-x", created),
    "Continued d3d3d3d3 in e4e4e4e4; d3d3d3d3 is archived; context moved: pr-412, ci; context stayed with d3d3d3d3: notes");
  assert.equal(continuedText("d3d3d3d3-x", { id: "e4e4e4e4-y", moved_context: { moved: [], stayed: [] } }),
    "Continued d3d3d3d3 in e4e4e4e4; d3d3d3d3 is archived");
});

test("continuedText: the new link, the archive, and the delegates that moved", () => {
  assert.equal(continuedText("d3d3d3d3-x", { id: "e4e4e4e4-y", moved: [] }), "Continued d3d3d3d3 in e4e4e4e4; d3d3d3d3 is archived");
  assert.equal(continuedText("d3d3d3d3-x", { id: "e4e4e4e4-y", moved: ["a"] }),
    "Continued d3d3d3d3 in e4e4e4e4; d3d3d3d3 is archived; 1 open delegate moved");
  assert.equal(continuedText("d3d3d3d3-x", { id: "e4e4e4e4-y", moved: ["a", "b"] }, { opened: false }),
    "Continued d3d3d3d3 in e4e4e4e4; 2 open delegates moved");
  // An older server's answer has no moved.
  assert.equal(continuedText("d3", { id: "e4" }), "Continued d3 in e4; d3 is archived");
});

test("continuedText: the model fallback's warning is its own part; none or empty leaves it as it was", () => {
  const warning = "gone:x isn't available (host gone is gone); the link starts on fake";
  assert.equal(continuedText("d3", { id: "e4", model_warning: warning }), `Continued d3 in e4; d3 is archived; ${warning}`);
  assert.equal(continuedText("d3", { id: "e4", moved: ["a"], model_warning: warning }, { opened: false }),
    `Continued d3 in e4; 1 open delegate moved; ${warning}`);
  assert.equal(continuedText("d3", { id: "e4", model_warning: null }), "Continued d3 in e4; d3 is archived");
  assert.equal(continuedText("d3", { id: "e4", model_warning: "" }), "Continued d3 in e4; d3 is archived");
  assert.equal(continuedText("d3", { id: "e4", model_warning: "  " }, { opened: false }), "Continued d3 in e4");
});

test("freshLink: a chain link with no turn yet, not running, not a terminal's, not continued", () => {
  const fresh = (extra = {}, timing = {}) => ({
    continues: "d2", owner: "worker", turnStarted: false, ...extra,
    timing: { turnRecords: [], activeTurn: null, ...timing },
  });
  assert.equal(freshLink(fresh()), true);
  assert.equal(freshLink(fresh({ owner: null })), true);
  assert.equal(freshLink(fresh({ continues: null })), false);
  assert.equal(freshLink(fresh({}, { turnRecords: [{ id: "t1", status: "failed" }] })), false);
  assert.equal(freshLink(fresh({}, { activeTurn: { id: "t1" } })), false);
  assert.equal(freshLink(fresh({ turnStarted: true })), false);
  assert.equal(freshLink(fresh(), { running: true }), false);
  assert.equal(freshLink(fresh({ owner: "tui" })), false);
  assert.equal(freshLink(fresh(), { continued: true }), false);
  assert.equal(freshLink(null), false);
});

test("continueRefusal: anything else is the server's words", () => {
  assert.deepEqual(continueRefusal(refused("busy", {}, "d3 is running a turn")), { kind: "error", text: "d3 is running a turn" });
  // A continued answer without its next_id (an older server) is words too.
  assert.equal(continueRefusal(refused("continued", {})).kind, "error");
  assert.deepEqual(continueRefusal(new Error("Failed to fetch")), { kind: "error", text: "Failed to fetch" });
});

test("the opener is the same neutral line for every chain", () => {
  assert.equal(CONTINUE_OPENER, "Continue where we left off.");
});

// The page folds on every hub event: one pass over the list, not one per
// family (a user has ~600 sessions; this was ~0.9 s at 4000).
test("foldChains over 4000 sessions in chains of ten stays well under a frame budget's worth of work", () => {
  const list = [];
  for (let i = 0; i < 4000; i++) {
    const t = new Date(Date.UTC(2026, 0, 1, 0, i)).toISOString();
    list.push({ id: `s${i}`, created_at: t, updated_at: t, continues: i % 10 ? `s${i - 1}` : null, archived: i % 10 !== 9 });
  }
  const fams = families(list);
  const start = performance.now();
  const folded = foldChains(fams, list);
  const ms = performance.now() - start;
  assert.equal(folded.length, 400);
  assert.ok(ms < 250, `foldChains took ${Math.round(ms)} ms`);
});

// The user's choice (b): a link titled with the opener shows its chain's
// first link's title, display only.
test("openTitle: a chain link's top bar reads its card's title whatever its first message; else the first message, the opener its card's", () => {
  const cardTitle = (s) => `card of ${s.id}`;
  const link = { id: "b", continues: "a" };
  assert.equal(openTitle({ shown: link, first: "Chain opener: check the queue", cardTitle }), "card of b");
  assert.equal(openTitle({ shown: link, first: "", cardTitle }), "card of b");
  assert.equal(openTitle({ shown: { id: "c" }, first: "fix X", cardTitle }), "fix X");
  assert.equal(openTitle({ shown: { id: "c" }, first: CONTINUE_OPENER, cardTitle }), "card of c");
  // Not listed (yet): its first message.
  assert.equal(openTitle({ shown: null, first: CONTINUE_OPENER, cardTitle }), CONTINUE_OPENER);
});

test("chainTitle: a link titled with the opener reads its chain's first link's title; anything else keeps its own", () => {
  const first = link("c1", 5, { first_preview: "/coordinate the daily review" });
  const mid = link("c2", 6, { continues: "c1", first_preview: "  Continue where we left off. " });
  const last = link("c3", 7, { continues: "c2", first_preview: null, last_prompt: "Continue where we left off." });
  const own = link("c4", 8, { continues: "c3", first_preview: "Continue where we left off. Then fix the lexer" });
  const byId = new Map([first, mid, last, own].map((s) => [s.id, s]));
  assert.equal(chainTitle(mid, byId), "/coordinate the daily review");
  assert.equal(chainTitle(last, byId), "/coordinate the daily review");
  // Only the whole message: one that starts with those words is a title of its own.
  assert.equal(chainTitle(own, byId), "Continue where we left off. Then fix the lexer");
  // The first link isn't listed (deleted, or a gap): its own.
  assert.equal(chainTitle(last, new Map([[last.id, last], [mid.id, mid]])), "Continue where we left off.");
  // In no chain, or the first link titled with the opener too: its own.
  assert.equal(chainTitle(link("solo", 5, { first_preview: "Continue where we left off." }), byId), "Continue where we left off.");
  const openerFirst = link("o1", 5, { first_preview: "Continue where we left off." });
  const openerNext = link("o2", 6, { continues: "o1", first_preview: "Continue where we left off." });
  assert.equal(chainTitle(openerNext, new Map([[openerFirst.id, openerFirst], [openerNext.id, openerNext]])), "Continue where we left off.");
  // A loop a hand-edited file makes: its own.
  const x = link("x", 1, { continues: "y", first_preview: "Continue where we left off." });
  const y = link("y", 2, { continues: "x", first_preview: "Continue where we left off." });
  assert.equal(chainTitle(x, new Map([[x.id, x], [y.id, y]])), "Continue where we left off.");
});

test("chainTitle and openTitle: a link's own auto title or recap beats the chain walk; a recapped first link names its chain", () => {
  const first = link("r1", 5, { first_preview: "/coordinate the daily review", recap: "Ran the daily review." });
  const bare = link("r2", 6, { continues: "r1", first_preview: "Continue where we left off." });
  const recapped = link("r3", 7, { continues: "r2", first_preview: "Continue where we left off.", recap: "Merged two branches." });
  const auto = link("r4", 8, { continues: "r3", first_preview: "Continue where we left off.", auto_title: "Merge day" });
  const byId = new Map([first, bare, recapped, auto].map((s) => [s.id, s]));
  assert.equal(chainTitle(bare, byId), "Ran the daily review.");
  assert.equal(chainTitle(recapped, byId), "Merged two branches.");
  assert.equal(chainTitle(auto, byId), "Merge day");
  // An opener head with only a recap names its chain too.
  const head = link("o1", 5, { first_preview: "Continue where we left off.", recap: "Started the queue." });
  const next = link("o2", 6, { continues: "o1", first_preview: "Continue where we left off." });
  assert.equal(chainTitle(next, new Map([[head.id, head], [next.id, next]])), "Started the queue.");
  // The top bar follows the card for a recapped or auto-titled session in no chain.
  const cardTitle = (s) => `card of ${s.id}`;
  assert.equal(openTitle({ shown: { id: "c", recap: "Fixed X." }, first: "fix X", cardTitle }), "card of c");
  assert.equal(openTitle({ shown: { id: "c", auto_title: "X fix" }, first: "fix X", cardTitle }), "card of c");
});

test("chainTitle and openTitle: a link's own title (/title) first, and a titled first link names its opener links", () => {
  const first = link("t1", 5, { first_preview: "hey chi", title: "Coordinator" });
  const next = link("t2", 6, { continues: "t1", first_preview: "Continue where we left off." });
  const renamed = link("t3", 7, { continues: "t2", first_preview: "Continue where we left off.", title: "Release day" });
  const byId = new Map([first, next, renamed].map((s) => [s.id, s]));
  assert.equal(chainTitle(first, byId), "Coordinator");
  assert.equal(chainTitle(next, byId), "Coordinator");
  assert.equal(chainTitle(renamed, byId), "Release day");
  // An opener-titled first link with a title of its own names its chain too.
  const openerFirst = link("u1", 5, { first_preview: "Continue where we left off.", title: "Named" });
  const openerNext = link("u2", 6, { continues: "u1", first_preview: "Continue where we left off." });
  assert.equal(chainTitle(openerNext, new Map([[openerFirst.id, openerFirst], [openerNext.id, openerNext]])), "Named");
  // The top bar of a titled session that is no link follows its card.
  const cardTitle = (s) => `card of ${s.id}`;
  assert.equal(openTitle({ shown: { id: "s", title: "Named" }, first: "hey chi", cardTitle }), "card of s");
});

test("chainRowsTemplate: a chain sharing one title shows each link's recap; a link renamed apart shows its own name", () => {
  const shared = { title: "Coordinator" };
  const r1 = link("r1", 5, { ...shared, recap: "Day one planned.", archived: true });
  const r2 = link("r2", 6, { ...shared, continues: "r1", recap: "Day two merged.", archived: true });
  const r3 = link("r3", 7, { ...shared, continues: "r2" });
  const [f] = foldChains(families([r3]), [r3, r2, r1]);
  const html = chainRowsHtml(f);
  assert.match(html, /data-id="r2"[^]*?<span class="fr-preview">Day two merged\.<\/span>/);
  assert.match(html, /data-id="r1"[^]*?<span class="fr-preview">Day one planned\.<\/span>/);
  assert.doesNotMatch(html, /fr-preview">Coordinator</);
  // A renamed middle link: its own name over its recap; no recap, no title: its preview.
  const [g] = foldChains(families([r3]), [r3, { ...r2, title: "Release day" }, { ...r1, title: null, recap: null, first_preview: "plan it" }]);
  const renamed = chainRowsHtml(g);
  assert.match(renamed, /data-id="r2"[^]*?<span class="fr-preview">Release day<\/span>/);
  assert.match(renamed, /data-id="r1"[^]*?<span class="fr-preview">plan it<\/span>/);
});

test("the chain popover's rows without a recap read the chain's title, not the opener", () => {
  const first = link("c1", 5, { first_preview: "/coordinate the daily review", archived: true });
  const mid = link("c2", 6, { continues: "c1", first_preview: "Continue where we left off.", archived: true });
  const last = link("c3", 7, { continues: "c2", first_preview: "Continue where we left off." });
  const [f] = foldChains(families([last]), [last, mid, first]);
  const html = chainRowsHtml(f);
  assert.equal((html.match(/<span class="fr-preview">\/coordinate the daily review<\/span>/g) || []).length, 2);
  assert.doesNotMatch(html, /Continue where we left off/);
});

test("a link inserted before the focused row of an open chain popover: the focus stays on the same link's row", async () => {
  const { createFamilyPop } = await import("../../../lib/samagotchi/web/public/families_view.js");
  const d4 = link("d4", 10, { continues: "d3" });
  let f = { head: d4, members: [], chain: { links: [d1, d2, d4], at: 2 } };
  const body = document.createElement("div");
  document.body.append(body);
  const chip = { setAttribute() {}, getBoundingClientRect: () => ({ left: 0, top: 0, bottom: 10, width: 10 }), closest: () => null };
  const pop = createFamilyPop({ id: "chainPopSpec", doc: { body, createElement: (t) => document.createElement(t),
                                addEventListener: (...a) => document.addEventListener(...a), get activeElement() { return document.activeElement; } }, win: { innerWidth: 1000 },
                                rowsFor: () => chainRowsTemplate(f), anchorFor: () => chip, onPick() {} });
  pop.open("d4");
  body.querySelector('.chain-row[data-id="d2"] .fr-open').focus();
  f = { ...f, chain: { links: [d1, d2, d3, d4], at: 3 } };
  pop.refresh();
  assert.deepEqual([...body.querySelectorAll(".chain-row")].map((r) => r.dataset.id), ["d3", "d2", "d1"]);
  assert.equal(document.activeElement?.closest(".chain-row")?.dataset.id, "d2");
  body.remove();
});
