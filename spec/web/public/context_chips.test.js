import test from "node:test";
import assert from "node:assert/strict";
import { addFormHtml, ageText, chipModel, chipsHtml, hintUrl, popoverHtml } from "../../../lib/samagotchi/web/public/context_chips.js";
import { escapeHtml } from "../../../lib/samagotchi/web/public/format.js";

const NOW = Date.parse("2026-10-05T12:00:00Z");
const ago = (s) => new Date(NOW - s * 1000).toISOString();
const row = (over = {}) => ({ name: "pr-1", scope: "session", kind: "cmd", every_seconds: 300, why: "the PR",
  hint: "https://github.com/x/y/pull/1", summary: "2 new comments", error: null, fetched_at: ago(180),
  has_text: true, unread: false, muted: false, ...over });

test("ageText: now, minutes, hours, days; blank for none", () => {
  assert.equal(ageText(ago(20), NOW), "now");
  assert.equal(ageText(ago(180), NOW), "3m");
  assert.equal(ageText(ago(7300), NOW), "2h");
  assert.equal(ageText(ago(3 * 86400), NOW), "3d");
  assert.equal(ageText(null, NOW), "");
});

test("hintUrl: only http(s) links", () => {
  assert.equal(hintUrl(" https://x/1 "), "https://x/1");
  assert.equal(hintUrl("javascript:alert(1)"), null);
  assert.equal(hintUrl("branch main"), null);
});

test("chipModel: name · age, the state by error, text and unread; muted ones left out", () => {
  const chips = chipModel([row({ unread: true }), row({ name: "ci", error: "exit 1" }), row({ name: "n", has_text: false, fetched_at: null }),
                           row({ name: "q", muted: true }), row({ name: "ok" })], NOW);
  assert.deepEqual(chips.map((c) => [c.label, c.state]), [["pr-1 · 3m", "unread"], ["ci · 3m", "error"], ["n", "empty"], ["ok · 3m", "ok"]]);
  assert.equal(chips[0].title, "2 new comments · changed; the agent hasn't read it yet");
  assert.equal(chips[1].title, "2 new comments · last refresh failed: exit 1");
});

test("chipsHtml: a dot only for an unread change, names escaped", () => {
  const html = chipsHtml(chipModel([row({ unread: true }), row({ name: "<x>" })], NOW), escapeHtml);
  assert.match(html, /class="ctx-chip unread" data-name="pr-1"[^>]*><span class="ctx-dot"/);
  assert.match(html, /data-name="&lt;x&gt;"/);
  assert.equal((html.match(/ctx-dot/g) || []).length, 1);
});

test("popoverHtml: why, a link for a URL hint, summary, age, error; detach or mute by scope", () => {
  const html = popoverHtml(row({ unread: true, error: "exit 1: boom" }), escapeHtml, NOW);
  assert.match(html, /<strong>pr-1<\/strong><span class="ctx-pop-kind">session · runs every 300s<\/span>/);
  assert.match(html, /<a class="ctx-pop-hint" href="https:\/\/github.com\/x\/y\/pull\/1" target="_blank" rel="noopener noreferrer">/);
  assert.match(html, /fetched 3m ago · the agent hasn't read this change/);
  assert.match(html, /last refresh failed: exit 1: boom/);
  assert.match(html, /data-act="view">view text/);
  assert.match(html, />detach<\/button>/);
  const project = popoverHtml(row({ scope: "project", kind: "push", hint: "not a url", has_text: false, fetched_at: null }), escapeHtml, NOW);
  assert.match(project, /project · pushed/);
  assert.match(project, /<div class="ctx-pop-hint">not a url<\/div>/);
  assert.match(project, />mute here<\/button>/);
  assert.doesNotMatch(project, /view text/);
});

test("chipsHtml: a + URL chip last when a bundle's provider can attach one", () => {
  const html = chipsHtml(chipModel([row()], NOW), escapeHtml, { addUrl: true });
  assert.match(html, /data-name="pr-1".*<button type="button" class="ctx-chip ctx-add" data-act="add" title="[^"]+" aria-haspopup="dialog">\+ URL<\/button>$/);
  assert.doesNotMatch(chipsHtml(chipModel([row()], NOW), escapeHtml), /ctx-add/);
  assert.equal(chipsHtml([], escapeHtml, { addUrl: true }).match(/ctx-chip/g).length, 1);
});

test("addFormHtml: a URL field, an optional why, Attach; an error line when the last try failed", () => {
  const html = addFormHtml(escapeHtml);
  assert.match(html, /<strong>Attach a URL<\/strong>/);
  assert.match(html, /<input[^>]*name="url"[^>]*type="url"[^>]*required/);
  assert.match(html, /<input[^>]*name="why"/);
  assert.match(html, /<button type="submit"[^>]*>Attach<\/button>/);
  assert.doesNotMatch(html, /ctx-pop-error/);
  const failed = addFormHtml(escapeHtml, { url: "https://x/<1>", error: "no installed bundle resolves it" });
  assert.match(failed, /value="https:\/\/x\/&lt;1&gt;"/);
  assert.match(failed, /<div class="ctx-pop-error"[^>]*>no installed bundle resolves it<\/div>/);
});
