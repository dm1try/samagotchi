import test from "node:test";
import assert from "node:assert/strict";
import { familyChipHtml, familyRowsHtml } from "../../../lib/samagotchi/web/public/families_view.js";
import { families } from "../../../lib/samagotchi/web/public/sessions_list.js";

const NOW = Date.parse("2026-10-06T12:00:00Z");
const del = (id, parent, extra = {}) => ({ id, short_id: id.slice(0, 8), parent_id: parent, delegate: true, status: "idle", updated_at: "2026-10-06T11:58:00Z", ...extra });
const family = (...members) => families([{ id: "p", short_id: "p" }, ...members])[0];

test("familyChipHtml: a button with the count, live and waiting; its open state in aria-expanded", () => {
  const fam = family(del("c1", "p", { owner: "worker", status: "running" }), del("c2", "p", { pending_question: { id: "q" } }));
  const html = familyChipHtml(fam, { open: false });
  assert.match(html, /^<button type="button" class="family-chip waiting" aria-expanded="false"/);
  assert.match(html, /<span class="fc-arrow" aria-hidden="true">▸<\/span>2 delegates/);
  assert.match(html, /<span class="live-dot" aria-hidden="true"><\/span>1 live/);
  assert.match(html, /<span class="fc-waiting">1 waiting<\/span>/);
  assert.match(html, /title="2 delegates: 1 running · 1 waiting"/);
  assert.match(familyChipHtml(fam, { open: true }), /aria-expanded="true"/);
  const quiet = familyChipHtml(family(del("c1", "p")), { open: false });
  assert.match(quiet, /class="family-chip"/);
  assert.doesNotMatch(quiet, /live|fc-waiting/);
  assert.match(quiet, /1 delegate</);
  assert.equal(familyChipHtml({ head: { id: "x" }, members: [] }, { open: false }), "");
});

test("familyRowsHtml: one row per member, indented by depth, escaped, with its dot, time and badges", () => {
  const fam = family(
    del("c1", "p", { first_preview: "<b>fix</b> it", owner: "worker", status: "running" }),
    del("g1", "c1", { first_preview: "grand", pending_question: { id: "q", kind: "approval", relayed_to: "c1" } }),
  );
  const html = familyRowsHtml(fam, { now: NOW });
  assert.match(html, /^<div class="family-rows" role="list">/);
  assert.equal((html.match(/class="family-row[ "]/g) || []).length, 2);
  assert.match(html, /data-id="c1" style="--depth:1"/);
  assert.match(html, /data-id="g1" style="--depth:2"/);
  assert.match(html, /&lt;b&gt;fix&lt;\/b&gt; it/);
  assert.doesNotMatch(html, /<b>fix/);
  assert.match(html, /status dot running/);
  assert.match(html, /status dot idle waiting/);
  assert.match(html, /2 min ago/);
  assert.match(html, /<span class="owner worker"/);
  // A relayed approval in its own parent's family: the plain kind.
  assert.match(html, /class="attn attn-approval"[^>]*>approval</);
  assert.doesNotMatch(html, /in parent/);
  // No archive buttons unless asked (the strip's popover, select mode).
  assert.doesNotMatch(html, /card-arch/);
});

test("familyRowsHtml: active, match / dim (a search), archive buttons and the archived badge", () => {
  const fam = family(del("c1", "p"), del("c2", "p", { archived: true }));
  const html = familyRowsHtml(fam, { activeId: "c2", matchIds: new Set(["c1"]), archivable: true, now: NOW });
  assert.match(html, /class="family-row match" data-id="c1"/);
  assert.match(html, /class="family-row active dim archived" data-id="c2"/);
  assert.match(html, /<button type="button" class="card-arch" data-arch="c1" title="Archive: hide from the lists, keep for good" aria-label="Archive session c1"><\/button>/);
  assert.match(html, /data-arch="c2" title="Unarchive: back to the lists"/);
  assert.match(html, /<span class="archived-badge"[^>]*>archived<\/span>/);
  // No search: nothing marked.
  assert.doesNotMatch(familyRowsHtml(fam, { now: NOW }), /match|dim/);
});

// ── The strip's popover (createFamilyPop) on fake elements ────────────────

import { createFamilyPop } from "../../../lib/samagotchi/web/public/families_view.js";

function fakeEl({ rect = null, parent = null, card = null } = {}) {
  const attrs = new Map();
  const listeners = new Map();
  const el = {
    id: "", className: "", hidden: false, style: {}, children: [], parent, innerHTMLSets: 0, focused: 0,
    _html: "",
    get innerHTML() { return this._html; },
    set innerHTML(v) { this._html = v; this.innerHTMLSets += 1; },
    setAttribute: (k, v) => attrs.set(k, String(v)),
    getAttribute: (k) => attrs.get(k) ?? null,
    addEventListener: (type, fn) => listeners.set(type, fn),
    fire: (type, e) => listeners.get(type)?.(e),
    appendChild(c) { this.children.push(c); c.parent = this; },
    contains(other) { for (let at = other; at; at = at.parent) if (at === this) return true; return false; },
    getBoundingClientRect: () => rect,
    closest: (sel) => (sel === ".card" ? card : null),
    focus() { this.focused += 1; },
  };
  return el;
}

function setupPop({ vw = 1440, rows = { p: "<rows p>" } } = {}) {
  const body = fakeEl();
  const doc = { body, createElement: () => fakeEl() };
  const card = fakeEl({ rect: { left: 100, top: 20, bottom: 120, width: 360 } });
  const chips = { p: fakeEl({ rect: { left: 180, top: 90, bottom: 108, width: 120 }, card }), q: fakeEl({ rect: { left: 500, top: 90, bottom: 108, width: 120 }, card }) };
  const page = { picked: [], closes: 0, rows, chips };
  const pop = createFamilyPop({
    doc, win: { innerWidth: vw },
    rowsFor: (id) => page.rows[id] ?? null,
    anchorFor: (id) => page.chips[id] ?? null,
    onPick: (id) => page.picked.push(id),
    onClose: () => { page.closes += 1; },
  });
  return { pop, page, body, el: () => body.children[0] };
}

test("familyPop opens under the chip, as wide as its card, in body; toggle closes it", () => {
  const { pop, page, el } = setupPop();
  pop.open("p");
  assert.equal(pop.isOpen(), true);
  assert.equal(pop.openHead(), "p");
  assert.equal(el().id, "familyPop");
  assert.equal(el().hidden, false);
  assert.equal(el().innerHTML, "<rows p>");
  assert.deepEqual(el().style, { top: "114px", left: "100px", width: "360px" });
  assert.equal(page.chips.p.getAttribute("aria-expanded"), "true");
  pop.toggle("p");
  assert.equal(pop.isOpen(), false);
  assert.equal(el().hidden, true);
  assert.equal(page.chips.p.getAttribute("aria-expanded"), "false");
  assert.equal(page.closes, 1);
  // Another family's chip moves it there.
  pop.open("p");
  page.rows.q = "<rows q>";
  pop.toggle("q");
  assert.equal(pop.openHead(), "q");
  assert.equal(el().innerHTML, "<rows q>");
});

test("familyPop: Esc closes it (and stops there, the chip focused), other keys and a closed popover pass", () => {
  const { pop, page } = setupPop();
  const key = (k) => ({ key: k, stopped: 0, prevented: 0, stopImmediatePropagation() { this.stopped += 1; }, stopPropagation() { this.stopped += 1; }, preventDefault() { this.prevented += 1; } });
  const idle = key("Escape");
  assert.equal(pop.onKeydown(idle), false);
  assert.equal(idle.stopped, 0);
  pop.open("p");
  assert.equal(pop.onKeydown(key("Enter")), false);
  const esc = key("Escape");
  assert.equal(pop.onKeydown(esc), true);
  assert.ok(esc.stopped > 0);
  assert.equal(pop.isOpen(), false);
  assert.equal(page.chips.p.focused, 1);
});

test("familyPop: a pointer down outside closes it; in the popover or on its chip it stays", () => {
  const { pop, page, el } = setupPop();
  pop.open("p");
  const row = fakeEl({ parent: el() });
  pop.onPointerDown({ target: row });
  assert.equal(pop.isOpen(), true);
  pop.onPointerDown({ target: page.chips.p });
  assert.equal(pop.isOpen(), true);
  pop.onPointerDown({ target: fakeEl() });
  assert.equal(pop.isOpen(), false);
});

test("familyPop: a row's click picks that session", () => {
  const { pop, page, el } = setupPop();
  pop.open("p");
  const row = { dataset: { id: "c1" } };
  el().fire("click", { target: { closest: (sel) => (sel === ".family-row[data-id]" ? row : null) } });
  assert.deepEqual(page.picked, ["c1"]);
  el().fire("click", { target: { closest: () => null } });
  assert.deepEqual(page.picked, ["c1"]);
});

test("familyPop.refresh re-anchors to the redrawn chip, rewrites rows only when they changed, closes when the family is gone", () => {
  const { pop, page, el } = setupPop();
  pop.open("p");
  const sets = el().innerHTMLSets;
  // The strip drew again: a new chip element, the same rows.
  page.chips.p = fakeEl({ rect: { left: 40, top: 90, bottom: 130, width: 100 }, card: fakeEl({ rect: { left: 30, width: 320 } }) });
  pop.refresh();
  assert.equal(el().innerHTMLSets, sets);
  assert.deepEqual(el().style, { top: "136px", left: "30px", width: "320px" });
  assert.equal(page.chips.p.getAttribute("aria-expanded"), "true");
  page.rows.p = "<rows p, a new one>";
  pop.refresh();
  assert.equal(el().innerHTML, "<rows p, a new one>");
  // Its card left the strip: closed.
  delete page.chips.p;
  pop.refresh();
  assert.equal(pop.isOpen(), false);
  // No members any more: closed.
  page.chips.p = fakeEl({ rect: { left: 0, top: 0, bottom: 10, width: 10 }, card: fakeEl({ rect: { left: 0, width: 300 } }) });
  pop.open("p");
  page.rows.p = null;
  pop.refresh();
  assert.equal(pop.isOpen(), false);
});

test("familyPop: never narrower than 300 px nor past the window's right edge", () => {
  const narrowCard = fakeEl({ rect: { left: 1300, width: 200 } });
  const { pop, page, el } = setupPop();
  page.chips.p = fakeEl({ rect: { left: 1320, top: 0, bottom: 20, width: 60 }, card: narrowCard });
  pop.open("p");
  assert.deepEqual(el().style, { top: "26px", left: "1132px", width: "300px" });
});
