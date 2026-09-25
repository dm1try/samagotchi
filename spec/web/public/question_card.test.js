import test from "node:test";
import assert from "node:assert/strict";
import { isApproval, approvalView, resultText, approvalAllowed, nextCardAction } from "../../../lib/samagotchi/web/public/question_card.js";

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
