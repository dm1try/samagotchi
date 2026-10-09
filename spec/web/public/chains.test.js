import test from "node:test";
import assert from "node:assert/strict";
import { CONTINUE_OPENER, allViewChains, chainChipHtml, chainTitle, chainDate, chainLinks, chainNeighbours, chainRowsHtml, continueRefusal, foldChains, openChildrenHtml } from "../../../lib/samagotchi/web/public/chains.js";
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
  assert.match(chainChipHtml(fams[0]), />day 2 of 3</);
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
  // Archived ones included: A heads its own card with D folded in, its chip "day 1 of 2".
  const fams = search("", true);
  assert.deepEqual(fams.map((f) => [f.head.id, f.members.map((m) => m.session.id)]), [["b", []], ["a", ["d"]]]);
  assert.match(chainChipHtml(fams[1]), />day 1 of 2</);
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

test("chainChipHtml: 'day N' with the links in its tooltip, its live links, and nothing outside a chain", () => {
  const all = [d3, d2, { ...d1, owner: "worker" }];
  const [f] = foldChains(families([d3]), all);
  const html = chainChipHtml(f, { open: true });
  assert.match(html, /^<button type="button" class="chain-chip" aria-expanded="true"/);
  assert.match(html, />day 3</);
  assert.match(html, /title="Session chain: day 3 of 3 \(2 earlier links\); open the list"/);
  assert.match(html, /1 live/);
  assert.equal(chainChipHtml(families([lone])[0]), "");
});

test("chainRowsHtml lists the other links newest first: day, date, recap's first sentence, archived; the open one active", () => {
  const all = [d3, d2, { ...d1, recap: null }];
  const [f] = foldChains(families([d3]), all);
  const html = chainRowsHtml(f, { activeId: "d2", now: Date.parse(at(9, "20")) });
  const ids = [...html.matchAll(/data-id="([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual(ids, ["d2", "d1"]);
  assert.match(html, /class="family-row chain-row active archived" data-id="d2"/);
  assert.match(html, /<span class="cr-day">day 2<\/span><span class="cr-date">2026-10-0[78]<\/span><span class="fr-preview">Day two fixed the specs\.<\/span>/);
  // No recap: its preview.
  assert.match(html, /<span class="fr-preview">d1 work<\/span>/);
  assert.equal((html.match(/archived-badge/g) || []).length, 2);
  // Escaped.
  const [g] = foldChains(families([d3]), [d3, { ...d2, recap: "<b>x</b>" }]);
  assert.match(chainRowsHtml(g), /&lt;b&gt;x&lt;\/b&gt;/);
});

const refused = (code, body, message = "refused (409)") => Object.assign(new Error(message), { status: 409, code, body: { error: code, ...body } });

test("continueRefusal: continued already opens the next link", () => {
  assert.deepEqual(continueRefusal(refused("continued", { next_id: "d4" })), { kind: "open", id: "d4" });
});

test("continueRefusal: open delegates are named with their preview and state", () => {
  const kids = [
    { id: "aaaaaaaa-1", status: "running", first_preview: "fix the flaky spec" },
    { id: "bbbbbbbb-2", status: "idle", first_preview: "write docs", pending_question: { id: "q", kind: "question" } },
  ];
  const detail = "d3 has delegates still open: aaaaaaaa (running), cccccccc (unreported reply); wait for them, stop them or archive them, then continue";
  const r = continueRefusal(refused("open_children", { ids: ["aaaaaaaa-1", "bbbbbbbb-2", "cccccccc-3", "dddddddd-4"] },
    `${detail} (409)`), kids);
  assert.equal(r.kind, "children");
  assert.equal(r.text, detail);
  // Why: the server's word, else the state here; the preview when the list has it.
  assert.deepEqual(r.children, [
    { id: "aaaaaaaa-1", short: "aaaaaaaa", text: "fix the flaky spec (running)" },
    { id: "bbbbbbbb-2", short: "bbbbbbbb", text: "write docs (waiting)" },
    { id: "cccccccc-3", short: "cccccccc", text: "(unreported reply)" },
    { id: "dddddddd-4", short: "dddddddd", text: "" },
  ]);
  const html = openChildrenHtml("d3d3d3d3-x", r.children, (id) => `#/s/${id}`);
  assert.match(html, /Can't continue d3d3d3d3: 4 delegates are still open\. Wait for them, stop or archive them, then continue\./);
  assert.match(html, /<a href="#\/s\/aaaaaaaa-1" class="cr-child">aaaaaaaa<\/a> fix the flaky spec \(running\)/);
  assert.match(openChildrenHtml("d3", r.children.slice(0, 1), (id) => id), /1 delegate is still open\. Wait for it, stop or archive it/);
});

test("continueRefusal: anything else is the server's words", () => {
  assert.deepEqual(continueRefusal(refused("busy", {}, "d3 is running a turn (409)")), { kind: "error", text: "d3 is running a turn" });
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

test("the chain popover's rows without a recap read the chain's title, not the opener", () => {
  const first = link("c1", 5, { first_preview: "/coordinate the daily review", archived: true });
  const mid = link("c2", 6, { continues: "c1", first_preview: "Continue where we left off.", archived: true });
  const last = link("c3", 7, { continues: "c2", first_preview: "Continue where we left off." });
  const [f] = foldChains(families([last]), [last, mid, first]);
  const html = chainRowsHtml(f);
  assert.equal((html.match(/<span class="fr-preview">\/coordinate the daily review<\/span>/g) || []).length, 2);
  assert.doesNotMatch(html, /Continue where we left off/);
});
