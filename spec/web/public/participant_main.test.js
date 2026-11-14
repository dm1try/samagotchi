// The participant main page's pieces (scenes 1-5 of the mock-up as unit
// variants; the e2e lan.spec.js runs the flow whole): who they are
// (viewer_self.js) and what that changes in the shared drawing, the bottom
// row and the closed line (participant_bar.js), the delivery line and the
// composer's placeholder for their turn or someone else's, the stage's
// waiting look (stage_owner_wait.js), and participant_main.js's reading of
// the stream, refusals and an ended link.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import { isViewerAuthor, isViewerClient, ownerLabel, setViewerSelf, viewerSelf } from "../../../lib/samagotchi/web/public/viewer_self.js";
import { isOwn, promptOps } from "../../../lib/samagotchi/web/public/turn_events.js";
import { userBubbleTemplate } from "../../../lib/samagotchi/web/public/turn_html.js";
import { authorBadgeText } from "../../../lib/samagotchi/web/public/participant_names.js";
import { barItems, barTemplate, closedLine, spentText, whoTemplate } from "../../../lib/samagotchi/web/public/participant_bar.js";
import { AFTER_OWNER, OWN_TURN_QUEUES, OWN_TURN_STEERS, deliveryLine } from "../../../lib/samagotchi/web/public/delivery_line.js";
import { composerMode } from "../../../lib/samagotchi/web/public/composer_mode.js";
import { createOwnerWait, OWNER_WAIT_STATUS, OWNER_WAIT_TEXT } from "../../../lib/samagotchi/web/public/stage_owner_wait.js";
import { createParticipantMain, LINK_ENDED } from "../../../lib/samagotchi/web/public/participant_main.js";

// npm test runs every file in one process: who the viewer is (module
// state) is put back after each test, so no other file sees a participant.
const ptest = (name, fn) => test(name, async (t) => {
  try {
    await fn(t);
  } finally {
    setViewerSelf(null);
  }
});

const ALEX = { kind: "participant", id: "p_0123abcd", name: "Alex", client_id: "review:p_0123abcd", mode: "pair",
  can: ["send", "stop_own_turn", "steer_own_turn", "working_set"], usage: { spent: 0.42, cap: 2, expires_at: "2026-11-20T12:00:00Z" } };

function html(template) {
  const el = document.createElement("div");
  render(template, el);
  return el;
}

ptest("viewer_self: a participant's show names them; the owner's (or none) clears it", () => {
  setViewerSelf(ALEX);
  assert.equal(viewerSelf().author, "p:p_0123abcd");
  assert.equal(isViewerClient("review:p_0123abcd"), true);
  assert.equal(isViewerClient("review:p_other"), false);
  assert.equal(isViewerAuthor("p:p_0123abcd"), true);
  assert.equal(ownerLabel(), "owner");
  setViewerSelf({ kind: "owner", can: [] });
  assert.equal(viewerSelf(), null);
  assert.equal(ownerLabel(), null);
  assert.equal(isViewerClient("review:p_0123abcd"), false);
});

ptest("their own turns: any tab's send is theirs by the client id; a turn_started they own starts their queued bubble", () => {
  setViewerSelf(ALEX);
  assert.equal(isOwn("review:p_0123abcd", "web:this-tab"), true);
  assert.equal(isOwn("web:other", "web:this-tab"), false);
  const queued = promptOps({ type: "turn_enqueued", enqueued_id: "e1", client_id: "review:p_0123abcd", prompt: "hi", author: "p:p_0123abcd" },
    { myId: "web:this-tab", known: () => false });
  assert.equal(queued[0].op, "tag");
  const started = promptOps({ type: "turn_started", turn_id: "t1", prompt: "hi", author: "p:p_0123abcd", mine: true },
    { myId: "web:this-tab", known: () => false });
  assert.deepEqual(started, [{ op: "start", enqueuedId: null, prompt: "hi", mine: true }]);
  // Someone else's queued turn arrives bare: no empty bubble.
  assert.deepEqual(promptOps({ type: "turn_enqueued" }, { myId: "web:this-tab", known: () => false }), []);
  setViewerSelf(null);
  // The owner's page as before: a participant's start is someone else's prompt.
  assert.equal(promptOps({ type: "turn_started", turn_id: "t1", prompt: "hi", author: "p:p_0123abcd" },
    { myId: "web:this-tab", known: () => false })[0].op, "add");
});

ptest("labels: the owner's prompt reads \"owner\" to a participant, their echo carries their name; a pair turn is the name alone", () => {
  setViewerSelf(ALEX);
  const owners = html(userBubbleTemplate({ content: "Check the shell" }));
  assert.equal(owners.querySelector(".origin-label").textContent, "owner");
  const echo = html(userBubbleTemplate({ content: "Mine" }, { own: true }));
  assert.equal(echo.querySelector(".author-badge").textContent, "Alex");
  assert.equal(authorBadgeText("Alex", "pair"), "Alex");
  assert.equal(authorBadgeText("Alex", "review"), "Alex · review");
  setViewerSelf(null);
  assert.ok(html(userBubbleTemplate({ content: "Check the shell" })).querySelector(".origin-label") === null);
  assert.equal(authorBadgeText("Alex", "pair"), "Alex · pair");
});

ptest("the bottom row: status, ctx, speed idle or the turn's time running, their spend of the cap, what their turns may do", () => {
  const idle = barItems({ status: "idle", ctxPct: 18, speed: { decode_tps: 42 }, usage: ALEX.usage, mode: "pair" });
  assert.deepEqual(idle.items.map((i) => i.text), ["idle", "ctx 18%", "42 tok/s", "$0.42 of $2.00 used"]);
  assert.equal(idle.rules, "chi acts under the owner's rules");
  const running = barItems({ status: "running", ctxPct: 19, turnMs: 14_000, usage: ALEX.usage, mode: "pair" });
  assert.deepEqual(running.items.map((i) => i.key), ["status", "ctx", "time", "spent"]);
  // Their exposure hides the spend: no pill. No cap: the spend alone.
  assert.deepEqual(barItems({ status: "idle", usage: {} }).items.map((i) => i.key), ["status", "ctx"]);
  assert.equal(spentText({ spent: 0, cap: null }), "$0.00 used");
  const bar = html(barTemplate(idle));
  assert.equal(bar.querySelector("[data-key=spent]").textContent, "$0.42 of $2.00 used");
  assert.doesNotMatch(bar.textContent, /model|memor|\/(?!s)/);
  const who = html(whoTemplate({ name: "Alex", endsAt: ALEX.usage.expires_at }));
  assert.equal(who.querySelector(".pb-who").textContent, "Alex · invited");
  assert.match(who.querySelector(".pb-ends").textContent, /^link ends /);
});

ptest("the closed line: their limit (the mock-up's words), else a refusal or an ended link in the server's words; none while they may send", () => {
  assert.equal(closedLine({ capReached: false }), null);
  assert.deepEqual(closedLine({ capReached: true, usage: { cap: 2 } }), {
    kind: "cap_reached", title: "You have used the $2.00 the owner set for you.",
    text: "You can keep reading. Ask the owner to raise the limit to send more.",
  });
  const stopped = closedLine({ refusal: { code: "session_stopped", text: "the session is stopped; only its owner's message starts it again" } });
  assert.equal(stopped.title, "The session is stopped; only its owner's message starts it again.");
  assert.equal(closedLine({ refusal: { code: "token_revoked", text: "this review link was revoked by the session's owner" } }).kind, "token_revoked");
});

ptest("the delivery line: their own turn takes the message at its next step (Alt+Enter queues); another's queues it as their own turn", () => {
  const own = deliveryLine({ phase: "thinking", viewerTurn: { own: true, steer: true, by: null } });
  assert.equal(own.text, `↳ ${OWN_TURN_STEERS}`);
  assert.equal(own.enter, null);
  assert.equal(own.cut.shown || own.queue.shown, false);
  // A worker without participant_steer queues their own turn's message.
  assert.equal(deliveryLine({ viewerTurn: { own: true, steer: false } }).text, `↳ ${OWN_TURN_QUEUES}`);
  const owners = deliveryLine({ phase: "running a tool", viewerTurn: { own: false, steer: false, by: null } });
  assert.deepEqual([owners.text, owners.enter], [AFTER_OWNER, "queue"]);
  assert.equal(deliveryLine({ viewerTurn: { own: false, by: "Sam" } }).text, "Your message goes in as your own turn after Sam's");
  // The owner's page as before.
  assert.match(deliveryLine({ phase: "thinking" }).text, /goes in after this step/);
});

ptest("the composer's placeholder: a message that won't steer reads plain; the button keeps its in-flight state", () => {
  const plain = composerMode({ selected: "s", owner: "worker", running: true, narrow: false, steers: false });
  assert.equal(plain.placeholder, "Message chi…");
  assert.equal(plain.disabled, undefined);
  assert.equal(plain.delivery, "running");
  assert.match(composerMode({ selected: "s", owner: "worker", running: true, narrow: false }).placeholder, /^Running…/);
});

ptest("the stage's waiting look: the status and one line per kind; none puts it back", () => {
  const stage = document.createElement("section");
  const line = document.createElement("div");
  const phaseEl = document.createElement("span");
  phaseEl.textContent = "running a tool";
  const draw = createOwnerWait({ stage, line, phaseEl });
  assert.equal(line.hidden, true);
  draw("approval");
  assert.equal(phaseEl.textContent, OWNER_WAIT_STATUS);
  assert.equal(line.textContent, OWNER_WAIT_TEXT.approval);
  assert.ok(stage.classList.contains("owner-wait"));
  draw("mystery");
  assert.equal(line.textContent, OWNER_WAIT_TEXT.question);
  draw(null);
  assert.equal(line.hidden, true);
  assert.ok(!stage.classList.contains("owner-wait"));
});

function page({ running = false, read = async () => ({ viewer: ALEX }), probe } = {}) {
  document.body.innerHTML = '<div id="topBar"><span id="sessionTitleRow"></span></div><div id="infoBar"><div id="infoText"></div></div><div id="composer"></div>';
  document.body.dataset.session = "s1";
  document.body.dataset.sessionTitle = "Fix the install notes";
  const touched = [];
  const state = { running };
  const stage = { redraws: 0, redraw() { this.redraws += 1; } };
  const store = { current: { ctxPct: 18, timing: { turnRecords: [{ id: "t0", decode_tps: 42 }] }, workerFeatures: ["participant_steer"] },
    touch: (name) => touched.push(name) };
  const main = createParticipantMain({
    body: document.body, topBar: document.querySelector("#topBar"), infoBar: document.querySelector("#infoBar"),
    composer: document.querySelector("#composer"), store, running: () => state.running, stage, read, probe,
  });
  return { main, state, stage, touched };
}

ptest("participant_main: their turn's start shows Stop turn and steers; the owner's doesn't; a wait names its kind, no card", () => {
  const { main, state, stage } = page();
  const calls = [];
  const handlers = main.wrapHandlers({
    turn_started: (d) => calls.push(["started", d.turn_id]),
    turn_completed: () => calls.push(["completed"]),
    continue_offered: () => calls.push(["owner's card"]),
    question_requested: () => calls.push(["owner's card"]),
  });
  main.shown(ALEX);
  state.running = true;
  handlers.turn_started({ turn_id: "t1", author: "p:p_0123abcd", author_name: "Alex", mine: true });
  assert.equal(main.canCancel(), true);
  assert.deepEqual(main.deliveryTurn(), { own: true, steer: true, by: null });
  handlers.question_requested({ kind: "approval" });
  assert.equal(main.ownerWait(), "approval");
  assert.ok(stage.redraws > 0);
  handlers.question_answered({});
  assert.equal(main.ownerWait(), null);
  handlers.continue_offered({ kind: "continue" });
  assert.equal(main.ownerWait(), "continue");
  handlers.turn_completed({ turn_id: "t1" });
  state.running = false;
  assert.equal(main.ownerWait(), null);
  assert.equal(main.canCancel(), false);
  state.running = true;
  handlers.turn_started({ turn_id: "t2" });
  assert.equal(main.canCancel(), false);
  assert.deepEqual(main.deliveryTurn(), { own: false, steer: false, by: null });
  // The owner's cards are never drawn from a participant's events.
  assert.deepEqual(calls, [["started", "t1"], ["completed"], ["started", "t2"]]);
});

ptest("participant_main: the top row, the bottom row in the info line's place, the title chi web gave", () => {
  const { main } = page();
  main.shown(ALEX);
  main.drawBar();
  assert.equal(document.querySelector(".plain-brand").textContent, "chi");
  assert.equal(document.querySelector("#participantWho .pb-who").textContent, "Alex · invited");
  assert.equal(document.querySelector("#infoText").hidden, true);
  assert.match(document.querySelector("#participantBar").textContent, /idle.*ctx 18%.*42 tok\/s.*\$0\.42 of \$2\.00 used/s);
  assert.equal(main.title(), "Fix the install notes");
});

ptest("participant_main: their limit closes the composer; a stopped session's refusal shows the server's words until a turn starts", async () => {
  const { main } = page({ read: async () => ({ viewer: { ...ALEX, cap_reached: true } }) });
  main.shown(ALEX);
  const composer = document.querySelector("#composer");
  const closed = document.querySelector("#participantClosed");
  assert.equal(closed.hidden, true);
  assert.equal(main.refused({ code: "too_many_turns" }), false);
  assert.equal(main.refused({ code: "session_stopped", body: { detail: "the session is stopped; only its owner's message starts it again" } }), true);
  assert.equal(composer.hidden, true);
  assert.match(closed.textContent, /^The session is stopped; only its owner's message starts it again\./);
  main.wrapHandlers({}).turn_started({ turn_id: "t9" });
  assert.equal(composer.hidden, false);
  assert.equal(main.refused({ code: "cap_reached" }), true);
  assert.match(closed.textContent, /You have used the \$2\.00 the owner set for you\./);
});

ptest("participant_main: an ended link shows the 401's words from a brief read, or a refused send's own", async () => {
  const probe = async () => ({ status: 401, json: async () => ({ error: "token_expired", detail: "this review link expired: ask the session's owner for a new one" }) });
  const { main } = page({ probe });
  await main.linkEnded();
  assert.equal(document.querySelector("#participantClosed").dataset.kind, "token_expired");
  assert.match(document.querySelector("#participantClosed").textContent, /^This review link expired/);
  const unreadable = page({ probe: async () => { throw new Error("down"); } });
  await unreadable.main.linkEnded();
  assert.match(document.querySelector("#participantClosed").textContent, new RegExp(`^${LINK_ENDED[0].toUpperCase()}`));
});

ptest("participant_main: a load or resync while their turn waits for the owner keeps the waiting look and the bar's \"waiting\"", () => {
  const { main, state } = page();
  const handlers = main.wrapHandlers({ turn_started: () => {} });
  // renderSessionView: the show's viewer first (no turn runs yet on the page), then the replay.
  main.shown({ ...ALEX, waiting_for_owner: "approval" });
  state.running = true;
  handlers.turn_started({ turn_id: "t1", author: "p:p_0123abcd", mine: true, replayed: true });
  assert.equal(main.ownerWait(), "approval");
  main.drawBar();
  assert.equal(document.querySelector("#participantBar [data-key=status]").textContent, "waiting");
  // A live start is a new turn: it waits for nothing yet.
  handlers.turn_started({ turn_id: "t2", mine: true });
  assert.equal(main.ownerWait(), null);
});

ptest("participant_main: a turn-end re-read a turn started after says nothing of the wait; a second end while one is out reads again", async () => {
  const pending = [];
  const read = () => new Promise((resolve) => pending.push(resolve));
  const { main, state } = page({ read });
  const handlers = main.wrapHandlers({});
  main.shown(ALEX);
  state.running = true;
  handlers.turn_started({ turn_id: "t1", mine: true });
  handlers.turn_completed({ turn_id: "t1" });
  handlers.turn_completed({ turn_id: "t1b" });
  assert.equal(pending.length, 1);
  // The next turn starts (a Continue) before the read comes back saying "continue".
  handlers.turn_started({ turn_id: "t2", mine: true });
  pending[0]({ viewer: { ...ALEX, waiting_for_owner: "continue" }, session: { title: "Renamed" } });
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(main.ownerWait(), null);
  assert.equal(main.title(), "Renamed");
  // The queued second read.
  assert.equal(pending.length, 2);
  pending[1]({ viewer: ALEX });
  await new Promise((resolve) => setTimeout(resolve, 0));
});
