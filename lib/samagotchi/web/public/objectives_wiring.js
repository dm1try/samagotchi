// The objectives' strip and moves, wired to the page's routes, so that app.js
// holds a few lines of them (its size cap). Every post follows the worker it woke
// only while the page still shows that session (latest.js), as cards_place.js does.
// A module of its own: static JS is cached at unversioned URLs.
import { stillOn } from "./latest.js";
import { cantText } from "./format.js";
import { createObjectivesMoves } from "./objectives_moves.js";
import { createObjectivesStrip } from "./objectives_strip.js";

// @param el the strip's element
// @param historyEl the history
// @param session () the open session's id
// @param running () a turn runs
// @param holding () the stage holds a finished turn (its answer, the newest, isn't in the history yet)
// @param commands () the session's command listing
// @param clientId this tab's
// @param sendCommand, sendTurn data.js's
// @param follow () follows a worker a post woke
// @param toast (text, action, options)
// @return {seed, update, reset, redraw, notYet}
export function createObjectives({ el, historyEl, session, running, holding = () => false, commands, clientId, sendCommand, sendTurn, follow, toast }) {
  const posted = async (request) => {
    const still = stillOn(session);
    await request(session());
    if (still()) follow();
  };
  const told = (what) => (e) => toast(cantText(what, e), null, { sticky: true });

  const strip = createObjectivesStrip({
    el, session, running,
    // A tap's edit goes as a card's action does: no echo, the worker woken.
    sendLine: (line) => posted((id) => sendCommand(id, line, { clientId, card: true })),
    // Not yet: a tab of its own as far as the echo goes, so the stream draws it here too.
    sendMessage: (text) => posted((id) => sendTurn(id, text, { clientId: `${clientId}:objectives`, history: false })),
    failed: told("edit the objectives"),
    onChange: () => moves.decorate(),
  });
  const moves = createObjectivesMoves({
    historyEl, notYet: (id) => strip.notYet(id),
    // Not during a turn: its answer isn't there yet, and /short refuses it. Nor
    // with a turn still in the stage: the history's last answer isn't the newest,
    // which is what /short reads. The hand-off fills the history, which redraws this.
    canShorten: () => strip.hasList() && !running() && !holding() && (commands() || []).some((c) => c?.name === "/short"),
    // false: a failure, already told: the button comes back.
    shorten: () => posted((id) => sendCommand(id, "/short", { clientId, card: true })).then(() => true, (e) => {
      told("ask for it")(e);
      return false;
    }),
  });

  return {
    seed: strip.seed,
    update: strip.update,
    reset: strip.reset,
    notYet: strip.notYet,
    // A turn started or ended.
    redraw: () => {
      strip.redraw();
      moves.decorate();
    },
  };
}
