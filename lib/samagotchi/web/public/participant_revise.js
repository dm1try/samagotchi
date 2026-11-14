// Revise on a participant's page: the answers to their own messages only,
// as chi web and the worker decide it (ParticipantRevise, from the author
// the server stamped; this is the page's mirror, so it shows a button only
// where a send would be taken). revise_stack.js draws the stacks for every
// viewer; this module answers its mayRevise, and app.js wires it for a
// participant (viewer.can("revise_own_turn")).
//
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.
import { viewerSelf } from "./viewer_self.js";
import { workerPredates } from "./worker_features.js";

// The worker feature their Revise needs (ReviseAnchor::PARTICIPANT_FEATURE):
// a worker that checks it at the stamp.
export const PARTICIPANT_REVISE_FEATURE = "participant_revise";

// The button's title and the chip's words while a live worker lacks it.
// The copy of ParticipantMessages::REVISE_UNAVAILABLE (its Ruby owner), the
// only one on the page: a refused send shows the server's own detail.
export const PARTICIPANT_REVISE_UNAVAILABLE = "this session's worker is too old for you to revise an answer: ask the session's owner to restart it";

// The pre-send gate (worker_features.js's rule): a live worker without it.
export function participantReviseUnavailable(workerFeatures, bridgeUp) {
  return workerPredates(workerFeatures, bridgeUp, PARTICIPANT_REVISE_FEATURE);
}

// Whether a prompt bubble is +author+'s: its data-author (a reload's, a live
// echo's), or this tab's own echo.
function ownPrompt(prompt, author) {
  return !!prompt && (prompt.dataset?.author === author || prompt.dataset?.own === "1");
}

// Rules 1–2 on historyTurns' list (+turns+, revise_stack.js), in one
// backward pass: the turns +author+ may revise, each opening with their
// prompt, answered, not a Verify turn, and with only their own turns after
// it (none of the owner's, another participant's or a wake turn's). The
// owner's `!` lines never reach their page, so they count for nothing here
// either. @return Set of turns
export function revisableOwn(turns, author) {
  const ok = new Set();
  if (!author || !Array.isArray(turns)) return ok;
  for (let i = turns.length - 1; i >= 0; i--) {
    const t = turns[i];
    const own = !t.wake && ownPrompt(t.prompt, author);
    if (!own) break;
    if (t.answer && !t.prompt.hasAttribute?.("data-verify")) ok.add(t);
  }
  return ok;
}

// Whether the turn at +index+ is one of revisableOwn's.
export function mayReviseOwn(turns, index, author) {
  return Array.isArray(turns) && revisableOwn(turns, author).has(turns[index]);
}

// revise_stack.js's mayRevise for the viewer looking (viewer_self.js), false
// while their composer is closed (+closed+(): cap reached, link ended,
// session stopped). One pass per decorate: its +turns+ list is read once.
export function participantMayRevise(closed = () => false) {
  let last = null;
  return (turn, turns) => {
    if (closed()) return false;
    if (last?.turns !== turns) last = { turns, ok: revisableOwn(turns, viewerSelf()?.author) };
    return last.ok.has(turn);
  };
}
