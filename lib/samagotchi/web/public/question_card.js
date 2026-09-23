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
    tool: a.tool || "",
    what: command || paths.join("\n"),
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

// Whether the answer allowed the call (the card turns green) or denied it.
export function approvalAllowed(pq, answer) {
  if (!isApproval(pq)) return null;
  return resultText(pq, { answer }).startsWith("Allowed");
}
