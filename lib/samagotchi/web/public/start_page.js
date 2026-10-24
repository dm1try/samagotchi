import {
  chipModel as llmContextChipModel, choiceWords, createLlmContextControl, NEW_SESSION, withChoice,
} from "./llm_context_chip.js";
import { chipModel as thinkingChipModel, createThinkingControl, withChoice as withThinkingChoice } from "./thinking_chip.js";
import { MODEL_KEY, modelsFailedText } from "./model_pick.js";
import { createModelPicker } from "./model_picker.js";
import { chainNeighbours, freshLink } from "./chains.js";
import { readStored } from "./storage.js";
import { createReviewStartControl, reviewChipModel } from "./review_start.js";

// ── The start page's model picker ──────────────────────────────────────────
// The hosts' models from GET /api/models, the choice this browser made last
// preselected while it is still offered (else the server's default). Hidden
// until the list is in, and in a session (its model is in the info bar),
// but a fresh chain link's (chains.js freshLink): there it shows the link's
// model and a pick runs /model in the link, remembered neither as this
// browser's choice nor in Recent. A host that failed is the picker's
// tooltip; a route that fails leaves the picker hidden and the server's
// default in charge. The search list itself is model_picker.js'; a pick
// sends the focus to the message box.
//
// Beside it, the start page's LLM context and thinking chips: the picked
// model's values, and a choice for the next new session only (sent with its
// create, then dropped; never remembered: a reload or opening a session
// drops it too, a failed create keeps it).
export const START_PICK_TITLE = "The model the new session starts on";

// Used by app.js. Elements: +pickEl+ (the picker's button), +panelEl+,
// +searchEl+, +listEl+, +composerEl+, +centerEl+ (model_picker.js'),
// +llmContextEl+ / +thinkingEl+ (the two chips).
// Hooks: +selected()+ the open session's id or null; +state()+ the open
// session's fields (session_state.js: model, continues…); +running()+ a turn
// runs; +sessions()+ the list; +run(line)+ a session command from a control
// (resolves true once the worker took it); +focusPrompt()+; +toast(text)+;
// +listModels()+ GET /api/models (data.js). +win+: the page's unload events.
export function createStartPage({
  pickEl, panelEl, searchEl, listEl, composerEl, centerEl, llmContextEl, thinkingEl, reviewEl,
  selected, state, running, sessions, run, focusPrompt, toast, listModels,
  doc = globalThis.document, win = globalThis.window,
}) {
  // The new session's own choices (null: follow the picked model's).
  let newChatLlmContext = null;
  let newChatThinking = null;
  // The files that make the new session a review session ([]: an ordinary one).
  let newChatReview = [];
  let startPickTitle = START_PICK_TITLE;
  // The fresh link the picker shows (null: the start page, or a session it
  // is hidden in), and a link pick's /model still in flight (a send waits).
  let pickLinkId = null;
  let pickSelected = null;
  let pendingPick = null;
  let pendingPickId = null;
  // A command_ran came while the pick was in flight (its sync was skipped):
  // the ack syncs then.
  let pickRanEarly = false;
  // A reload cuts the fetch: its error is no news (modelsFailedText).
  let pageLeaving = false;

  const newChatLlmSummary = () => (selected() || pickEl.hidden ? null : modelPicker.chosenRow()?.llm_context || null);
  const llmContextNewControl = createLlmContextControl({
    el: llmContextEl,
    summary: newChatLlmSummary,
    kind: NEW_SESSION,
    choice: () => newChatLlmContext,
    choose: (next) => {
      newChatLlmContext = next;
      renderNewChatLlmContext();
      focusPrompt();
    },
    id: "llmContextNewPopover",
    anchor: "#llmContextNew",
  });
  const newChatThinkingSummary = () => (selected() || pickEl.hidden ? null : modelPicker.chosenRow()?.thinking || null);
  const thinkingNewControl = createThinkingControl({
    el: thinkingEl,
    summary: newChatThinkingSummary,
    kind: NEW_SESSION,
    choice: () => newChatThinking,
    choose: (next) => {
      newChatThinking = next;
      renderNewChatThinking();
      focusPrompt();
    },
    id: "thinkingNewPopover",
    anchor: "#thinkingNew",
  });
  const reviewNewControl = reviewEl ? createReviewStartControl({
    el: reviewEl,
    choice: () => newChatReview,
    choose: (next) => {
      newChatReview = next;
      renderNewChatReview();
      focusPrompt();
    },
  }) : null;
  function renderNewChatReview() {
    if (!reviewEl) return;
    const chip = reviewChipModel(newChatReview);
    reviewEl.textContent = chip.text;
    reviewEl.title = chip.title;
    reviewEl.classList.toggle("own", chip.own);
  }
  function renderNewChatThinking() {
    const chip = thinkingChipModel(withThinkingChoice(newChatThinkingSummary(), newChatThinking), { kind: NEW_SESSION });
    thinkingEl.hidden = !chip;
    if (!chip) return thinkingNewControl.close();
    thinkingEl.textContent = chip.text;
    thinkingEl.title = chip.title;
    thinkingEl.classList.toggle("own", chip.own);
  }
  // Hidden without the model's values (the list not in, an older server).
  function renderNewChatLlmContext() {
    const chip = llmContextChipModel(withChoice(newChatLlmSummary(), newChatLlmContext), { kind: NEW_SESSION });
    llmContextEl.hidden = !chip;
    if (!chip) return llmContextNewControl.close();
    llmContextEl.textContent = chip.text;
    llmContextEl.title = chip.title;
    llmContextEl.classList.toggle("own", chip.own);
  }

  const modelPicker = createModelPicker({
    button: pickEl,
    panel: panelEl,
    input: searchEl,
    list: listEl,
    composer: composerEl,
    center: centerEl,
    remember: () => !selected(),
    onPick: (name) => {
      if (selected()) pickForLink(name);
      else {
        renderNewChatLlmContext();
        renderNewChatThinking();
      }
      focusPrompt();
    },
  });
  // A pick on a fresh link: /model in its worker (its command bubble and the
  // info bar follow from command_ran); refused, the button goes back to the
  // link's model, if the page is still on that link.
  function pickForLink(name) {
    const id = selected();
    const ran = run(`/model ${name}`).then((ok) => {
      const ranEarly = pendingPick === ran && pickRanEarly;
      if (pendingPick === ran) {
        pendingPick = null;
        pendingPickId = null;
        pickRanEarly = false;
      }
      if ((!ok || ranEarly) && selected() === id) syncModelPick();
      return ok;
    });
    pendingPick = ran;
    pendingPickId = id;
    pickRanEarly = false;
  }
  // The button's name, tooltip and label for what the page shows: a fresh
  // link's model, else the start page's (whose choice stays as it is).
  // Toggles the fresh-link class (the CSS shows the button in a session
  // only with it); the panel closes when the link changes or stops being fresh.
  function syncModelPick() {
    const open = selected();
    const current = state();
    // The list walk only for a link that is fresh otherwise (the info bar
    // calls this every second while a turn runs).
    const fresh = !!open && freshLink(current, { running: running() })
      && !chainNeighbours(sessions(), open, { continues: current.continues }).next;
    doc.body.classList.toggle("fresh-link", fresh);
    const linkId = fresh ? open : null;
    // Another session (or the start page), or the link stopped being fresh:
    // a panel left open would come back open where it no longer belongs.
    if (open !== pickSelected || linkId !== pickLinkId) modelPicker.close();
    pickSelected = open;
    pickLinkId = linkId;
    if (fresh) {
      // A pick in flight keeps its name until its /model is taken (its
      // command_ran syncs again then).
      if (!(pendingPick && pendingPickId === open)) modelPicker.show(current.model);
      pickEl.title = "The model this link starts on";
      pickEl.setAttribute("aria-label", "Model this link starts on");
    } else {
      pickEl.title = startPickTitle;
      pickEl.setAttribute("aria-label", "Model for the new session");
    }
  }
  // A command_ran with a model (stream_handlers.js): while a pick is in
  // flight its ack syncs again.
  function commandRan() {
    if (pendingPick) pickRanEarly = true;
    syncModelPick();
  }
  // Leaving a session: the start page's remembered model again (no fetch).
  function restoreStartPick() {
    modelPicker.restore(readStored(MODEL_KEY));
    renderNewChatLlmContext();
    renderNewChatThinking();
  }
  win.addEventListener("beforeunload", () => { pageLeaving = true; });
  win.addEventListener("pagehide", () => { pageLeaving = true; });
  win.addEventListener("pageshow", () => { pageLeaving = false; }); // back from the bfcache
  // +asked+: + new session's load, for the start page it opens.
  async function loadModels({ asked = false } = {}) {
    let payload;
    try {
      payload = await listModels();
    } catch (e) {
      const text = modelsFailedText(e, { startPage: !selected(), asked, leaving: pageLeaving });
      if (text) toast(text);
      return;
    }
    const stored = readStored(MODEL_KEY);
    if (!modelPicker.setModels(payload, stored)) return;
    startPickTitle = payload.warning ? `${START_PICK_TITLE} · ${payload.warning}` : START_PICK_TITLE;
    pickEl.hidden = false;
    // A fresh link open meanwhile shows its own model again, not the stored one.
    syncModelPick();
    renderNewChatLlmContext();
    renderNewChatThinking();
  }
  // The picker's choice for a create request; nothing (the server's default)
  // while the list is not in.
  function chosenModel() {
    return pickEl.hidden ? undefined : modelPicker.chosen() || undefined;
  }
  // The create request's own choices (the chips').
  function newChoices() {
    return { llm_context: choiceWords(newChatLlmContext), thinking: newChatThinking || undefined,
             review: newChatReview.length ? { subjects: newChatReview } : undefined };
  }
  // The choices were for that new session only: a create took them.
  function clearChoices() {
    newChatLlmContext = null;
    renderNewChatLlmContext();
    newChatThinking = null;
    renderNewChatThinking();
    newChatReview = [];
    renderNewChatReview();
  }
  // A session opened: the start page's choices were for a new session, they go.
  function dropChoices() {
    llmContextNewControl.close();
    if (newChatLlmContext) {
      newChatLlmContext = null;
      renderNewChatLlmContext();
    }
    thinkingNewControl.close();
    if (newChatThinking) {
      newChatThinking = null;
      renderNewChatThinking();
    }
    reviewNewControl?.close();
    if (newChatReview.length) {
      newChatReview = [];
      renderNewChatReview();
    }
  }

  return {
    syncModelPick, commandRan, restoreStartPick, loadModels, chosenModel, newChoices, clearChoices, dropChoices,
    // A fresh link's /model still in flight (a send waits for it), or null.
    pendingPick: () => pendingPick,
    // The start page's review files ([]: the new session isn't a review).
    reviewSubjects: () => newChatReview,
    // Start refused them (400 invalid_review): said in the review form, opened
    // again. @return whether it was said there
    reviewRefused: (message) => {
      if (!reviewNewControl || !newChatReview.length) return false;
      reviewNewControl.refuse(message);
      return true;
    },
  };
}
