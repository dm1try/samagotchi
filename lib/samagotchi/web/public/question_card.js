// What a question card shows, apart from the DOM. An approval (kind
// "approval", from the tool guardrails) gets its own view: the tool, the
// command or paths, where and why. Its options end in "Deny"; the answer's
// last option denies. A page that doesn't know approvals still shows the
// plain question text, which says the same.

export function isApproval(pq) {
  return !!pq && pq.kind === "approval";
}

// @return {null | {tool, what, isCommand, where, why}}
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
  };
}

// The line a resolved card shows.
export function resultText(pq, { answer = null, cancelled = false, reason = "" } = {}) {
  const approval = isApproval(pq);
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
    const asked = summaryAsked(pq);
    return truncate(asked ? `${truncate(asked, 60)} → ${result}` : result, 120);
  }
  const label = isApproval(pq) ? `Approve ${pq.approval?.label || pq.approval?.tool || "call"}?` : "Question";
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
