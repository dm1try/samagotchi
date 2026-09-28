import test from "node:test";
import assert from "node:assert/strict";
import { isApproval, approvalView, resultText, approvalAllowed, nextCardAction, summaryText, truncate } from "../../../lib/samagotchi/web/public/question_card.js";

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

test("a plugin tool's approval names it by its label, as its row does", () => {
  const pq = {
    kind: "approval", header: "",
    approval: { tool: "save_note", label: "saving note", paths: ["/r/secret.md"], cwd: "/r", reason: "secret" },
  };
  assert.equal(approvalView(pq).tool, "saving note");
  assert.equal(summaryText(pq), "Approve saving note?");
  assert.equal(summaryText(pq, { answer: { selected: ["Allow once"] } }), "saving note: /r/secret.md → Allowed: Allow once");
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
  assert.equal(summaryText(approval, { answer: { selected: ["Deny"], freeform: "use a PR" } }), "execute: git push → Denied: use a PR");
  assert.equal(summaryText(approval, { cancelled: true, reason: "dismissed" }), "execute: git push → Denied (dismissed)");
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
