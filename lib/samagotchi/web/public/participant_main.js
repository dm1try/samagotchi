// The main page for a participant (an invited person's link): what is
// theirs on the owner's page, wired from app.js in a few lines. The
// owner's page never makes it (app.js: viewer.kind() is "participant").
//
//   - The grant's session (<body data-session>) is the page's one session,
//     whatever the hash says; no start page, no list.
//   - Who they are (viewer_self.js), from each show's `viewer`: their own
//     turns and prompts, the owner's labelled "owner".
//   - The top row's name and the link's end, the bottom row in the bar's
//     place, the closed composer (participant_bar.js).
//   - The running turn: whose it is (turn_started's author and `mine`), so
//     Stop turn shows on their own only and the delivery line says where a
//     message goes; and whether it waits for the owner (question_requested
//     / continue_offered's `kind`; stage_owner_wait.js draws it).
//   - Their usage and limit, read again from the show at each turn's end
//     (the light re-reads carry no viewer).
//   - A link that ended mid-session (a 401 from chi web): the composer gives
//     way to the server's sentence, instead of the owner's signed-out banner.
//
// See docs/internals/web-frontend.md (The participant's page).
import { render } from "./vendor/lit-html.js";
import { setViewerSelf } from "./viewer_self.js";
import { barItems, barTemplate, CLOSING_CODES, closedLine, closedTemplate, whoTemplate } from "./participant_bar.js";

// The worker features a participant's composer reads: their message goes
// into their own running turn at its next step (Delivery::OWN_TURN_STEER_FEATURE).
export const PARTICIPANT_STEER = "participant_steer";
// A 401 whose words the page couldn't read (an auth proxy's own answer).
export const LINK_ENDED = "this link no longer opens the session";

// The events that end a turn: whose turn it was and its wait go, and the
// viewer is read again (their spend moved).
const TURN_ENDS = ["turn_completed", "turn_canceled", "turn_failed"];
// The owner's question, approval or Continue offer, and their answers:
// chi web sends a participant the kind alone, never a card's content.
const WAITS = ["question_requested", "continue_offered"];
const WAIT_ENDS = ["question_answered", "question_cancelled", "continue_resolved"];

// @param body       the page's <body> (data-session, data-session-title)
// @param topBar     #topBar: the logo, title, their name, the link's end
// @param infoBar    #infoBar: the bottom row takes its place
// @param composer   #composer: given way to the closed line
// @param store      the session store (store.current: ctxPct, timing, workerFeatures)
// @param running()  a turn runs (liveTurn.running)
// @param stage      the stage view (turnDom): redraw()
// @param read(id)   the session's show (data.js getSession)
// @param probe(id)  a fetch Response of the session's brief read, whose 401 carries the ended link's words
export function createParticipantMain({ body, topBar, infoBar, composer, store, running, stage, read,
  probe = (id) => fetch(`/api/sessions/${encodeURIComponent(id)}?brief=1`, { headers: { Accept: "application/json" } }) }) {
  const sessionId = body.dataset.session || null;
  let viewer = null;
  // The running turn's author: {author, name, mine}; null between turns.
  let turnBy = null;
  // What the running turn waits for the owner on (a kind), or null.
  let waitKind = null;
  // The last generation's speed ({decode_tps, source}).
  let speed = null;
  // A refusal that closed the composer ({code, text}).
  let refusal = null;
  let reading = null;

  // The top row: a plain logo (not the owner's new-session button), their
  // name and the link's end after the title.
  const logo = document.createElement("span");
  logo.className = "brand plain-brand";
  logo.textContent = "chi";
  topBar.prepend(logo);
  const who = document.createElement("span");
  who.id = "participantWho";
  topBar.querySelector("#sessionTitleRow")?.after(who);
  // The bottom row, in the owner's info line's place.
  const row = document.createElement("div");
  row.id = "participantBar";
  infoBar.prepend(row);
  infoBar.querySelector("#infoText")?.setAttribute("hidden", "");
  const closed = document.createElement("div");
  closed.id = "participantClosed";
  closed.hidden = true;
  composer.after(closed);
  body.classList.add("participant-view");

  const redraw = () => store.touch("infoBar");

  function drawTop() {
    render(whoTemplate({ name: viewer?.name, endsAt: viewer?.usage?.expires_at }), who);
  }

  function drawClosed() {
    const line = closedLine({ capReached: !!viewer?.cap_reached, usage: viewer?.usage, refusal });
    closed.hidden = !line;
    composer.hidden = !!line;
    body.classList.toggle("participant-closed", !!line);
    if (line) {
      closed.dataset.kind = line.kind;
      render(closedTemplate(line), closed);
    }
  }

  // A show's viewer: who they are, their usage, whether the session waits.
  function shown(next) {
    if (!next || next.kind !== "participant") return;
    viewer = next;
    setViewerSelf(next);
    // A session the owner started again (it runs, or was read not stopped)
    // takes the stopped line back.
    if (refusal?.code === "session_stopped" && !next.session_stopped) refusal = null;
    if (running() && next.waiting_for_owner) waitKind = next.waiting_for_owner;
    drawTop();
    drawClosed();
    stage.redraw?.();
    redraw();
  }

  // The viewer again from the show (its usage moved, or its cap).
  async function reread() {
    if (!sessionId || reading) return reading;
    reading = read(sessionId).then((data) => shown(data?.viewer), () => {}).finally(() => { reading = null; });
    return reading;
  }

  function started(data) {
    turnBy = { author: data?.author || null, name: data?.author_name || null, mine: !!data?.mine };
    waitKind = null;
    if (refusal?.code === "session_stopped") {
      refusal = null;
      drawClosed();
    }
  }

  // The stream's handlers (stream_handlers.js) with a participant's own
  // reading of the events chi web sends them bare or cut down.
  function wrapHandlers(handlers) {
    const wrapped = { ...handlers };
    wrapped.turn_started = (data) => {
      started(data);
      handlers.turn_started?.(data);
      stage.redraw?.();
    };
    for (const type of TURN_ENDS) {
      wrapped[type] = (data) => {
        waitKind = null;
        const out = handlers[type]?.(data);
        turnBy = null;
        reread();
        redraw();
        return out;
      };
    }
    // No card: the stage's waiting look says for what kind of thing.
    for (const type of WAITS) {
      wrapped[type] = (data) => {
        waitKind = data?.kind || "question";
        stage.redraw?.();
        redraw();
      };
    }
    for (const type of WAIT_ENDS) {
      wrapped[type] = () => {
        waitKind = null;
        stage.redraw?.();
        redraw();
      };
    }
    wrapped.generation_completed = (data) => {
      if (data?.speed && Number.isFinite(Number(data.speed.decode_tps))) speed = data.speed;
      return handlers.generation_completed?.(data);
    };
    return wrapped;
  }

  function lastSpeed() {
    if (speed) return speed;
    const records = store.current.timing?.turnRecords || [];
    const last = [...records].reverse().find((r) => Number(r.decode_tps) > 0);
    return last ? { decode_tps: last.decode_tps, source: last.tps_source } : null;
  }

  function drawBar() {
    const isRunning = running();
    const status = isRunning ? (waitKind ? "waiting" : "running") : "idle";
    const startedAt = Date.parse(store.current.timing?.activeTurn?.started_at || "");
    const turnMs = isRunning && Number.isFinite(startedAt) ? Math.max(0, Date.now() - startedAt) : null;
    render(barTemplate(barItems({
      status, ctxPct: store.current.ctxPct, windowSource: store.current.ctxWindowSource, speed: lastSpeed(), turnMs,
      usage: viewer?.usage, mode: viewer?.mode,
    })), row);
  }

  // A refused send (send_turn.js): the codes that close the composer
  // close it (the cap: from the show read again); @return whether it was one.
  function refused(error) {
    const code = error?.code;
    if (!CLOSING_CODES.includes(code)) return false;
    if (code === "cap_reached") {
      viewer = viewer ? { ...viewer, cap_reached: true } : viewer;
      drawClosed();
      reread();
      return true;
    }
    refusal = { code, text: error.body?.detail || error.message };
    drawClosed();
    return true;
  }

  // chi web refused the page's credential (data.js onAuthLost): their link
  // ended. The server's sentence: a refused send's own (refused), else the
  // 401 of a brief read.
  let ended = false;
  async function linkEnded() {
    if (ended) return;
    ended = true;
    let found = null;
    try {
      const res = await probe(sessionId);
      const answer = await res.json();
      if (res.status === 401 && answer?.detail) found = { code: answer.error || "token_revoked", text: answer.detail };
    } catch (_) { /* unreachable or not JSON: the words below */ }
    if (refusal?.code?.startsWith("token_")) return;
    refusal = found || { code: "token_revoked", text: LINK_ENDED };
    drawClosed();
  }

  return {
    sessionId,
    shown,
    wrapHandlers,
    drawBar,
    refused,
    linkEnded,
    // The session title the top row shows: the one chi web gave the page.
    title: () => body.dataset.sessionTitle || "",
    // Stop turn: on their own turn only.
    canCancel: () => !!turnBy?.mine,
    // What the stage's waiting look says, while a turn runs.
    ownerWait: () => (running() ? waitKind : null),
    // The delivery line's input (delivery_line.js viewerTurn): whose turn
    // runs, and whether a message goes into it (their own, on a worker that
    // takes it).
    deliveryTurn: () => ({
      own: !!turnBy?.mine,
      steer: !!turnBy?.mine && (store.current.workerFeatures || []).includes(PARTICIPANT_STEER),
      by: turnBy?.author && !turnBy.mine ? turnBy.name || "another participant" : null,
    }),
  };
}
