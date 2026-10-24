import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  agoText, chipModel, chipTemplate, createParticipantsControl, inviteBody, panelTemplate, rowModel, untilText, viewURL, PRESENT_MS,
} from "../../../lib/samagotchi/web/public/participants_panel.js";
import { authorBadge, participantName, setParticipantNames } from "../../../lib/samagotchi/web/public/participant_names.js";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";

const NOW = Date.parse("2026-10-23T12:00:00Z");
const iso = (ms) => new Date(ms).toISOString();
const grant = (over = {}) => ({
  id: "p_0001abcd", name: "Alex", kind: "human", state: "active", cap: 2, spend: 0.5, turns: 3,
  expires_at: iso(NOW + 7 * 864e5), last_used_at: iso(NOW - 30_000), ...over,
});
const markupOf = (template) => {
  const frag = document.createDocumentFragment();
  render(template, frag);
  return htmlOf(frag);
};

test("participants: times read as people say them", () => {
  assert.equal(untilText(iso(NOW + 7 * 864e5 - 1000), NOW), "in 7 days");
  assert.equal(untilText(iso(NOW + 5 * 3600e3), NOW), "in 5 hours");
  assert.equal(untilText(iso(NOW + 90e3), NOW), "in 2 minutes");
  assert.equal(untilText(iso(NOW - 1), NOW), "ended");
  assert.equal(agoText(null, NOW), "never");
  assert.equal(agoText(iso(NOW - 10e3), NOW), "just now");
  assert.equal(agoText(iso(NOW - 5 * 60e3), NOW), "5 min ago");
  assert.equal(agoText(iso(NOW - 3 * 3600e3), NOW), "3 h ago");
});

test("participants: a row says here now, spend of cap, turns, expiry; a reached cap and an ended link are marked", () => {
  const row = rowModel(grant(), NOW);
  assert.equal(row.state, "here now");
  assert.ok(row.present);
  assert.equal(row.spend, "$0.50 of $2.00");
  assert.equal(row.turns, "3 turns");
  assert.equal(row.expires, "expires in 7 days");
  assert.equal(rowModel(grant({ last_used_at: iso(NOW - PRESENT_MS - 1) }), NOW).state, "seen 2 min ago");
  assert.ok(rowModel(grant({ spend: 2 }), NOW).capReached);
  const ended = rowModel(grant({ state: "revoked", revoked_by: "owner" }), NOW);
  assert.deepEqual([ended.active, ended.state, ended.expires, ended.present], [false, "revoked (owner)", "", false]);
  assert.equal(rowModel(grant({ state: "expired" }), NOW).state, "expired");
});

test("participants: the chip invites with nobody, else counts the active ones with a dot while one is here", () => {
  assert.equal(chipModel(null, NOW), null);
  assert.equal(chipModel([], NOW).text, "invite");
  assert.equal(chipModel([grant({ state: "revoked" })], NOW).text, "invite");
  const two = chipModel([grant(), grant({ id: "p_2", name: "Sam", last_used_at: null })], NOW);
  assert.deepEqual([two.text, two.count, two.present], ["2 participants", 2, true]);
  assert.match(two.title, /Alex, Sam \(here now: Alex\)/);
  assert.match(markupOf(chipTemplate(two)), /class="model participants-chip present"/);
  assert.match(markupOf(chipTemplate(chipModel([], NOW))), /participants-chip none/);
});

test("participants: Invite's body: a name, person or agent, the expiry in seconds, a cap in dollars", () => {
  assert.deepEqual(inviteBody({ name: " Alex ", kind: "human", days: "3", cap: "" }), { body: { name: "Alex", kind: "human", ttl: 259200 } });
  assert.deepEqual(inviteBody({ name: "Bot", kind: "agent", days: "99", cap: "$5" }).body, { name: "Bot", kind: "agent", ttl: 604800, cap: 5 });
  assert.match(inviteBody({ name: "  " }).error, /name/);
  assert.match(inviteBody({ name: "A", cap: "lots" }).error, /dollars/);
  assert.match(inviteBody({ name: "A", cap: "5000" }).error, /dollars/);
});

test("participants: the panel lists the active ones with Cap and Revoke, folds the ended, links the participant view", () => {
  const out = markupOf(panelTemplate([grant(), grant({ id: "p_old", name: "Kim", state: "expired" })], { now: NOW, sessionId: "s 1" }));
  assert.match(out, /data-act="revoke" data-id="p_0001abcd"/);
  assert.match(out, /<summary>Ended \(1\)<\/summary>/);
  assert.match(out, /class="pp-invite"/);
  assert.match(out, /href="\/\?as=participant#s=s%201"/);
  assert.equal(viewURL("abc"), "/?as=participant#s=abc");
  const shown = markupOf(panelTemplate([], { now: NOW, sessionId: "s", invite: { name: "Alex", link: "http://x/?token=chp_t", lan: true }, canShare: true }));
  assert.match(shown, /shown once/);
  assert.match(shown, /data-act="share"/);
  assert.doesNotMatch(shown, /class="pp-invite"/);
  const warned = markupOf(panelTemplate([], { now: NOW, sessionId: "s", invite: { name: "Alex", link: "http://x/", lan: true, warning: "3f9a1c2e is a working session" } }));
  assert.match(warned, /class="pp-warning"[^>]*>3f9a1c2e is a working session</);
  assert.doesNotMatch(shown, /pp-warning/);
});

test("participants: names and badges for the owner's bubbles", () => {
  setParticipantNames([grant()]);
  assert.equal(participantName("p:p_0001abcd"), "Alex");
  assert.equal(authorBadge("owner"), null);
  assert.equal(authorBadge(null), null);
  assert.deepEqual(Object.keys(authorBadge("p:p_0001abcd")), ["author", "name", "color"]);
  assert.equal(authorBadge("p:p_0001abcd").name, "Alex");
  assert.equal(authorBadge("p:p_0001abcd", "Alexandra").name, "Alexandra");
  assert.equal(authorBadge("p:p_unknown").name, "a participant");
  setParticipantNames([]);
});

test("participants: a participant's queued or started prompt carries their badge; the owner's ops stay as they were", async () => {
  const { promptOps } = await import("../../../lib/samagotchi/web/public/turn_events.js");
  const { userBubbleTemplate } = await import("../../../lib/samagotchi/web/public/turn_html.js");
  setParticipantNames([grant()]);
  const known = () => false;
  const [queued] = promptOps({ type: "turn_enqueued", enqueued_id: "e1", client_id: "review:p_0001abcd", prompt: "q", author: "p:p_0001abcd" }, { myId: "web:me", known });
  assert.equal(queued.author.name, "Alex");
  const [started] = promptOps({ type: "turn_started", prompt: "q", author: "p:p_0001abcd", author_name: "Alex B",
                                origin: { client_id: "review:p_0001abcd", author: "p:p_0001abcd" } }, { myId: "web:me", known });
  assert.equal(started.author.name, "Alex B");
  const [owner] = promptOps({ type: "turn_enqueued", enqueued_id: "e2", client_id: "tui:1", prompt: "mine" }, { myId: "web:me", known });
  assert.ok(!("author" in owner));
  const bubble = markupOf(userBubbleTemplate({ content: "q" }, { author: started.author, label: "review" }));
  assert.match(bubble, /class="bubble user by-participant"/);
  assert.match(bubble, /style="--author-color:var\(--author-[1-6]\)"/);
  assert.match(bubble, /<span class="origin-label author-badge"[^>]*>Alex B · review<\/span>/);
  setParticipantNames([]);
});

test("participants: a working session's warning comes before the Invite, with Start a review of it; none for a review session", () => {
  const working = markupOf(panelTemplate([], { now: NOW, sessionId: "s", working: "3f9a1c2e is a working session" }));
  assert.match(working, /class="pp-warning pp-working"[^>]*>3f9a1c2e is a working session<button[^>]*data-act="start-review"[^>]*>Start a review of it<\/button>/);
  assert.ok(working.indexOf("pp-working") < working.indexOf('class="pp-invite"'));
  assert.match(markupOf(panelTemplate([], { now: NOW, sessionId: "s", working: "w", reviewing: true })), /disabled[^>]*>Starting…</);
  assert.doesNotMatch(markupOf(panelTemplate([], { now: NOW, sessionId: "s" })), /pp-working/);
  assert.doesNotMatch(markupOf(panelTemplate([], { now: NOW, sessionId: "s", working: "w", invite: { name: "A", link: "x", lan: true } })), /pp-working/);
});

// The control on the shim's document: the chip in +el+, an api whose
// answers the test settles (deferred), a stub window.
const deferred = () => {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
};
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
function panelControl({ api: over = {}, win: winOver = {}, ...opts } = {}) {
  const el = document.createElement("div");
  el.innerHTML = '<button type="button" class="participants-chip">invite</button>';
  document.body.append(el);
  let open = "s1";
  const pending = [];
  const api = {
    list: async () => ({ participants: [grant()] }),
    invite: () => { const d = deferred(); pending.push(d); return d.promise; },
    cap: () => { const d = deferred(); pending.push(d); return d.promise; },
    revoke: () => { const d = deferred(); pending.push(d); return d.promise; },
    ...over,
  };
  const win = { innerWidth: 1000, innerHeight: 800, navigator: {}, confirm: () => true, ...winOver };
  const ctl = createParticipantsControl({ el, session: () => open, api, clock: () => NOW, win, ...opts });
  // This control's (a failed test leaves its own behind).
  const pop = [...document.querySelectorAll("#participantsPopover")].pop();
  const chip = el.querySelector(".participants-chip");
  const submit = (form) => form.dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  return {
    ctl, pop, chip, pending, submit,
    switchTo: (id) => { open = id; },
    done: () => { el.remove(); pop.remove(); },
  };
}

// An invite answered after its panel closed (or another session opened)
// is dropped: its one-time link never shows in a later panel.
test("participants panel: an invite answered after the panel closed doesn't show its link in the next panel", async () => {
  const c = panelControl();
  await c.ctl.load();
  c.chip.click();
  await tick();
  assert.ok(c.ctl.isOpen());
  c.pop.querySelector("form.pp-invite").elements.name.value = "Kim";
  c.submit(c.pop.querySelector("form.pp-invite"));
  c.ctl.close();
  c.pending[0].resolve({ participant: { name: "Kim" }, link: "http://x/?token=chp_late", lan: true });
  await tick();
  c.chip.click();
  await tick();
  assert.ok(c.ctl.isOpen());
  assert.ok(!c.pop.querySelector(".pp-invite-done"), "the late link isn't in the reopened panel");
  assert.ok(c.pop.querySelector("form.pp-invite"));
  c.done();
});

test("participants panel: a revoke's refusal after another session opened doesn't land in that session's panel", async () => {
  const c = panelControl();
  await c.ctl.load();
  c.chip.click();
  await tick();
  c.pop.querySelector('[data-act="revoke"]').click();
  c.ctl.close();
  c.switchTo("s2");
  await c.ctl.load("s2");
  c.pending[0].reject(new Error("revoke failed"));
  await tick();
  c.chip.click();
  await tick();
  assert.equal(c.pop.querySelector(".ctx-pop-error").textContent, "");
  c.done();
});

test("participants panel: a failed list for another session drops the previous session's warning and rows", async () => {
  let fail = false;
  const c = panelControl({ api: { list: async () => {
    if (fail) throw new Error("down");
    return { participants: [grant()], warning: "s1 is a working session" };
  } }, startReview: async () => null });
  await c.ctl.load();
  fail = true;
  c.switchTo("s2");
  await c.ctl.load("s2");
  // The panel s2 opens: no s1 rows, no s1 warning.
  c.chip.click();
  await tick();
  assert.ok(c.ctl.isOpen());
  assert.ok(c.pop.querySelector("form.pp-invite"));
  assert.doesNotMatch(c.pop.innerHTML, /s1 is a working session/);
  assert.doesNotMatch(c.pop.innerHTML, /pp-row/);
  c.done();
});

// Start a review of it: closed once the review is made; a refusal stays in
// the open panel, said there. "Starting…" while one is under way.
test("participants panel: Start a review closes the panel when made, and keeps it open with the refusal when not", async () => {
  const under = new Set();
  let answer = deferred();
  const c = panelControl({
    api: { list: async () => ({ participants: [], warning: "s1 is a working session" }) },
    reviewing: () => under.has("s1"),
    startReview: ({ onError }) => {
      under.add("s1");
      return answer.promise.then((made) => {
        under.delete("s1");
        if (!made && !onError("Can't start a review of s1: the folder is gone")) throw new Error("not shown");
        return made;
      });
    },
  });
  await c.ctl.load();
  c.chip.click();
  await tick();
  c.pop.querySelector('[data-act="start-review"]').click();
  assert.match(c.pop.innerHTML, /Starting…/);
  answer.resolve(null);
  await tick();
  assert.ok(c.ctl.isOpen(), "a refused review leaves the panel open");
  assert.equal(c.pop.querySelector(".ctx-pop-error").textContent, "Can't start a review of s1: the folder is gone");
  assert.match(c.pop.innerHTML, /Start a review of it</);
  answer = deferred();
  c.pop.querySelector('[data-act="start-review"]').click();
  answer.resolve({ id: "s3" });
  await tick();
  assert.ok(!c.ctl.isOpen());
  c.done();
});
