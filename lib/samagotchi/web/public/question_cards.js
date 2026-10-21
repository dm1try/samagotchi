// The cards that ask the user inside the history, and their DOM (the words
// are question_card.js'):
//
// ── ask_user_question card ─────────────────────────────────────────────────
// Inline card in the message history: rendered on question_requested (or from
// pending_question on session select for reload recovery), resolved/disabled
// on question_answered / question_cancelled so SSE replay and answers from
// another client converge to the same state.
//
// ── continue card ──────────────────────────────────────────────────────────
// A turn ran out of iterations: continue it, drop it, or drop it saying why
// (the terminal's continue prompt). Answers go as /continue commands; the
// card closes on the continue_resolved every client gets.

import { dismissQuestion, sendAnswer, sendCommand } from "./data.js";
import { diffTemplate } from "./diff_view.js";
import { render } from "./vendor/lit-html.js";
import {
  answerErrorText, approvalAllowed, approvalView, CONTINUE_REASON_PLACEHOLDER, deniedReason, isContinue, keepsAskingText,
  nextCardAction, relayedToView, relayView, resultText, summaryText,
} from "./question_card.js";
import { sessionHash } from "./route.js";
import { clientLabel, isOwn } from "./turn_events.js";
import { continueLine } from "./commands.js";
import { plainText } from "./plain_line.js";

// @param sessionId () => the open session's id (answers go there)
// @param clientId this tab's id in the session's events
// @param place (card) puts a new card at the end of the history; true: the
//   stage took it (it brings the card into its view itself, eased)
// @param isNearBottom () => whether the history follows its end
// @param scrollToEnd () scrolls the history to its end
// @param removeHintIfEmpty () drops the history's placeholder hint
// @param askingText () => the running turn's asking reply (turn_model.js
//   askingText via the page's view), kept by a question or own approval card
// @param renderMarkdown (text) => Promise<html|null>: the kept reply's
//   markdown (the page's POST /api/render; null keeps the raw text)
// @param linkRefs (el) the page's path:line ref pass on it
// @param api {sendAnswer, dismissQuestion, sendCommand} (data.js)
// @param doc the page's document
// @return {renderQuestion(pq, {said}), resolveQuestion(id, opts), removeQuestion(),
//   questionCard() (the live card or null), pendingQuestion() (or null),
//   renderContinue(offer), resolveContinue(data), forgetContinue()}
export function createQuestionCards({
  sessionId, clientId, place, isNearBottom, scrollToEnd, removeHintIfEmpty, askingText = () => "",
  renderMarkdown = () => Promise.resolve(null), linkRefs = () => {},
  api = { sendAnswer, dismissQuestion, sendCommand }, doc = globalThis.document,
}) {
  // Live ask_user_question card, keyed by pending question id. Re-rendered from
  // pending_question on session select so a reload mid-question restores it.
  let questionEl = null;
  let pending = null;
  // The continue offer's card while the offer is pending.
  let continueEl = null;
  // card → the reply that asked it, drawn under the summary once resolved.
  const saidOf = new WeakMap();

  // +said+: the asking reply when the caller knows it (a reloaded card: its
  // step's text, "" for none); else the running turn's (askingText).
  function renderQuestionCard(pq, { said = null } = {}) {
    const action = nextCardAction({ cardId: questionEl?.dataset.qid ?? null, pendingId: pending?.id ?? null }, pq);
    if (action === "same") return;
    // A resolved card stays where it was; only a pending one is replaced.
    if (action === "keep") questionEl = null;
    else removeQuestionCard();
    pending = pq;
    removeHintIfEmpty();

    const approval = approvalView(pq);
    const stepLimit = isContinue(pq);
    // The step-limit question stands for the old continue card.
    if (stepLimit) dropContinueCard();
    const card = doc.createElement("details");
    card.className = approval ? "bubble question approval" : stepLimit ? "bubble question step-limit" : "bubble question";
    card.dataset.qid = pq.id;
    // What asks (the stage's question room is a model's own question's,
    // stage_view.js): the kind, and a delegate's question relayed here.
    card.dataset.kind = pq.kind || "question";
    if (relayView(pq)) card.dataset.relay = "1";
    const asked = keepsAskingText(pq) ? String(said ?? askingText() ?? "").trim() : "";
    if (asked) saidOf.set(card, asked);
    // Open while pending: the question must be actionable.
    card.open = true;

    // The summary is the card's one line: the question (or its header) while
    // pending, the result once resolved. It replaces the old .question-header.
    const summary = doc.createElement("summary");
    summary.textContent = summaryText(pq);
    card.appendChild(summary);
    // A hand toggle: the resolve's auto-collapse then leaves it as the user
    // left it (rememberToggle-style, as turn_view.js does).
    summary.addEventListener("click", () => { card.dataset.toggled = "1"; });

    // Relayed to the parent: say where else it waits (QuestionDesk#annotate).
    card.appendChild(renderRelayedTo(pq));
    if (approval) {
      card.appendChild(renderApprovalDetails(approval));
    } else {
      // A delegate's hook question relayed here: who asks, then its own text.
      const relay = relayView(pq);
      if (relay) card.appendChild(renderDelegateLine(relay));
      const q = doc.createElement("div");
      q.className = "question-text";
      q.textContent = (relay && pq.relay.asked) || pq.question || "";
      card.appendChild(q);
    }

    const options = Array.isArray(pq.options) ? pq.options : [];
    if (stepLimit) {
      renderStepLimitActions(card, pq, options);
    } else if (options.length) {
      const list = doc.createElement("div");
      list.className = "question-options";
      const inputType = pq.multi_select ? "checkbox" : "radio";
      options.forEach((label, i) => {
        const row = doc.createElement("label");
        row.className = "question-option";
        const input = doc.createElement("input");
        input.type = inputType;
        input.name = `q-${pq.id}`;
        input.value = String(label);
        input.dataset.index = String(i);
        const text = doc.createElement("span");
        text.textContent = String(label);
        row.appendChild(input);
        row.appendChild(text);
        list.appendChild(row);
      });
      card.appendChild(list);
    }

    if (stepLimit) {
      const follow = isNearBottom();
      place(card);
      questionEl = card;
      if (follow) scrollToEnd();
      return;
    }

    let freeformInput = null;
    if (pq.allow_freeform) {
      freeformInput = doc.createElement("input");
      freeformInput.type = "text";
      freeformInput.className = "question-freeform";
      freeformInput.placeholder = approval ? "Reason for the model (with Deny, or alone to deny)…" : "Other…";
      card.appendChild(freeformInput);
    }

    const err = doc.createElement("div");
    err.className = "question-error hidden";
    card.appendChild(err);

    const submit = doc.createElement("button");
    submit.className = "question-submit";
    submit.textContent = "Submit";
    submit.addEventListener("click", () => {
      const chosen = Array.from(card.querySelectorAll(".question-option input:checked")).map((i) => i.value);
      const freeform = freeformInput ? freeformInput.value.trim() : "";
      if (!chosen.length && !freeform) {
        err.textContent = "Pick an option or enter a response.";
        err.classList.remove("hidden");
        return;
      }
      err.classList.add("hidden");
      submit.disabled = true;
      card.classList.add("submitting");
      api.sendAnswer(sessionId(), {
        id: pq.id,
        selected: chosen,
        ...(freeform ? { freeform } : {}),
      }).catch((e) => {
        submit.disabled = false;
        card.classList.remove("submitting");
        err.textContent = answerErrorText(e);
        err.classList.remove("hidden");
      });
    });
    card.appendChild(submit);

    // Leaves the question unanswered, like an empty answer in the terminal.
    // The card closes on the question_cancelled every client gets.
    // For an approval, dismissing denies the call.
    const dismiss = doc.createElement("button");
    dismiss.className = "question-dismiss ghost";
    dismiss.textContent = approval ? "Deny" : "Dismiss";
    dismiss.addEventListener("click", () => {
      err.classList.add("hidden");
      submit.disabled = true;
      dismiss.disabled = true;
      api.dismissQuestion(sessionId(), pq.id).catch((e) => {
        submit.disabled = false;
        dismiss.disabled = false;
        err.textContent = answerErrorText(e);
        err.classList.remove("hidden");
      });
    });
    card.appendChild(dismiss);

    // Enter in the response box or on an option submits (never denies or
    // dismisses: that stays a click).
    card.addEventListener("keydown", (e) => {
      if (!isPlainEnter(e) || submit.disabled) return;
      const t = e.target;
      if (t !== freeformInput && !t?.closest?.(".question-option")) return;
      e.preventDefault();
      submit.click();
    });

    // Read before the card makes the history taller.
    const follow = isNearBottom();
    const staged = place(card) === true;
    questionEl = card;
    if (follow) scrollToEnd();
    focusWhenIdle(card, pq.id, { staged });
  }

  function isPlainEnter(e) {
    return e.key === "Enter" && !e.isComposing && !e.shiftKey && !e.altKey && !e.ctrlKey && !e.metaKey;
  }

  // A new card takes the focus while nobody is typing: the focus is on
  // the page or an empty composer. Checked after the caller is done, so a
  // card drawn already answered (the history replay) never takes it.
  // +staged+: the stage holds the card and scrolls to it once it has grown
  // for it (eased): the focus doesn't scroll, or the stage would snap to the
  // card before its room eases in.
  function focusWhenIdle(card, id, { staged = false } = {}) {
    queueMicrotask(() => {
      if (questionEl !== card || String(pending?.id) !== String(id)) return;
      const prompt = doc.getElementById?.("prompt");
      const active = doc.activeElement;
      const idle = !active || active === doc.body || (active === prompt && !prompt.value);
      if (!idle || (prompt && prompt.value)) return;
      const target = card.querySelector(".question-option input") || card.querySelector(".question-freeform");
      if (staged) target?.focus({ preventScroll: true });
      else target?.focus();
    });
  }

  // The step-limit question's actions: a button per option (Continue,
  // Stop), the reason (it goes with Stop) and no dismiss: the turn waits
  // on one or the other. A Continue with a reason in the box is refused
  // here, as the worker would.
  function renderStepLimitActions(card, pq, options) {
    const reason = doc.createElement("input");
    reason.type = "text";
    reason.className = "question-freeform continue-reason";
    reason.placeholder = CONTINUE_REASON_PLACEHOLDER;
    const err = doc.createElement("div");
    err.className = "question-error hidden";
    const row = doc.createElement("div");
    row.className = "continue-actions";
    const send = (label) => {
      const freeform = label === "Continue" ? "" : reason.value.trim();
      if (label === "Continue" && reason.value.trim()) {
        err.textContent = "Continue takes no reason: clear it, or Stop with it.";
        err.classList.remove("hidden");
        return;
      }
      err.classList.add("hidden");
      card.querySelectorAll("button, input").forEach((el) => { el.disabled = true; });
      card.classList.add("submitting");
      api.sendAnswer(sessionId(), { id: pq.id, selected: [label], ...(freeform ? { freeform } : {}) }).catch((e) => {
        card.querySelectorAll("button, input").forEach((el) => { el.disabled = false; });
        card.classList.remove("submitting");
        err.textContent = answerErrorText(e);
        err.classList.remove("hidden");
      });
    };
    options.forEach((label, i) => {
      const button = doc.createElement("button");
      button.className = i === 0 ? "question-choice continue-yes" : "question-choice continue-no ghost";
      button.dataset.value = String(label);
      button.textContent = String(label);
      button.addEventListener("click", () => send(String(label)));
      row.appendChild(button);
    });
    if (pq.allow_freeform) row.appendChild(reason);
    card.appendChild(row);
    card.appendChild(err);
  }

  // "delegate ab12 · its task", the name linked to its session (a relayed
  // approval's or hook question's; relayView).
  function renderDelegateLine(delegate) {
    const who = doc.createElement("div");
    who.className = "approval-delegate";
    const label = doc.createElement("span");
    label.className = "approval-label";
    label.textContent = "delegate ";
    who.appendChild(label);
    const name = doc.createElement("a");
    name.className = "approval-delegate-link";
    name.href = sessionHash(delegate.childId);
    name.title = "Open the delegate's session";
    name.textContent = delegate.who;
    who.appendChild(name);
    if (delegate.task) who.appendChild(doc.createTextNode(` · ${delegate.task}`));
    return who;
  }

  // The tool, the command (or paths, or args) as code, where and why; no
  // code box when there is nothing to show.
  function renderApprovalDetails(view) {
    const box = doc.createElement("div");
    box.className = "approval-details";
    // A delegate's approval: who asks, and its task.
    if (view.delegate) box.appendChild(renderDelegateLine(view.delegate));
    const tool = doc.createElement("div");
    tool.className = "approval-tool";
    tool.textContent = view.tool;
    box.appendChild(tool);
    if (view.what) {
      const what = doc.createElement("pre");
      what.className = view.isCommand ? "approval-what command" : "approval-what paths";
      const code = doc.createElement("code");
      if (view.paths) appendPathRefs(code, view.paths);
      else code.textContent = view.what;
      what.appendChild(code);
      box.appendChild(what);
    }
    // An edit/write: the diff it would make, under the path.
    if (view.preview) {
      const diff = doc.createElement("div");
      diff.className = "approval-diff";
      render(diffTemplate(view.preview), diff);
      box.appendChild(diff);
    }
    for (const [cls, label, text] of [["approval-where", "in", view.where], ["approval-why", "why", view.why]]) {
      if (!text) continue;
      const row = doc.createElement("div");
      row.className = cls;
      const b = doc.createElement("span");
      b.className = "approval-label";
      b.textContent = `${label} `;
      row.appendChild(b);
      row.appendChild(doc.createTextNode(text));
      box.appendChild(row);
    }
    return box;
  }

  // One file ref per path, a line each (refs.js: the card's path opens
  // the current file at the dry run's first change). A directory (a
  // plugin's path ending in /) stays plain text.
  function appendPathRefs(code, paths) {
    paths.forEach((path, i) => {
      if (i) code.appendChild(doc.createTextNode("\n"));
      if (String(path).endsWith("/")) {
        code.appendChild(doc.createTextNode(String(path)));
        return;
      }
      const ref = doc.createElement("span");
      ref.className = "ref";
      ref.dataset.refKind = "file";
      ref.dataset.refPath = String(path);
      ref.textContent = String(path);
      code.appendChild(ref);
    });
  }

  // "Waiting for approval in parent ab12: answering here works too", or
  // an empty (hidden) line while the question isn't relayed.
  function renderRelayedTo(pq) {
    const line = doc.createElement("div");
    line.className = "question-relayed";
    const view = relayedToView(pq);
    if (!view) {
      line.classList.add("hidden");
      return line;
    }
    line.appendChild(doc.createTextNode(`Waiting for ${pq.kind === "approval" ? "approval" : "an answer"} in parent `));
    const link = doc.createElement("a");
    link.href = sessionHash(view.parentId);
    link.textContent = view.parentShort;
    line.appendChild(link);
    line.appendChild(doc.createTextNode(": answering here works too"));
    return line;
  }

  // The parent relayed the open question, or no longer does (question_relay).
  function markRelayed(id, relayedTo) {
    if (!questionEl || !pending || String(pending.id) !== String(id)) return;
    pending = { ...pending, relayed_to: relayedTo || null };
    questionEl.querySelector(".question-relayed")?.replaceWith(renderRelayedTo(pending));
  }

  function resolveQuestionCard(id, { answer = null, cancelled = false, reason = "" } = {}) {
    if (!questionEl) return;
    if (id && pending && String(pending.id) !== String(id)) return;
    // A double-delivered question_answered / question_cancelled (SSE replay
    // after a reconnect) is a no-op: the card is already resolved.
    if (questionEl.classList.contains("answered") || questionEl.classList.contains("cancelled")
      || questionEl.querySelector(".question-result")) return;

    const result = resultText(pending, { answer, cancelled, reason });
    const note = doc.createElement("div");
    note.className = "question-result";
    note.textContent = result;
    // N1: an approval's verdict goes before its command block, not after it:
    // with the details expanded the command reads like another tool call.
    const allowed = approvalAllowed(pending, answer);
    if (allowed !== null) note.classList.add("verdict");
    if (cancelled) {
      questionEl.classList.add("cancelled");
    } else {
      questionEl.classList.add("answered");
      if (allowed === false) questionEl.classList.add("denied");
      markQuestionSelection(answer && Array.isArray(answer.selected) ? answer.selected : []);
    }
    const before = allowed !== null ? questionEl.querySelector(".approval-details") : null;
    if (before) questionEl.insertBefore(note, before);
    else questionEl.appendChild(note);
    questionEl.classList.remove("submitting");
    disableQuestionInputs();
    questionEl.querySelector(".question-relayed")?.classList.add("hidden");
    // The summary becomes the result; the card collapses to that one line
    // unless the user opened or closed it by hand.
    const summary = questionEl.querySelector("summary");
    if (summary) summary.textContent = summaryText(pending, { answer, cancelled, reason });
    // The reply that asked, kept with the card: what made the question
    // answerable stays with it in the history. Muted under the "Q → A" line
    // in two lines while the card is closed (a copy screen readers skip: not
    // the toggle's label; plain text, plain_line.js: no "##" or "**" in a
    // clamped line), and whole, selectable, at the top of the body
    // when it is open (a drag in the summary would toggle the card).
    const asked = saidOf.get(questionEl);
    let full = null;
    if (summary && asked) {
      const line = doc.createElement("div");
      line.className = "question-said";
      line.setAttribute("aria-hidden", "true");
      line.textContent = plainText(asked);
      summary.appendChild(line);
      full = doc.createElement("div");
      full.className = "question-said-full";
      full.textContent = asked;
      questionEl.insertBefore(full, summary.nextSibling);
    }
    // 4.02: a reopened card's summary already carries the result (the
    // snapshot re-renders it resolved), and the body line repeats it. It
    // stays for a hand-toggled card, whose expanded body the user looks at,
    // and for a deny with a reason: the summary says only "Denied".
    const keepNote = questionEl.dataset.toggled || (!cancelled && deniedReason(pending, answer));
    if (summary && !keepNote) note.classList.add("hidden");
    if (!questionEl.dataset.toggled) questionEl.open = false;
    // After the collapse: a card left open by hand renders at once.
    if (full) renderSaidOnOpen(questionEl, full, asked);
    pending = null;
  }

  // The body's copy as markdown, from the card's first open on (a reload
  // draws every card in the history: rendering them all would ask once per
  // card). Raw until then, and when the render answers null (then the next
  // open asks again).
  function renderSaidOnOpen(card, full, asked) {
    let state = "raw";
    const draw = () => {
      if (!card.open || state !== "raw") return;
      state = "asking";
      Promise.resolve()
        .then(() => renderMarkdown(asked))
        .catch(() => null)
        .then((html) => {
          if (!html) { state = "raw"; return; }
          state = "done";
          // Sanitised on the server (POST /api/render).
          full.innerHTML = html;
          full.classList.add("markdown", "md-compact");
          linkRefs(full);
        });
    };
    card.addEventListener("toggle", draw);
    draw();
  }

  function markQuestionSelection(sel) {
    if (!questionEl || !sel.length) return;
    questionEl.querySelectorAll(".question-choice").forEach((button) => {
      if (sel.includes(button.dataset.value)) button.classList.add("selected");
    });
    questionEl.querySelectorAll(".question-option input").forEach((input) => {
      if (sel.includes(input.value)) {
        input.checked = true;
        input.closest(".question-option").classList.add("selected");
      }
    });
  }

  function disableQuestionInputs() {
    if (!questionEl) return;
    questionEl.querySelectorAll("input, button").forEach((el) => {
      el.disabled = true;
    });
  }

  function removeQuestionCard() {
    if (questionEl) {
      questionEl.remove();
      questionEl = null;
    }
    pending = null;
  }

  // ── continue card ──────────────────────────────────────────────────────────
  // A turn ran out of iterations: continue it, drop it, or drop it saying why
  // (the terminal's continue prompt). Answers go as /continue commands; the
  // card closes on the continue_resolved every client gets.

  const CONTINUE_DECISIONS = {
    resume: "Continued",
    abort: "Not continued",
    abort_with_reason: "Not continued (reason noted)",
    dropped: "Dropped: a new prompt came",
  };

  // The old card goes: the step-limit question asks the same (a worker that
  // posts it announces continue_offered too, for older pages).
  function dropContinueCard() {
    continueEl?.remove();
    continueEl = null;
  }

  function renderContinueCard(offer) {
    if (continueEl?.isConnected) return;
    // A step-limit question is up: it is the card (an older worker has none).
    if (isContinue(pending)) return;
    removeHintIfEmpty();
    const card = doc.createElement("div");
    card.className = "bubble continue";
    const text = doc.createElement("div");
    text.className = "continue-text";
    text.textContent = "The turn ran out of iterations. Continue it?";
    card.appendChild(text);
    const task = offer?.context?.original_prompt;
    if (task) {
      const ctx = doc.createElement("div");
      ctx.className = "continue-context";
      ctx.textContent = task;
      card.appendChild(ctx);
    }
    const err = doc.createElement("div");
    err.className = "question-error hidden";
    const answer = (line) => {
      err.classList.add("hidden");
      card.querySelectorAll("button, input").forEach((el) => { el.disabled = true; });
      api.sendCommand(sessionId(), line, { clientId }).catch((e) => {
        card.querySelectorAll("button, input").forEach((el) => { el.disabled = false; });
        err.textContent = e.message;
        err.classList.remove("hidden");
      });
    };
    const yes = doc.createElement("button");
    yes.className = "continue-yes";
    yes.textContent = "Yes";
    yes.addEventListener("click", () => answer(continueLine("yes")));
    const no = doc.createElement("button");
    no.className = "continue-no ghost";
    no.textContent = "No";
    no.addEventListener("click", () => answer(continueLine("no")));
    const reason = doc.createElement("input");
    reason.type = "text";
    reason.className = "continue-reason";
    reason.placeholder = "Why not? (the model reads it)";
    const noBecause = doc.createElement("button");
    noBecause.className = "continue-no-reason ghost";
    noBecause.textContent = "No, because…";
    noBecause.addEventListener("click", () => {
      if (!reason.value.trim()) return reason.focus();
      answer(continueLine("no", reason.value));
    });
    const row = doc.createElement("div");
    row.className = "continue-actions";
    [yes, no, reason, noBecause].forEach((el) => row.appendChild(el));
    card.appendChild(row);
    card.appendChild(err);
    const follow = isNearBottom();
    place(card);
    continueEl = card;
    if (follow) scrollToEnd();
  }

  function resolveContinueCard(data) {
    const card = continueEl;
    continueEl = null;
    if (!card) return;
    card.classList.add("resolved");
    card.querySelectorAll("button, input").forEach((el) => { el.disabled = true; });
    const note = doc.createElement("div");
    note.className = "question-result";
    const who = isOwn(data.client_id, clientId) ? "" : ` (${clientLabel(data.client_id) || "another client"})`;
    note.textContent = (CONTINUE_DECISIONS[data.decision] || data.decision || "Answered") + who;
    card.appendChild(note);
  }

  return {
    renderQuestion: renderQuestionCard,
    resolveQuestion: resolveQuestionCard,
    markRelayed,
    removeQuestion: removeQuestionCard,
    questionCard: () => questionEl,
    pendingQuestion: () => pending,
    renderContinue: renderContinueCard,
    resolveContinue: resolveContinueCard,
    // The turn view was reset: a later offer draws a new card.
    forgetContinue() { continueEl = null; },
  };
}
