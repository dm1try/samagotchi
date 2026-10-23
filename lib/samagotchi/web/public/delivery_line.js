// The composer's delivery line (web, steer delivery P4w): a row above the
// text field in a session, always there so the composer never changes
// height (the stage above it would jump). Idle it holds the key hint; while
// the open session's turn runs it says where a message typed now goes in,
// and offers the other two deliveries as links:
//
//   ↳ goes in after this thinking step · 2:31 · 31k chars    cut in now · queue for after the turn
//   ↳ goes in after this tool call (execute · 0:12)           queue for after the turn
//
// Send (Enter, the button) is next_step; "queue for after the turn" (or
// Alt/Option+Enter) runs the message as a turn of its own after this one;
// "cut in now" (a click only: it throws the thinking away) cuts a
// thinking-only generation (the worker's SteerCut rule: once it has
// thought for the model's cut_after seconds). A link clicked with an empty
// composer arms its choice for the next Enter; Esc or a second click
// disarms it.
//
// An Apply turn (review_apply.js) in the composer is the owner's own turn,
// never a steer into the running one (that may be a participant's
// read-only review turn): while the composer holds it (hold(), till it is
// sent, emptied or Esc'd) Enter queues it, and the line says so.
//
// While a participant's review turn runs, the worker queues the owner's
// input behind it whatever it asks (never a steer or a cut into a
// read-only turn): Enter queues, no cut is offered, and the line says so.
//
// deliveryLine is pure (node tests); deliveryLineTemplate is its lit view.
import { html, nothing, render } from "./vendor/lit-html.js";

export const QUEUE_LABEL = "queue for after the turn";
export const CUT_LABEL = "cut in now";
// A phone's row (≤ 600 px) is short: its text and chips.
const QUEUE_SHORT = "queue";
const CUT_SHORT = "cut in";
// Alt+Enter to a worker without the delivery feature: not sent (a queue
// would steer it), the text kept, this said.
export const QUEUE_NEEDS_WORKER = "Not sent: queueing needs a newer worker (it would steer the running turn). "
  + "Restart it (chi sessions restart ID, or the update badge), then send again.";
// The line while the composer holds an Apply turn (Enter queues it).
export const APPLY_QUEUES = "your Apply turn queues for after this turn · Esc to steer it in instead";
export const APPLY_QUEUES_SHORT = "Apply: queued after the turn";
// The same to a worker without the delivery feature: Enter refuses it.
export const APPLY_CANT_QUEUE = "your Apply turn can't queue on this worker (restart it) · Esc to steer it in instead";
// The line while a participant's review turn runs (the worker queues).
export const PARTICIPANT_TURN_QUEUES = "goes in as your own turn after this participant's review turn";
export const PARTICIPANT_TURN_QUEUES_SHORT = "after their review turn";
// The idle row: the keys (the placeholder's hint before the row existed).
export const IDLE_HINT = "Enter to send · Shift+Enter newline · ↑ history";

// m:ss (h:mm:ss past an hour) of +seconds+; "" when unknown.
export function clockText(seconds) {
  if (seconds == null || !Number.isFinite(seconds) || seconds < 0) return "";
  const total = Math.floor(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = String(total % 60).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${s}` : `${m}:${s}`;
}

// "812 chars", "31k chars"; "" for none.
export function charsText(count) {
  if (!count) return "";
  return count < 1000 ? `${count} chars` : `${Math.round(count / 1000)}k chars`;
}

// Seconds the current generation has run: from the page's own clock (its
// first thinking delta, thinkingAt, as the worker's cut counts; else its
// startedAt, set at generation_started), else from the worker's snapshot
// (+serverGen+: {thinking_only, age, at}; a page that joined mid-generation
// has no start of its own: age as of +at+, the page's clock when the
// snapshot came); null when neither.
export function genAge(gen, serverGen, now) {
  const since = gen?.thinkingAt ?? gen?.startedAt;
  if (since != null) return Math.max(0, (now - since) / 1000);
  if (serverGen?.age != null && serverGen.at != null) return serverGen.age + Math.max(0, (now - serverGen.at) / 1000);
  return null;
}

// Whether the generation has streamed only thinking: thinking, no visible
// text, no tool call (the worker's GenerationPhase, freshness aside: a
// stale cut is the worker's to refuse or hold, its ack says which). The
// worker's own word (+serverGen+) wins: it also sees tool-call chunks.
function thinkingOnly(gen, serverGen) {
  if (!gen?.thinking || gen.text?.trim() || gen.tools?.length) return false;
  return serverGen?.thinking_only !== false;
}

// What the line shows for the running turn:
//   phase      stage_model.js liveSlots(turn).phase
//   gen        the current gen (turn_model.js: thinking, text, tools, startedAt)
//   tool       the running call: {name, startedAt} (activity.js row), or null
//   cutAfter   the run's cut wait in seconds (turn_started / current_turn
//              cut_after): 0 is cutting off, null unknown (an older worker)
//   serverGen  the snapshot's current_turn.generation with `at`, or null
//   now        the page's clock (ms)
//   armed      "cut" | "queue" | null: the choice the next Enter sends
//   canQueue   the worker takes delivery: queue (its "delivery" feature)
//   model      the session's model, for the cut-off reason
//   held       the composer holds an Apply turn: Enter queues it (an armed
//              cut still wins)
//   participantTurn  the running turn is a participant's: Enter queues,
//              no cut (the worker queues the owner's input behind it)
// → {text, short, cut: {enabled, shown, reason, label, short}, queue:
//    {enabled, shown, label, short}, armed, enter}: short is the phone's text;
//    armed is what is still armed (a cut no longer possible disarms); enter
//    what Enter sends ("cut", "queue" or null: a steer). With
//    cutting off the cut link goes (the text says why); without the
//    feature the queue link goes.
export function deliveryLine({ phase = "thinking", gen = null, tool = null, cutAfter = null, serverGen = null, now = Date.now(),
  armed = null, canQueue = true, model = "", held = false, participantTurn = false } = {}) {
  const cutOff = cutAfter === 0 || (cutAfter != null && cutAfter < 0);
  const thinking = phase === "thinking" && thinkingOnly(gen, serverGen);
  const age = genAge(gen, serverGen, now);
  let where;
  let short;
  let reason = "";
  if (phase === "running a tool") {
    const clock = clockText(tool?.startedAt != null ? (now - tool.startedAt) / 1000 : null);
    where = `goes in after this tool call (${[tool?.name || "tool", clock].filter(Boolean).join(" · ")})`;
    short = ["after this tool call", clock].filter(Boolean).join(" · ");
    reason = "a tool is running: only a thinking step can be cut";
  } else if (phase === "waiting for you") {
    where = "goes in once the card above is answered";
    short = "after the card's answer";
    reason = "the turn waits for you";
  } else if (phase === "writing" || phase === "writing the answer") {
    where = "goes in after this answer; the turn may go on";
    short = "after this answer";
    reason = "the model is writing: only a thinking step can be cut";
  } else if (thinking) {
    where = ["goes in after this thinking step", clockText(age), charsText(gen.thinking.length)].filter(Boolean).join(" · ");
    short = ["after this thinking", clockText(age)].filter(Boolean).join(" · ");
  } else {
    where = "goes in after this step";
    short = "after this step";
    reason = "nothing to cut until the model thinks";
  }
  if (cutOff) reason = `cutting is off for ${model || "this model"}`;
  const cutEnabled = !cutOff && thinking;
  let wait = "";
  if (cutEnabled && cutAfter > 0 && age != null && age < cutAfter) wait = `cuts at about ${clockText(cutAfter)} if you choose ${CUT_LABEL}`;
  const effective = (armed === "cut" && cutEnabled) || (armed === "queue" && canQueue) ? armed : null;
  // An Apply turn queues unless a cut was armed for it.
  const applies = held && effective !== "cut";
  const enter = effective || (applies && canQueue ? "queue" : null);
  let parts = [cutOff ? reason : "", where, wait].filter(Boolean);
  // A phone's short row leaves it out: its ticked chip says it.
  if (effective) parts.push("Enter sends");
  if (applies) {
    parts = [canQueue ? APPLY_QUEUES : APPLY_CANT_QUEUE];
    if (canQueue) short = APPLY_QUEUES_SHORT;
  }
  if (participantTurn) {
    return {
      text: `\u21B3 ${PARTICIPANT_TURN_QUEUES}`,
      short: `\u21B3 ${PARTICIPANT_TURN_QUEUES_SHORT}`,
      cut: { enabled: false, shown: false, reason: "", label: CUT_LABEL, short: CUT_SHORT },
      queue: { enabled: true, shown: true, label: `${QUEUE_LABEL} \u2713`, short: `${QUEUE_SHORT} \u2713` },
      armed: null,
      enter: "queue",
    };
  }
  const tick = (label, which) => (enter === which ? `${label} \u2713` : label);
  return {
    text: `\u21B3 ${parts.join(" · ")}`,
    short: `\u21B3 ${short}`,
    cut: { enabled: cutEnabled, shown: !cutOff, reason: cutEnabled ? "" : reason, label: tick(CUT_LABEL, "cut"), short: tick(CUT_SHORT, "cut") },
    queue: { enabled: canQueue, shown: canQueue, label: tick(QUEUE_LABEL, "queue"), short: tick(QUEUE_SHORT, "queue") },
    armed: effective,
    enter,
  };
}

// The line's view: +line+ is deliveryLine's; +onCut+ / +onQueue+ the
// links' clicks. A disabled cut stays in place, its reason on hover.
export function deliveryLineTemplate(line, { onCut, onQueue } = {}) {
  const on = line.enter ?? line.armed;
  const link = (which, part, onClick) => html`<button type="button" class="delivery-link ${which}${on === which ? " armed" : ""}"
    ?disabled=${!part.enabled} title=${part.reason || nothing} aria-label=${part.label} aria-pressed=${on === which ? "true" : "false"}
    @mousedown=${(e) => e.preventDefault()} @click=${onClick}><span class="long">${part.label}</span><span class="short">${part.short}</span></button>`;
  const links = [line.cut.shown ? link("cut", line.cut, onCut) : null, line.queue.shown ? link("queue", line.queue, onQueue) : null]
    .filter(Boolean);
  return html`<span class="delivery-where" title=${line.text}><span class="long">${line.text}</span><span class="short">${line.short}</span></span><span class="delivery-links">${links.map((l, i) =>
    (i ? html`<span class="delivery-sep" aria-hidden="true">·</span>${l}` : l))}</span>`;
}

// The idle row: the key hint (none on a phone: no keyboard keys there).
function idleTemplate() {
  return html`<span class="delivery-where idle"><span class="long">${IDLE_HINT}</span><span class="short"></span></span>`;
}

// The row on the page: the key hint while idle, the line while the turn
// runs (its clock ticking every TICK_MS), nothing outside a session; the
// armed choice is kept here. No page globals: the page passes its hooks.
//   read()           deliveryLine's inputs but now and armed (the turn's
//                    phase, gen, tool, cutAfter, serverGen, canQueue, model)
//   composerEmpty()  nothing typed and no image chips: a link arms
//   send(delivery)   send the composer's line with +delivery+ ("cut", "queue")
//   session()        the open session's id: an Apply hold is that session's
const TICK_MS = 500;

export function createDeliveryControl({ el, read, composerEmpty, send, session = () => null, now = () => Date.now(),
  setTimer = (fn, ms) => setInterval(fn, ms), clearTimer = (t) => clearInterval(t) }) {
  // "off" (no session: the row is gone), "idle" or "running".
  let mode = "off";
  let armed = null;
  // The session whose Apply turn the composer holds, or null.
  let heldFor = null;
  let timer = null;
  let line = null;

  const click = (which) => {
    if (mode !== "running" || !line?.[which]?.enabled) return;
    if (!composerEmpty()) {
      armed = null;
      send(which);
      return;
    }
    armed = armed === which ? null : which;
    refresh();
  };

  function refresh() {
    if (mode === "off") return;
    if (mode === "idle") {
      render(idleTemplate(), el);
      return;
    }
    line = deliveryLine({ ...read(), now: now(), armed, held: held() });
    // A choice no longer possible (a tool started) disarms.
    armed = line.armed;
    render(deliveryLineTemplate(line, { onCut: () => click("cut"), onQueue: () => click("queue") }), el);
  }

  const held = () => heldFor != null && heldFor === session();

  return {
    // +next+: "off", "idle" or "running".
    show(next) {
      if (next !== mode) {
        mode = next;
        el.hidden = mode === "off";
        el.classList.toggle("running", mode === "running");
        if (mode === "running") timer ??= setTimer(refresh, TICK_MS);
        else {
          clearTimer(timer);
          timer = null;
          armed = null;
          line = null;
        }
      }
      refresh();
    },
    refresh,
    click,
    armed: () => armed,
    // The composer holds an Apply turn (of the open session): Enter queues it.
    hold() {
      heldFor = session();
      refresh();
    },
    held,
    // The composer let it go (emptied).
    release() {
      if (heldFor == null) return;
      heldFor = null;
      refresh();
    },
    // What this send goes in as while the turn runs ("cut", "queue" or
    // null), the armed choice and the Apply hold let go. The hold is the
    // line's word on it (it knows the worker can queue); idle, none.
    take() {
      const was = mode === "running" && line ? line.enter : armed;
      if (armed || heldFor != null) {
        armed = null;
        heldFor = null;
        refresh();
      }
      return was || null;
    },
    // Esc: the armed choice goes; else, while the turn runs, the Apply hold
    // (Enter then steers it in).
    disarm() {
      if (armed) armed = null;
      else if (mode === "running" && held()) heldFor = null;
      else return false;
      refresh();
      return true;
    },
    line: () => line,
  };
}
