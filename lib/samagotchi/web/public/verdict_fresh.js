// Verify fresh on a verdict card, both pages (docs/internals/participants.md,
// Verify fresh): an unclear verdict's card offers a new agent that checks the
// claim with none of the session's context; while it runs the card says so
// (the owner's links to its session), and its verdict lands on the same card
// as a "fresh:" line. A module of its own: static JS is cached at unversioned
// URLs, and a new export on an old module would blank the page.

import { placeVerdict } from "./verdict_card.js";

const ICONS = Object.freeze({ confirmed: "✅", refuted: "❌", unclear: "❓" });

// The request that starts one (owner and participant alike).
export function freshURL(sessionId, checkTurnId) {
  return `/api/sessions/${encodeURIComponent(sessionId)}/verdicts/${encodeURIComponent(checkTurnId)}/fresh`;
}

// A running entry's verdict: the participant's are its check_turn_id, the
// owner's {of, child_id}.
function runningOf(entry) {
  return typeof entry === "string" ? entry : entry?.of;
}

// +running+ without the check a fresh verdict just ended (+record+).
export function settleRunning(running, record) {
  if (!record?.fresh) return running || [];
  return (running || []).filter((entry) => runningOf(entry) !== record.of);
}

// Places a session verdict as the pages draw them: an original verdict's
// card (verdict_card.js) with its Verify fresh part, or a fresh verdict on
// its original's card. +fresh+: {verdicts (all of the session's), running
// (the page's own array; a start adds to it), errors (the page's own
// object, check id → the last start error, so a redraw shows it again), canStart, start(of) → Promise
// of {ok, child_id, error}, childHref(id) → a link to the child or null}.
export function placeVerdictWithFresh(root, record, opts = {}, fresh = {}) {
  if (record?.fresh) {
    const card = [...(root?.querySelectorAll?.(".verify-verdict") || [])]
      .find((candidate) => candidate.dataset.checkTurnId === record.of);
    if (card) renderFresh(card, fresh);
    return card || null;
  }
  const card = placeVerdict(root, record, opts);
  if (card) renderFresh(card, fresh);
  return card;
}

// Every verdict card under +root+ drawn again from +fresh+ (the gate changed).
export function redrawFresh(root, fresh = {}) {
  for (const card of root?.querySelectorAll?.(".verify-verdict") || []) renderFresh(card, fresh);
}

// The card's Verify fresh part, drawn again from +fresh+: the fresh
// verdicts, the running check, else the button (an unclear verdict, and a
// viewer who could run a turn now; "Verify fresh again" after a fresh
// verdict, each press another paid check).
export function renderFresh(card, fresh = {}) {
  const doc = card.ownerDocument;
  const of = card.dataset.checkTurnId;
  card.querySelector(":scope > .verify-fresh")?.remove();
  const part = doc.createElement("div");
  part.className = "verify-fresh";
  const childLink = (id) => {
    const href = id && fresh.childHref ? fresh.childHref(id) : null;
    if (!href) return null;
    const link = doc.createElement("a");
    link.className = "verify-fresh-link";
    link.href = href;
    link.textContent = "open its session";
    return link;
  };

  const results = (fresh.verdicts || []).filter((r) => r?.fresh && r.of === of);
  // Once a fresh verdict is in, the button says a press runs another one.
  const label = results.length ? "Verify fresh again" : "Verify fresh";
  for (const result of results) {
    const line = doc.createElement("p");
    line.className = `verify-fresh-result ${ICONS[result.verdict] ? result.verdict : ""}`.trim();
    line.textContent = `fresh: ${ICONS[result.verdict] || ""} ${result.verdict} — ${result.reason || ""}`;
    const link = childLink(result.child_id);
    if (link) line.append(" · ", link);
    part.append(line);
  }

  const run = (fresh.running || []).find((entry) => runningOf(entry) === of);
  if (run) {
    const line = doc.createElement("p");
    line.className = "verify-fresh-running";
    line.textContent = "Verifying fresh…";
    const link = childLink(typeof run === "string" ? null : run.child_id);
    if (link) line.append(" ", link);
    part.append(line);
  } else if (card.classList.contains("unclear") && fresh.unavailableReason) {
    const button = doc.createElement("button");
    button.type = "button";
    button.className = "verify-fresh-btn";
    button.textContent = label;
    button.title = fresh.unavailableReason;
    button.disabled = true;
    const note = doc.createElement("p");
    note.className = "verify-fresh-unavailable";
    note.textContent = fresh.unavailableReason;
    part.append(button, note);
  } else if (card.classList.contains("unclear") && fresh.canStart && fresh.start) {
    const button = doc.createElement("button");
    button.type = "button";
    button.className = "verify-fresh-btn";
    button.textContent = label;
    button.title = "A new agent checks this claim against the files, with none of this session's context";
    button.addEventListener("click", () => startFresh(card, button, fresh));
    part.append(button);
  }

  const error = (fresh.errors ||= {})[of];
  if (error) {
    const line = doc.createElement("p");
    line.className = "verify-fresh-error";
    line.textContent = error;
    part.append(line);
  }
  if (part.childNodes.length) card.append(part);
}

async function startFresh(card, button, fresh) {
  const of = card.dataset.checkTurnId;
  button.disabled = true;
  button.textContent = "Starting…";
  let result;
  try {
    result = await fresh.start(of);
  } catch (error) {
    result = { ok: false, error: error?.message };
  }
  if (result?.ok) {
    if (fresh.errors) delete fresh.errors[of];
    // In place, on purpose: on the owner page fresh.running is the session
    // store's verifyFresh (session_fields.js, D8).
    if (fresh.running && !fresh.running.some((entry) => runningOf(entry) === of)) {
      fresh.running.push(result.child_id ? { of, child_id: result.child_id } : of);
    }
  } else {
    (fresh.errors ||= {})[of] = result?.error || "Couldn't start a fresh check.";
  }
  renderFresh(card, fresh);
}
