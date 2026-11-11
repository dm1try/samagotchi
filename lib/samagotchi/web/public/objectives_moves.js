// The model's moves on the objectives, as chips in the conversation. A tool row
// of the objectives tool shows its id as a chip (moveRowText, turn_html.js, live
// and reloaded alike), but a finished turn's steps collapse, so a finished turn
// also gets a line of its moves between its block and its answer (mockup G). The
// rows are the record: one observer on the history reads them back, as
// answer_fold.js decorates its answers, so every path that fills it is covered.
// Nothing is drawn for a turn with no move. A decision-card's "Concerns O2" gets
// the same chip. The newest long answer of a session with a list offers its
// short version where the bundle's /short is there (decision-card): the card
// lands under it, so the button sits there too. A module of its own: static JS is cached at unversioned URLs.
import { foldable } from "./answer_fold.js";
import { TURN_PROMPT } from "./bubbles.js";
import { backingText, stateOfParams, stateWord, WORK_ROWS } from "./objectives_state.js";
import { keepFollowing } from "./scroll.js";
import { html, nothing, render } from "./vendor/lit-html.js";

const ROW_TITLE = /^(O\d+)\s+([^]*)$/;
const RECORDED = /Recorded a move on /;
const CONCERNS = /^Concerns (O\d+)\b/;

// A row's move: {id, note, state?} (state only for blocked or done, from the
// params line), null for any other row, and for a call that recorded nothing (no
// list, a refusal: Tools::ObjectivesTool).
export function moveOfRow(row) {
  if (row?.tool !== "objectives" || !RECORDED.test(String(row.output || ""))) return null;
  const found = ROW_TITLE.exec(String(row.title || row.params || ""));
  if (!found) return null;
  const state = stateOfParams(row.params);
  return state ? { id: found[1], note: found[2], state } : { id: found[1], note: found[2] };
}

// The row's title, its objective a chip, marked for the line above an answer
// when the call recorded a move.
export function moveRowText(row, shown) {
  if (row?.tool !== "objectives") return shown;
  const found = ROW_TITLE.exec(String(shown ?? ""));
  if (!found) return shown;
  const move = moveOfRow(row);
  return html`<span class="obj-pill obj-mark" data-move-id=${move ? move.id : nothing} data-move-note=${move ? move.note : nothing} data-move-state=${move?.state || nothing}>${found[1]}</span>${stateTemplate(move?.state)} ${found[2]}`;
}

// A move's state as words beside its id, by text and a class (never colour
// alone); nothing for progress.
function stateTemplate(state) {
  const word = stateWord(state);
  return word ? html` <span class=${`obj-state ${state}`}>${word}</span>` : nothing;
}

// A finished turn block's moves, in order.
export function movesInBlock(block) {
  return [...block.querySelectorAll("[data-move-id]")].map((el) => {
    const move = { id: el.dataset.moveId, note: el.dataset.moveNote || "" };
    if (el.dataset.moveState) move.state = el.dataset.moveState;
    return move;
  });
}

// A card body's "Concerns O2 …" paragraph: the id a chip. Idempotent.
export function chipConcerns(body) {
  for (const p of body.querySelectorAll("p")) {
    const first = p.firstChild;
    if (first?.nodeType !== 3) continue;
    const found = CONCERNS.exec(first.textContent);
    if (!found) continue;
    const chip = body.ownerDocument.createElement("span");
    chip.className = "obj-pill obj-mark";
    chip.textContent = found[1];
    first.textContent = first.textContent.slice(found[0].length);
    p.insertBefore(chip, first);
    p.classList.add("obj-concerns");
  }
}

function lineFor(block) {
  const next = block.nextElementSibling;
  return next?.classList.contains("obj-moves") ? next : null;
}

// @param historyEl the history
// @param notYet (id) the tap on a move's Not yet (the newest turn's only: CSS)
// @param canShorten () whether the newest long answer offers its short version
// @param shorten () the tap on it
// @param latestMove (id) the view's last move of an objective (its backing), null while it can't be placed
// @param canMarkNoMove () whether the newest finished block may say it recorded no move (an active objective, no turn running or held)
export function createObjectivesMoves({ historyEl, notYet = () => {}, canShorten = () => false, shorten = () => {}, latestMove = () => null,
                                        canMarkNoMove = () => false }) {
  // Off once tapped; back when +ask+ answers false (a failure, already told).
  const once = (e, ask) => {
    const button = e.currentTarget;
    button.disabled = true;
    Promise.resolve(ask()).then((sent) => {
      if (sent === false) button.disabled = false;
    });
  };
  const drawLine = (line, moves) => render(html`${moves.map((m) => html`<div class="obj-move-line">
    <span class="obj-pill obj-mark">${m.id}</span>${stateTemplate(m.state)}<span class="obj-move-note">${m.note}</span>${m.flag ? html`<span class="obj-unbacked">${m.flag}</span>` : nothing}
    <button type="button" class="obj-act ghost obj-notyet" title=${`Tell the agent: not yet on ${m.id}`} @click=${(e) => once(e, () => notYet(m.id))}>Not yet</button>
  </div>`)}`, line);

  const markNewest = () => {
    const lines = [...historyEl.querySelectorAll(":scope > .obj-moves")];
    lines.forEach((line, i) => line.classList.toggle("newest", i === lines.length - 1));
  };

  // After an answer's own rows (its Revise row, its timing line: the bubble's
  // next siblings, one of which CSS reads by adjacency).
  function shortRowPlace(answer) {
    let place = answer;
    while (place.nextElementSibling?.matches(".revise-row, .turn-timing")) place = place.nextElementSibling;
    return place;
  }

  function placeShort() {
    const answers = canShorten() ? historyEl.querySelectorAll(":scope > .bubble.output:not(.streaming)") : [];
    const answer = answers[answers.length - 1];
    const long = answer && foldable(answer.dataset.copySource || answer.textContent);
    let row = historyEl.querySelector(":scope > .obj-short");
    if (!long) {
      row?.remove();
      return;
    }
    if (!row) {
      row = historyEl.ownerDocument.createElement("div");
      row.className = "obj-short";
      render(html`<button type="button" class="obj-act ghost" title="Ask for the short version; nothing enters the conversation"
        @click=${(e) => once(e, shorten)}>Short version</button>`, row);
    }
    const place = shortRowPlace(answer);
    if (place.nextElementSibling !== row) {
      row.querySelector("button").disabled = false;
      keepFollowing(historyEl, () => place.after(row));
    }
  }

  // The view's backing is its latest move's: drawn on that objective's last
  // move in the history only (a block may hold two moves on it).
  function flagged(blocks) {
    const newest = new Map();
    blocks.forEach((block, b) => movesInBlock(block).forEach((m, i) => newest.set(m.id, `${b}:${i}`)));
    return (b, moves) => moves.map((m, i) => {
      const flag = newest.get(m.id) === `${b}:${i}` ? backingText(latestMove(m.id)) : null;
      return flag ? { ...m, flag } : m;
    });
  }

  // The newest finished turn of the owner's that did work (an edit, write or
  // execute row) and recorded no move says so where its moves line would be.
  // Only the newest: the list of an older turn's time isn't known. Not for a
  // canceled or failed turn, nor a participant's (turn_block.js stamps them),
  // nor one that ran before the list's first note (the model had none to move
  // on), nor once a newer turn's prompt follows it (a plain turn has no block).
  const after = (a, b) => !!(a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING);
  function newerTurn(block) {
    for (let el = block.nextElementSibling; el; el = el.nextElementSibling) if (el.matches(TURN_PROMPT)) return true;
    return false;
  }

  function placeNoMove(blocks) {
    const newest = blocks[blocks.length - 1];
    const list = historyEl.querySelector(".objectives-entry");
    const wanted = newest && canMarkNoMove() && newest.dataset.end === "completed" && !newest.dataset.participant
      && !newest.querySelector("[data-move-id]") && newest.querySelector(WORK_ROWS)
      && list && after(list, newest) && !newerTurn(newest);
    for (const el of historyEl.querySelectorAll(":scope > .obj-nomove")) {
      if (!wanted || el.previousElementSibling !== newest) el.remove();
    }
    if (!wanted || newest.nextElementSibling?.classList.contains("obj-nomove")) return;
    const el = historyEl.ownerDocument.createElement("div");
    el.className = "obj-nomove";
    el.textContent = "no move recorded";
    el.title = "This turn did work and recorded no move on the objectives. Information only.";
    keepFollowing(historyEl, () => newest.after(el));
  }

  function decorate() {
    const blocks = [...historyEl.querySelectorAll(":scope > .turn-work")];
    const withFlags = flagged(blocks);
    for (const [b, block] of blocks.entries()) {
      const moves = withFlags(b, movesInBlock(block));
      const line = lineFor(block);
      if (!moves.length) {
        line?.remove();
        continue;
      }
      const sig = JSON.stringify(moves);
      if (line?.dataset.sig === sig) continue;
      keepFollowing(historyEl, () => {
        const el = line || historyEl.ownerDocument.createElement("div");
        el.className = "obj-moves";
        el.dataset.sig = sig;
        drawLine(el, moves);
        if (!line) block.after(el);
      });
    }
    markNewest();
    placeNoMove(blocks);
    placeShort();
    for (const card of historyEl.querySelectorAll(".plugin-card .card-body")) {
      if (card.closest(".plugin-card").querySelector(".card-source")?.textContent === "decision-card") chipConcerns(card);
    }
  }

  // The class toggle isn't a childList change, so this doesn't feed itself.
  new MutationObserver(decorate).observe(historyEl, { childList: true, subtree: true });
  decorate();
  return { decorate };
}
