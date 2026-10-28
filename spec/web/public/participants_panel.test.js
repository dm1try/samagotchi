import { htmlOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import {
  agoText, capValue, chipModel, chipTemplate, createParticipantsControl, inviteBody, lateInviteText, panelTemplate, revokeConfirmText, rowModel, untilText, viewURL, PRESENT_MS,
} from "../../../lib/samagotchi/web/public/participants_panel.js";
import { authorBadge, nameUnnamedBadges, participantName, setParticipantNames, UNNAMED } from "../../../lib/samagotchi/web/public/participant_names.js";
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

test("participants: Invite's email binds the link (lower case), names them by its local part, refuses a non-address", () => {
  assert.deepEqual(inviteBody({ name: "", kind: "human", days: "7", identity: " Alex.Doe@Corp.Example " }).body,
    { name: "alex.doe", kind: "human", ttl: 604800, identity: "alex.doe@corp.example" });
  assert.equal(inviteBody({ name: "Alex", identity: "alex@github" }).body.name, "Alex");
  assert.ok(!("identity" in inviteBody({ name: "Alex", identity: "  " }).body));
  for (const bad of ["alex", "a@b@c", "a b@c", "a,b@c", "<a@b>"]) {
    assert.match(inviteBody({ name: "A", identity: bad }).error, /one address/, bad);
  }
});

test("participants: the email field only behind a proxy that names the user; a bound row and link say so", () => {
  const plain = markupOf(panelTemplate([], { now: NOW, sessionId: "s" }));
  assert.doesNotMatch(plain, /name="identity"/);
  const proxied = markupOf(panelTemplate([], { now: NOW, sessionId: "s", identityHeader: "X-Forwarded-Email" }));
  assert.match(proxied, /name="identity"[^>]*type="email"/);
  assert.match(proxied, /anyone the proxy lets in who gets the link can open it/);
  const bound = markupOf(panelTemplate([grant({ identity: "alex@corp.example" })], { now: NOW, sessionId: "s" }));
  assert.match(bound, /bound to alex@corp\.example/);
  assert.doesNotMatch(markupOf(panelTemplate([grant()], { now: NOW, sessionId: "s" })), /bound to/);
  const shown = markupOf(panelTemplate([], { now: NOW, sessionId: "s",
    invite: { name: "Alex", link: "https://x/#code=chc_c", lan: true, identity: "alex@corp.example" } }));
  assert.match(shown, /It opens this session only, for alex@corp\.example only\./);
});

test("participants panel: the list's identity_header shows the email field, and the invite sends it", async () => {
  const sent = [];
  const c = panelControl({ api: { list: async () => ({ participants: [], identity_header: "X-Forwarded-Email" }),
                                  invite: async (_id, body) => { sent.push(body); return { participant: { name: body.name, identity: body.identity }, link: "https://x/#code=chc_c", lan: true }; } } });
  await c.ctl.load();
  c.chip.click();
  await tick();
  const form = c.pop.querySelector("form.pp-invite");
  assert.ok(form.elements.identity, "the email field");
  form.elements.identity.value = "Kim@Corp.Example";
  c.submit(form);
  await tick();
  await tick();
  assert.deepEqual(sent.map(({ name, kind, identity }) => ({ name, kind, identity })),
    [{ name: "kim", kind: "human", identity: "kim@corp.example" }]);
  assert.match(c.pop.querySelector(".pp-invite-done").textContent, /for kim@corp\.example only/);
  c.done();
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
  assert.equal(authorBadge("not-a-participant"), null);
  assert.deepEqual(Object.keys(authorBadge("p:p_0001abcd")), ["author", "name", "color"]);
  assert.equal(authorBadge("p:p_0001abcd").name, "Alex");
  assert.equal(authorBadge("p:p_0001abcd", "Alexandra").name, "Alexandra");
  assert.equal(authorBadge("p:p_unknown").name, "a participant");
  assert.equal(authorBadge("p:p_unknown").unnamed, true);
  assert.equal(setParticipantNames([grant()]), false, "the same names: nothing to redraw");
  assert.equal(setParticipantNames([grant(), grant({ id: "p_2", name: "Kim" })]), true);
  setParticipantNames([]);
});

// A prompt drawn before the panel's list came (neither its own author_name
// nor a known name) says "a participant"; the list's names name it then.
test("participants: a badge drawn before the names came is named when they come", async () => {
  const { userBubbleTemplate, elementOf } = await import("../../../lib/samagotchi/web/public/turn_html.js");
  setParticipantNames([]);
  const root = document.createElement("div");
  root.append(elementOf(userBubbleTemplate({ content: "q" }, { author: authorBadge("p:p_0001abcd") })),
              elementOf(userBubbleTemplate({ content: "r" }, { author: authorBadge("p:p_0001abcd", "Alex B") })));
  const [early, own] = root.querySelectorAll(".author-badge");
  assert.equal(early.textContent, `${UNNAMED} · review`);
  assert.equal(early.dataset.unnamed, "1");
  assert.equal(own.dataset.unnamed, undefined);
  assert.equal(nameUnnamedBadges(root), 0, "no names yet: left as it is");
  setParticipantNames([grant()]);
  assert.equal(nameUnnamedBadges(root), 1);
  assert.equal(early.textContent, "Alex · review");
  assert.match(early.title, /^A review comment from Alex, /);
  assert.equal(early.dataset.unnamed, undefined);
  assert.equal(own.textContent, "Alex B · review");
  setParticipantNames([]);
});

test("participants panel: a list with new names asks for the badges to be named; the same list doesn't", async () => {
  let named = 0;
  setParticipantNames([]);
  const c = panelControl({ onNames: () => { named += 1; } });
  await c.ctl.load();
  assert.equal(named, 1);
  await c.ctl.load();
  assert.equal(named, 1);
  await c.ctl.load(null);
  assert.equal(participantName("p:p_0001abcd"), null, "no session, no names");
  c.done();
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

test("participants: a badge drawn while its turn was queued takes the pair mode at turn_started", async () => {
  const { userBubbleTemplate, elementOf } = await import("../../../lib/samagotchi/web/public/turn_html.js");
  const { setBadgeMode } = await import("../../../lib/samagotchi/web/public/participant_names.js");
  setParticipantNames([grant()]);
  const bubble = elementOf(userBubbleTemplate({ content: "q" }, { author: authorBadge("p:p_0001abcd") }));
  const badge = bubble.querySelector(".author-badge");
  assert.equal(badge.textContent, "Alex · review", "a queued prompt's mode isn't known yet: the review words");
  setBadgeMode(bubble, "pair");
  assert.equal(badge.textContent, "Alex · pair");
  assert.match(badge.title, /^A turn from Alex, a participant: it acted with this session's tools/);
  assert.equal(bubble.dataset.participantMode, "pair");
  setBadgeMode(bubble, "review");
  assert.equal(badge.textContent, "Alex · review");
  setParticipantNames([]);
});

test("participants: the empty list says what a participant's turn does, by the session's mode", () => {
  const review = markupOf(panelTemplate([], { now: NOW, sessionId: "s" }));
  assert.match(review, /their comments become read-only review turns/);
  const pair = markupOf(panelTemplate([], { now: NOW, sessionId: "s", pair: true }));
  assert.match(pair, /their turns act with this session's tools under your guardrails, and their asks come to you/);
  assert.doesNotMatch(pair, /read-only/);
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
// never shows its one-time link in a later panel: a sticky toast keeps it.
test("participants panel: an invite answered after the panel closed doesn't show its link in the next panel", async () => {
  const toasts = [];
  const copied = [];
  const c = panelControl({
    toast: (text, action = null, options = {}) => toasts.push({ text, action, options }),
    win: { navigator: { clipboard: { writeText: async (text) => { copied.push(text); } } } },
  });
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
  assert.equal(toasts.length, 1);
  assert.equal(toasts[0].text, lateInviteText("Kim", "s1"));
  assert.doesNotMatch(toasts[0].text, /chp_late/, "the toast's words don't show the link");
  assert.deepEqual([toasts[0].action.label, toasts[0].options.sticky], ["Copy link", true]);
  await toasts[0].action.run();
  assert.deepEqual(copied, ["http://x/?token=chp_late"]);
  c.done();
});

test("participants panel: a late invite's Copy link that fails shows the link itself to select", async () => {
  const toasts = [];
  const c = panelControl({
    toast: (text, action = null, options = {}) => toasts.push({ text, action, options }),
    win: { navigator: { clipboard: { writeText: async () => { throw new Error("denied"); } } } },
  });
  await c.ctl.load();
  c.chip.click();
  await tick();
  c.pop.querySelector("form.pp-invite").elements.name.value = "Kim";
  c.submit(c.pop.querySelector("form.pp-invite"));
  c.ctl.close();
  c.pending[0].resolve({ participant: { name: "Kim" }, link: "http://x/?token=chp_late", lan: true });
  await tick();
  await toasts[0].action.run();
  assert.deepEqual(toasts.slice(1).map((t) => [t.text, t.options.sticky]), [["Kim's review link: http://x/?token=chp_late", true]]);
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

// The empty list's words follow the server's mode, never the warning: an
// older worker's warning still means review turns.
test("participants panel: the empty list says pair only when the server's mode is pair", async () => {
  const words = async (body) => {
    const c = panelControl({ api: { list: async () => body } });
    await c.ctl.load();
    c.chip.click();
    await tick();
    const text = c.pop.querySelector(".ctx-pop-meta").textContent;
    c.done();
    return text;
  };
  assert.match(await words({ participants: [], warning: "s1 is a working session", mode: "pair" }), /their turns act/);
  assert.match(await words({ participants: [], warning: "s1 is a working session, but its worker predates pair turns",
    mode: "review" }), /read-only review turns/);
  assert.match(await words({ participants: [], warning: null, mode: "review" }), /read-only review turns/);
});

// Revoke can't be undone: it asks first, as a delete does.
test("participants panel: Revoke asks first, naming them; a No sends nothing", async () => {
  const asked = [];
  let yes = false;
  const revoked = [];
  const c = panelControl({
    api: { revoke: async (id, pid) => { revoked.push([id, pid]); } },
    win: { confirm: (text) => { asked.push(text); return yes; } },
  });
  await c.ctl.load();
  c.chip.click();
  await tick();
  c.pop.querySelector('[data-act="revoke"]').click();
  await tick();
  assert.deepEqual(asked, [revokeConfirmText("Alex")]);
  assert.match(asked[0], /^Revoke Alex's link\? .*can't be undone/);
  assert.deepEqual(revoked, []);
  yes = true;
  c.pop.querySelector('[data-act="revoke"]').click();
  await tick();
  assert.deepEqual(revoked, [["s1", "p_0001abcd"]]);
  c.done();
});

// The owner's controls name themselves: the dialog, each row's Cap and
// Revoke (several rows: which participant), and Cap's field takes the focus.
test("participants panel: the dialog and each row's Cap and Revoke are named; Cap's field takes the focus", async () => {
  const c = panelControl({ api: { list: async () => ({ participants: [grant(), grant({ id: "p_2", name: "Kim" })] }) } });
  await c.ctl.load();
  c.chip.click();
  await tick();
  assert.equal(c.pop.getAttribute("role"), "dialog");
  assert.equal(c.pop.getAttribute("aria-label"), "Participants");
  const labels = [...c.pop.querySelectorAll(".pp-actions button")].map((b) => b.getAttribute("aria-label"));
  assert.deepEqual(labels, ["Cap Alex's spending", "Revoke Alex's link", "Cap Kim's spending", "Revoke Kim's link"]);
  c.pop.querySelectorAll('[data-act="cap"]')[1].click();
  const field = c.pop.querySelector(".pp-cap-form input");
  assert.equal(field.getAttribute("aria-label"), "New cap for Kim, dollars");
  assert.equal(document.activeElement, field);
  c.done();
});

// One rule for both cap fields: the Invite's (empty = the default cap) and a
// row's Cap form (empty = nothing to set, never a $0 cap).
test("participants: capValue reads dollars 0 to 1000, empty as none, else one refusal", () => {
  assert.deepEqual(capValue(" $2.5 "), { value: 2.5 });
  assert.deepEqual(capValue("0"), { value: 0 });
  assert.deepEqual(capValue(""), { value: null });
  for (const bad of ["-1", "1001", "lots"]) assert.deepEqual(capValue(bad), { error: "A cap is dollars, 0 to 1000." });
});

test("participants panel: a cleared, negative or too-high cap is refused in the panel and sends nothing", async () => {
  const sent = [];
  const c = panelControl({ api: { cap: async (...args) => { sent.push(args); return {}; } } });
  await c.ctl.load();
  c.chip.click();
  await tick();
  c.pop.querySelector('[data-act="cap"]').click();
  for (const text of ["", "  ", "-3", "5000"]) {
    const form = c.pop.querySelector(".pp-cap-form");
    form.elements.cap.value = text;
    c.submit(form);
    await tick();
    assert.match(c.pop.textContent, /A cap is dollars, 0 to 1000\./);
  }
  assert.deepEqual(sent, []);
  const form = c.pop.querySelector(".pp-cap-form");
  form.elements.cap.value = "$3";
  c.submit(form);
  await tick();
  assert.deepEqual(sent, [["s1", "p_0001abcd", 3]]);
  c.done();
});

test("participants panel: a claim link's target is the list's link base and the active participants' names", async () => {
  const c = panelControl({ api: { list: async () => ({ participants: [grant(), grant({ id: "p_old", name: "Kim", state: "expired" })],
                                                       link_base: "http://192.168.1.5:4567/" }) } });
  assert.equal(c.ctl.claimTarget(), null, "nothing read yet");
  await c.ctl.load();
  assert.deepEqual(c.ctl.claimTarget(), { base: "http://192.168.1.5:4567/", names: [grant().name] });
  c.switchTo("s2");
  assert.equal(c.ctl.claimTarget(), null, "another session's list");
  c.done();
});

test("participants panel: no claim target with only agents active (no browser to open it)", async () => {
  const c = panelControl({ api: { list: async () => ({ participants: [grant({ kind: "agent", name: "Bot" })], link_base: "http://x/" }) } });
  await c.ctl.load();
  assert.equal(c.ctl.claimTarget(), null);
  c.done();
});

test("participants panel: no claim target without a link base (an older chi web) or anyone active", async () => {
  const older = panelControl();
  await older.ctl.load();
  assert.equal(older.ctl.claimTarget(), null);
  older.done();
  const ended = panelControl({ api: { list: async () => ({ participants: [grant({ state: "revoked" })], link_base: "http://x/" }) } });
  await ended.ctl.load();
  assert.equal(ended.ctl.claimTarget(), null);
  ended.done();
});
