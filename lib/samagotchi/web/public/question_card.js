// What a question card shows, apart from the DOM. An approval (kind
// "approval", from the tool guardrails) gets its own view: the tool, the
// command or paths, where and why. Its options end in "Deny"; the answer's
// last option denies. A page that doesn't know approvals still shows the
// plain question text, which says the same.

export function isApproval(pq) {
  return !!pq && pq.kind === "approval";
}

// The step-limit question (kind "continue"): a turn ran out of iterations.
// Its card has a button per option (Continue, Stop) and a reason that goes
// with Stop; it can't be dismissed.
export function isContinue(pq) {
  return !!pq && pq.kind === "continue";
}

export const CONTINUE_REASON_PLACEHOLDER = "Stop, because… (the model reads it)";

// Why a step-limit question closed unanswered (its question_cancelled reason).
const CONTINUE_CLOSED = {
  dropped: "Dropped: a new prompt came",
  answered: "Answered with /continue",
  superseded: "Set aside for another question",
  replaced: "Asked again",
};

// A delegate's approval relayed to this session's user (the approval
// relay): who asks (the chain, "ab12 → cd34" for a grandchild's) and its
// task, or null.
// @return {null | {who, childId, childShort, task, more}}
export function relayView(pq) {
  const r = pq && pq.relay;
  if (!r || typeof r !== "object" || !r.child_id) return null;
  const chain = Array.isArray(r.chain) && r.chain.length ? r.chain : [String(r.child_id).slice(0, 8)];
  return {
    who: [...chain].reverse().join(" → "),
    childId: String(r.child_id),
    childShort: r.child_short || String(r.child_id).slice(0, 8),
    task: r.task ? String(r.task) : "",
    more: Number(r.more) || 0,
  };
}

// @return {null | {tool, what, isCommand, where, why, preview?, delegate?}};
// preview is an edit/write's dry-run diff (diff_view.js draws it); delegate
// is relayView's, for a delegate's approval
export function approvalView(pq) {
  if (!isApproval(pq)) return null;
  const a = pq.approval || {};
  const paths = Array.isArray(a.paths) ? a.paths : [];
  const command = a.command || null;
  let where = a.cwd || "";
  if (a.repo_root) {
    const repo = String(a.repo_root).split("/").filter(Boolean).pop() || a.repo_root;
    where += ` (repo ${repo}${a.branch ? `, branch ${a.branch}` : ""})`;
  } else if (where) {
    where += " (not in a repo)";
  }
  const who = a.rule ? [`rule ${a.rule}`, a.source].filter(Boolean).join(", ") : (a.source || "hook");
  const reason = a.reason ? String(a.reason) : "(no reason given)";
  return {
    // A plugin tool's label ("chrome: screenshot"), as its row shows it.
    tool: a.label || a.tool || "",
    // A tool without a command or path (an MCP tool): its compact args.
    what: command || paths.join("\n") || a.args || "",
    isCommand: !!command,
    where,
    why: `${reason} (${who})`,
    ...(a.preview && typeof a.preview === "object" ? { preview: a.preview } : {}),
    ...(relayView(pq) ? { delegate: relayView(pq) } : {}),
  };
}

// This session's question waits in its parent's card too (the parent
// relayed it): the parent's id and short id, or null.
// @return {null | {parentId, parentShort}}
export function relayedToView(pq) {
  const r = pq && pq.relayed_to;
  if (!r || typeof r !== "object" || !r.parent_id) return null;
  return { parentId: String(r.parent_id), parentShort: r.parent_short || String(r.parent_id).slice(0, 8) };
}

// How a relayed approval's card closed without an answer here: the
// delegate's question was answered there, its worker went, or this turn
// stopped (the question still waits in the delegate). A dismiss here
// denied it.
function relayClosedText(relay, reason) {
  if (reason === "answered_on_child") return `Answered in ${relay.who}`;
  if (reason === "child_gone") return `${relay.who}'s worker is gone`;
  return reason ? `Left open in ${relay.who} (${reason})` : `Left open in ${relay.who}`;
}

// The line a resolved card shows.
export function resultText(pq, { answer = null, cancelled = false, reason = "" } = {}) {
  const approval = isApproval(pq);
  const relay = relayView(pq);
  if (cancelled && relay && reason !== "dismissed") return relayClosedText(relay, reason);
  if (isContinue(pq)) return continueResultText({ answer, cancelled, reason });
  if (cancelled) {
    const label = approval ? "Denied" : "Cancelled";
    return reason ? `${label} (${reason})` : label;
  }
  const sel = answer && Array.isArray(answer.selected) ? answer.selected : [];
  const freeform = answer && answer.freeform ? String(answer.freeform) : "";
  if (approval) {
    const options = Array.isArray(pq.options) ? pq.options : [];
    const denied = !sel.length || sel[0] === options[options.length - 1];
    if (denied) return freeform ? `Denied: ${freeform}` : "Denied";
    return `Allowed: ${sel[0]}`;
  }
  const parts = [];
  if (sel.length) parts.push(sel.join(", "));
  if (freeform) parts.push(freeform);
  return parts.length ? `Answered: ${parts.join(" · ")}` : "Answered";
}

function continueResultText({ answer, cancelled, reason }) {
  if (cancelled) return CONTINUE_CLOSED[reason] || (reason ? `Closed (${reason})` : "Closed");
  const sel = answer && Array.isArray(answer.selected) ? answer.selected : [];
  const freeform = answer && answer.freeform ? String(answer.freeform) : "";
  if (sel[0] === "Continue") return "Continued";
  return freeform ? `Stopped: ${freeform}` : "Stopped";
}

// Shorten a line of text for the card's summary (the collapsed one-liner).
export function truncate(text, n = 80) {
  const s = String(text ?? "");
  return s.length > n ? `${s.slice(0, n - 1)}…` : s;
}

// The card's summary line: while pending its header, else a label (the
// question itself is in the body, so it isn't repeated here); once resolved
// what was asked and the result, "Which file? → README.md" (an approval
// asks its tool and command: "execute: rm -rf tmp → Denied").
export function summaryText(pq, { answer = null, cancelled = false, reason = "" } = {}) {
  if (cancelled || answer) {
    const result = resultText(pq, { answer, cancelled, reason }).replace(/^Answered: /, "");
    const relay = relayView(pq);
    const asked = summaryAsked(pq);
    const text = asked ? `${truncate(asked, 60)} → ${result}` : result;
    return truncate(relay ? `${relay.who}: ${text}` : text, 120);
  }
  const label = isApproval(pq) ? `Approve ${pq.approval?.label || pq.approval?.tool || "call"}?`
    : isContinue(pq) ? "Step limit" : "Question";
  return truncate(pq.header || label);
}

function summaryAsked(pq) {
  const view = approvalView(pq);
  if (view) {
    const what = String(view.what || "").split("\n")[0];
    return [view.tool, what].filter(Boolean).join(": ");
  }
  return String(pq.question || pq.header || "").split("\n")[0];
}

// Whether the answer allowed the call (the card turns green) or denied it.
export function approvalAllowed(pq, answer) {
  if (!isApproval(pq)) return null;
  return resultText(pq, { answer }).startsWith("Allowed");
}

// What a new question does to the card on the page: "same" (the card
// already shows it: a replay), "keep" (the card is resolved, so it stays in
// the history and the new one goes under it), "replace" (the card is still
// pending, or there is none).
export function nextCardAction({ cardId = null, pendingId = null } = {}, incoming) {
  if (cardId != null && String(cardId) === String(incoming?.id)) return "same";
  if (cardId != null && pendingId == null) return "keep";
  return "replace";
}
