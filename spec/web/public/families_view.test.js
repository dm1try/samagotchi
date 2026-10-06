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
