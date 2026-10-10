import test from "node:test";
import assert from "node:assert/strict";
import { isApproval, approvalView, relayView, resultText, approvalAllowed, answerErrorText, nextCardAction, summaryText, truncate } from "../../../lib/samagotchi/web/public/question_card.js";

const approval = {
  id: "a1",
  kind: "approval",
  header: "Approve tool call?",
  question: "execute: git push\n  in /r/app (repo app, branch main)\n  why: pushes (rule git-push, config)",
  options: ["Allow once", "Allow this call in this repo", "Deny"],
  approval: {
    tool: "execute", command: "git push", cwd: "/r/app", repo_root: "/r/app", branch: "main",
    rule: "git-push", source: "config", reason: "pushes", scopes: ["once", "repo"],
  },
};

test("isApproval tells approvals from ask_user_question", () => {
  assert.equal(isApproval(approval), true);
  assert.equal(isApproval({ id: "q", question: "Pick" }), false);
  assert.equal(isApproval(null), false);
});

test("approvalView shows the command, where and why", () => {
  assert.deepEqual(approvalView(approval), {
    tool: "execute", what: "git push", isCommand: true,
    where: "/r/app (repo app, branch main)", why: "pushes (rule git-push, config)",
  });
});

test("approvalView names the repository (repo_name), not the worktree's folder", () => {
  const pq = { ...approval, approval: { ...approval.approval, cwd: "/r/app-wt", repo_root: "/r/app-wt", repo_name: "app" } };
  assert.equal(approvalView(pq).where, "/r/app-wt (repo app, branch main)");
});

test("a plugin tool's approval names it by its label, as its row does", () => {
  const pq = {
    kind: "approval", header: "",
    approval: { tool: "save_note", label: "saving note", paths: ["/r/secret.md"], cwd: "/r", reason: "secret" },
  };
  assert.equal(approvalView(pq).tool, "saving note");
  assert.equal(summaryText(pq), "Approve saving note?");
  assert.equal(summaryText(pq, { answer: { selected: ["Allow once"] } }), "saving note: /r/secret.md → Allowed: Allow once");
});

test("a call that acts as another tool is named by its label, else by that tool", () => {
  const pq = (extra) => ({
    kind: "approval", header: "",
    approval: { tool: "mcp_call", acts_as: "mcp_github_x", args: "owner=me", cwd: "/r", reason: "mcp", ...extra },
  });
  assert.equal(approvalView(pq({ label: "github: x" })).tool, "github: x");
  assert.equal(approvalView(pq({})).tool, "mcp_github_x");
  assert.equal(summaryText(pq({})), "Approve mcp_github_x?");
});

test("approvalView: a tool without a command or path shows its args, or nothing", () => {
  const pq = (approval) => ({ kind: "approval", approval: { tool: "mcp_x_echo", cwd: "/r", reason: "mcp", ...approval } });
  const withArgs = approvalView(pq({ args: "message=\"hi\" n=3" }));
  assert.equal(withArgs.what, "message=\"hi\" n=3");
  assert.equal(withArgs.isCommand, false);
  assert.equal(approvalView(pq({})).what, "");
  assert.equal(summaryText(pq({}), { answer: { selected: ["Allow once"] } }), "mcp_x_echo → Allowed: Allow once");
});

test("approvalView lists paths outside a repo and names a hook", () => {
  const view = approvalView({
    kind: "approval",
    approval: { tool: "write", paths: ["/tmp/a", "/tmp/b"], cwd: "/tmp", reason: "outside" },
  });
  assert.equal(view.what, "/tmp/a\n/tmp/b");
  assert.equal(view.isCommand, false);
  assert.equal(view.where, "/tmp (not in a repo)");
  assert.equal(view.why, "outside (hook)");
});

test("approvalView is null for a plain question", () => {
  assert.equal(approvalView({ id: "q" }), null);
});

test("resultText for approvals: allowed, denied, denied with a reason, dismissed", () => {
  assert.equal(resultText(approval, { answer: { selected: ["Allow this call in this repo"] } }), "Allowed: Allow this call in this repo");
  assert.equal(resultText(approval, { answer: { selected: ["Deny"] } }), "Denied");
  assert.equal(resultText(approval, { answer: { selected: ["Deny"], freeform: "use a PR" } }), "Denied: use a PR");
  assert.equal(resultText(approval, { answer: { selected: [], freeform: "not now" } }), "Denied: not now");
  assert.equal(resultText(approval, { cancelled: true, reason: "dismissed" }), "Denied (dismissed)");
  assert.equal(approvalAllowed(approval, { selected: ["Allow once"] }), true);
  assert.equal(approvalAllowed(approval, { selected: ["Deny"] }), false);
});

test("resultText for questions is unchanged", () => {
  const q = { id: "q", options: ["A", "B"] };
  assert.equal(resultText(q, { answer: { selected: ["A"], freeform: "x" } }), "Answered: A · x");
  assert.equal(resultText(q, { cancelled: true }), "Cancelled");
  assert.equal(resultText(q, { cancelled: true, reason: "dismissed" }), "Cancelled (dismissed)");
  assert.equal(approvalAllowed(q, { selected: ["A"] }), null);
});

test("resultText: a question closed in a non-interactive run says no one could answer, in words", () => {
  const plain = "No one could answer (non-interactive run)";
  assert.equal(resultText({ question: "Which?", options: ["A", "B"] }, { cancelled: true, reason: "non_interactive" }), plain);
  assert.equal(resultText(approval, { cancelled: true, reason: "non_interactive" }), plain);
  assert.equal(resultText({ kind: "continue", options: ["Continue", "Stop"] }, { cancelled: true, reason: "non_interactive" }), plain);
});

// 4.27: only a 503 (no live bridge) means the session isn't running; any
// other failure shows what the server or the worker said.
test("answerErrorText: 503 says restart, anything else shows the detail", () => {
  const err = (message, status, code) => Object.assign(new Error(message), status ? { status } : {}, code ? { code } : {});
  assert.equal(answerErrorText(err("no live bridge for session s1 (503)", 503)), "Session is not running — restart it to answer.");
  // The status alone is enough: the message needn't spell it out.
  assert.equal(answerErrorText(err("no live bridge for session s1", 503)), "Session is not running — restart it to answer.");
  // The server's code says it too; the message's words don't.
  assert.equal(answerErrorText(err("gone", null, "not_live")), "Session is not running — restart it to answer.");
  assert.equal(answerErrorText(err("not_live here (502)", 502)), "not_live here (502)");
  assert.equal(answerErrorText(err("the question desk raised (502)", 502)), "the question desk raised (502)");
  assert.equal(answerErrorText(err("question already answered (409)", 409)), "question already answered (409)");
  assert.equal(answerErrorText(err("Failed to fetch")), "Failed to fetch");
});

test("summaryText pending: header, else a label (the question is in the body)", () => {
  assert.equal(summaryText({ id: "q", header: "Pick a lane", question: "Which lane?" }), "Pick a lane");
  assert.equal(summaryText({ id: "q", question: "Which lane?" }), "Question");
  assert.equal(summaryText({ id: "a", kind: "approval", approval: { tool: "execute" } }), "Approve execute?");
  assert.equal(summaryText({ id: "a", kind: "approval" }), "Approve call?");
  assert.equal(summaryText({ id: "q" }), "Question");
});

test("summaryText resolved: answered, denied, cancelled with reason", () => {
  const q = { id: "q", question: "Which lane?", options: ["A", "B"] };
  assert.equal(summaryText(q, { answer: { selected: ["A"], freeform: "x" } }), "Which lane? → A · x");
  assert.equal(summaryText(q, { cancelled: true }), "Which lane? → Cancelled");
  assert.equal(summaryText(q, { cancelled: true, reason: "turn ended" }), "Which lane? → Cancelled (turn ended)");
  assert.equal(summaryText(approval, { answer: { selected: ["Allow once"] } }), "execute: git push → Allowed: Allow once");
  assert.equal(summaryText(approval, { answer: { selected: ["Deny"], freeform: "use a PR" } }), "execute: git push → Denied");
  assert.equal(summaryText(approval, { cancelled: true, reason: "dismissed" }), "execute: git push → Denied (dismissed)");
});

// A deny's typed reason goes in the card body, not the summary line: a long
// one cut at 120 chars crowded out the command.
test("summaryText resolved: a denied approval's summary drops the typed reason", () => {
  const reason = "Denied (coordinator): checkout drops the CHANGELOG edits; ".repeat(4);
  assert.equal(summaryText(approval, { answer: { selected: ["Deny"], freeform: reason } }), "execute: git push → Denied");
  assert.equal(summaryText(approval, { answer: { selected: [], freeform: "not now" } }), "execute: git push → Denied");
  assert.equal(summaryText(approval, { answer: { selected: ["Deny"] } }), "execute: git push → Denied");
});

test("summaryText resolved: a long question is cut so the result stays", () => {
  const s = summaryText({ id: "q", question: "y".repeat(200) }, { answer: { selected: ["A"] } });
  assert.ok(s.endsWith("… → A"));
  assert.equal(summaryText({ id: "q" }, { answer: { selected: ["A"] } }), "A");
});

test("summaryText truncates long lines at 80 chars", () => {
  const long = "x".repeat(120);
  const s = summaryText({ id: "q", header: long });
  assert.equal(s.length, 80);
  assert.ok(s.endsWith("…"));
  assert.equal(summaryText({ id: "q", header: "short" }), "short");
  assert.equal(truncate("abcdef", 3), "ab…");
  assert.equal(truncate("abc", 3), "abc");
  assert.equal(truncate(null), "");
});

// A resolved card stays in the history (as the terminal's scrollback keeps
// every question); only a still-pending one is replaced.
test("nextCardAction: same card, keep a resolved one, replace a pending one", () => {
  assert.equal(nextCardAction({ cardId: null, pendingId: null }, { id: "q1" }), "replace");
  assert.equal(nextCardAction({ cardId: "q1", pendingId: "q1" }, { id: "q1" }), "same");
  assert.equal(nextCardAction({ cardId: "q1", pendingId: "q1" }, { id: "q2" }), "replace");
  assert.equal(nextCardAction({ cardId: "q1", pendingId: null }, { id: "q2" }), "keep");
  // A replay of the question the resolved card shows draws no second card.
  assert.equal(nextCardAction({ cardId: "q1", pendingId: null }, { id: "q1" }), "same");
  assert.equal(nextCardAction({ cardId: 7, pendingId: null }, { id: "7" }), "same");
});

test("approvalView passes an edit's dry-run diff on as preview, and adds nothing without one", () => {
  const preview = { text: "@@ -1 +1 @@\n-a\n+b", added: 1, removed: 1, truncated: false, new_file: false };
  const edit = { ...approval, approval: { ...approval.approval, tool: "edit", command: undefined, paths: ["/x/kitty.conf"], preview } };
  assert.deepEqual(approvalView(edit).preview, preview);
  assert.equal(approvalView(edit).what, "/x/kitty.conf");
  assert.equal("preview" in approvalView(approval), false);
});

const relayed = {
  ...approval,
  id: "a2",
  header: "Approve delegate ab12cd34's tool call?",
  question: "delegate ab12cd34 (\"fix it\") asks:\n  execute: git push",
  relay: { id: "r1", child_id: "ab12cd34-0000", child_short: "ab12cd34", child_question_id: "q1", task: "fix it", chain: ["ab12cd34"], more: 0 },
};

test("a delegate's approval shows who asks and its task; a grandchild's names the chain", () => {
  assert.deepEqual(approvalView(relayed).delegate, { who: "ab12cd34", childId: "ab12cd34-0000", childShort: "ab12cd34", task: "fix it", more: 0 });
  assert.equal(relayView({ ...relayed, relay: { ...relayed.relay, chain: ["cd34", "ab12cd34"] } }).who, "ab12cd34 → cd34");
  assert.equal(relayView(approval), null);
  assert.equal(approvalView(approval).delegate, undefined);
});

test("a relayed card closed without an answer here says where the question went, never a deny", () => {
  assert.equal(resultText(relayed, { cancelled: true, reason: "answered_on_child" }), "Answered in ab12cd34");
  assert.equal(resultText(relayed, { cancelled: true, reason: "child_gone" }), "ab12cd34's worker is gone");
  assert.equal(resultText(relayed, { cancelled: true, reason: "user" }), "Left open in ab12cd34 (user)");
  // A dismiss here denied it, as for the session's own approvals.
  assert.equal(resultText(relayed, { cancelled: true, reason: "dismissed" }), "Denied (dismissed)");
  assert.equal(resultText(relayed, { answer: { selected: ["Allow once"] } }), "Allowed: Allow once");
});

test("a resolved relayed card's summary names the delegate first", () => {
  assert.equal(summaryText(relayed, { answer: { selected: ["Allow once"] } }), "ab12cd34: execute: git push → Allowed: Allow once");
  assert.equal(summaryText(relayed), "Approve delegate ab12cd34's tool call?");
});
