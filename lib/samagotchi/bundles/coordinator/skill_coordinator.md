# Skill: coordinator

Use when the user hands over work with several independent parts, or asks to "run it in parallel",
"delegate", "coordinate". The user decides; you do the legwork and keep them in the loop briefly.

## Handoff memory
Your conversation is lost when this session ends; git and the session list are not. Keep a handoff in a
project-scope memory named `handoff_<epic-slug>` (the epic or goal in a few lowercase words joined by
`-`, e.g. `handoff_calc-v2`). Create it with memory_write (scope: project). Its description is the status:
one line under 200 characters that names its owner and says where things stand, never what to do (every
session in this repo sees it, children too): "OPEN coordinator handoff calc-v2 (session <your id>): 2/3
merged, docs kept (user)", later "DONE: …". Change the body with `edit` on the memory's file (in the
Project memories folder), and after every change of state change the status with memory_write name,
scope and description only (no content). It holds ONLY what git and the session list can't rebuild:
- Goal: the goal in one line and the split (task → branch, worktree, child session id).
- Decisions: what the user said per branch (merge / keep / drop / "don't touch X"), their words short.
- Verdicts: your verdict per report (verified / doubts / failed) and why, in one line.
- Follow-ups: found but not fixed.
Not commit lists, diffs, test output or anything a git command shows again. Update it right after:
the split started (step 3), each verdict (step 4), each user decision (an ask_user_question answer or a
plain message: save it before you act on it), each merge or cleanup (steps 6, 7). Before you end a turn
in which any of these changed, check the memory and its description have it. Short: under 40 lines.
One handoff per epic: never write another epic's handoff_* memory.

## Resume (step 0)
Before step 1, look at the project memory index for `handoff_*` entries not marked DONE (`/coordinate
resume` picks one for the user). If one is open and the user's request continues it, or doesn't name new
work ("hi", "what's next?", "where were we?"), do all of this before you answer:
1. Read this skill if you haven't in this session, and memory_read the handoff: its body is the state,
   not the index line (that line is from when this session started). Then rebuild the truth:
   `git worktree list`, `git branch --list`, for each branch in it `git log --oneline <default>..<branch>`
   and `git merge-base --is-ancestor <branch> <default>`, and the list_sessions tool for the child ids
   on record (not listed is not proof a child is gone).
2. Git and the sessions are the truth; the memory is your notes. Tell the user, per branch: its state
   now, the decision and verdict on record, and every mismatch (merged by hand, worktree gone, branch
   deleted, a child that ended without a verdict on record), in one short list.
3. Update the memory and its description to match the truth (keep the decisions; mark the mismatches;
   the owner is now you), then go on from the first open step. Don't redo a merge or cleanup git shows
   done.
If the request is a new goal, say which handoffs are open (one line each) and go on with a new
`handoff_<slug>` of its own; don't touch the others.

## Steps
1. Find the repository's default branch, <default> below: `git symbolic-ref --short
   refs/remotes/origin/HEAD` (drop the `origin/`), else `main` or `master`, whichever exists; ask the
   user if unsure. Split the work into independent tasks (at most session.max_children at once,
   default 4). Tell the user the split in a few lines and go on unless they object.
2. For each task: from your own folder, `git worktree add ../<repo>-<task> -b <type>/<task>` with
   execute; then `delegate` with `wait: false`, `cwd:` that worktree's absolute path, and a
   self-contained task. The task starts with "Work only in <absolute worktree path>: every cd, read,
   write, test and commit goes there, never the project root" and says what to report (the result,
   evidence: commands and what they printed, what isn't done) and "commit on the branch, don't merge,
   don't push, don't write or edit any handoff_* memory".
3. Tell the user what started (one line per child: its id, branch and task) and end your turn or keep
   talking. Don't call delegate_result: chi brings each child's reply as a delegate report, also when
   you are idle.
4. On each report, check it before telling the user: `git -C <worktree> log --oneline <default>..` and
   `git diff --stat <default>...<branch>`; run the tests the child names (execute with cwd: the worktree).
   Say the result in one or two lines: done and verified / done with doubts / failed. In the same turn,
   write that verdict into the handoff body and change its description to match (description only).
5. Then one of (a user's decision about it goes into the handoff first): a follow-up (`delegate
   session: <id>`, narrower, `wait: false`; then end your turn: its report comes by itself, so don't
   wait for it with delegate_result or task_wait), stop it
   (`chi sessions stop <session id>` with execute; task_stop is for task ids, not children; the user
   can use /children), or tell the user it is ready to merge.
6. Merging is the user's call: ask (ask_user_question) per branch, "Merge <branch> into <default>?", and
   save the answer in the handoff before you act on it.
   Before merging, in your own folder: `git branch --show-current` must print <default> (if it
   doesn't, stop and ask the user; don't switch branches yourself); then check <default>:
   `git log --oneline -3 <default>` and `git merge-base --is-ancestor <branch> <default>`; if the branch is already in, say so and don't merge
   again. Merge with `git merge --ff-only <branch>` yourself, in your own folder. If that fails, ask the
   child to rebase its branch on <default> (a follow-up that says "rebase only, don't merge") or ask the
   user; don't rebase it from here (the branch is checked out in the child's worktree). Children
   never merge. Never push unless asked. Don't tell the user a branch can fast-forward unless
   `git merge-base --is-ancestor <default> <branch>` says so now (after each merge <default> moved);
   after a child rebases, check it again as in step 4.
7. Clean up only a branch that was merged or that the user said to drop (that decision saved in the
   handoff first): stop its child (`chi sessions stop <session id>`), then `git worktree remove
   ../<repo>-<task>`, then
   `git branch -d <branch>` (in that order: a branch checked out in a worktree can't be deleted). If
   `-d` refuses, say why to the user; never `-D` unless they say so. If `git worktree remove` refuses
   over untracked or ignored files, show `git -C <worktree> status --short --ignored` and ask; never
   `rm -rf`. Remove only worktrees and branches you created in this session. Every other branch stays as it is, its child, worktree and
   branch too (the user said "keep it", or didn't say): leave them and tell the user they remain.
8. When all are done, report: what merged, what didn't and why, what you cleaned up and what remains,
   follow-ups found but not fixed. Report only what the commands' output showed: a step you planned
   but didn't run, or whose output you didn't see, is not done; say so. Then set the handoff's
   description to "DONE: …" and ask the user whether to remove it (memory_write name, scope and
   remove: true).

## Gotchas
- Children are asked before changing anything outside their worktree (your checkout, a sibling's):
  the user approves it on the child's card. Still check where commits landed (step 4).
- Never kill processes by a pid from a file or an old note; stop children with `chi sessions stop
  <session id>` (execute) and background tasks with task_stop (task ids only: it doesn't stop a child).
- A child's tool approvals go to the user on the child's card; tell the user when a report says a
  child waits for one.
- A report is the child's claim: verify it (step 4) before telling the user it is done, and check
  where its commits landed: `git log --oneline <default>..<branch>` has them and `git status` in your own
  folder is clean. A child that worked in your folder instead of its worktree: tell the user.
- Don't send a follow-up to a child that is still running; wait for its report.
- Don't start more children than the user asked for.

## Changelog
- 2026-10-06 created (coordinator bundle 0.1.0)
- 2026-10-06 clean up only merged or dropped branches; report only what commands showed (0.1.2)
- 2026-10-07 handoff memory with its status in the description, resume (step 0, /coordinate resume),
  save decisions first, fast-forward and worktree-remove checks, remove the handoff when done (0.2.0)
