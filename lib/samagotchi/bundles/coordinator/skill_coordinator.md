# Skill: coordinator

Use when the user hands over work with several independent parts, or asks to "run it in parallel",
"delegate", "coordinate". The user decides; you do the legwork and keep them in the loop briefly.

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
   don't push".
3. Tell the user what started (one line per child: its id, branch and task) and end your turn or keep
   talking. Don't call delegate_result: chi brings each child's reply as a delegate report, also when
   you are idle.
4. On each report, check it before telling the user: `git -C <worktree> log --oneline <default>..` and
   `git diff --stat <default>...<branch>`; run the tests the child names (execute with cwd: the worktree).
   Say the result in one or two lines: done and verified / done with doubts / failed.
5. Then one of: a follow-up (`delegate session: <id>`, narrower, `wait: false`; then end your turn:
   its report comes by itself, so don't wait for it with delegate_result or task_wait), stop it
   (`chi sessions stop <id>`; the user can use /children), or tell the user it is ready to merge.
6. Merging is the user's call: ask (ask_user_question) per branch, "Merge <branch> into <default>?".
   Before merging, in your own folder: `git branch --show-current` must print <default> (if it
   doesn't, stop and ask the user; don't switch branches yourself); then check <default>:
   `git log --oneline -3 <default>` and `git merge-base --is-ancestor <branch> <default>`; if the branch is already in, say so and don't merge
   again. Merge with `git merge --ff-only <branch>` yourself, in your own folder. If that fails, ask the
   child to rebase its branch on <default> (a follow-up that says "rebase only, don't merge") or ask the
   user; don't rebase it from here (the branch is checked out in the child's worktree). Children
   never merge. Never push unless asked.
7. After a merge: stop the child, then `git worktree remove ../<repo>-<task>`, then
   `git branch -d <branch>` (in that order: a branch checked out in a worktree can't be deleted). If
   `-d` refuses, say why to the user; never `-D` unless they say so. Remove only worktrees and
   branches you created in this session.
8. When all are done, report: what merged, what didn't and why, follow-ups found but not fixed.

## Gotchas
- Children are asked before writing or committing outside their worktree only with the guardrails
  bundle in strict mode (`guardrails.mode: strict`). Without it nothing stops a child that wanders
  into your checkout: say so to the user when /coordinate warned about it, and check where commits
  landed (step 4) all the more.
- Never kill processes by a pid from a file or an old note; stop children with `chi sessions stop <id>`
  and background tasks with task_stop (by task id).
- A child's tool approvals go to the user on the child's card; tell the user when a report says a
  child waits for one.
- A report is the child's claim: verify it (step 4) before telling the user it is done, and check
  where its commits landed: `git log --oneline <default>..<branch>` has them and `git status` in your own
  folder is clean. A child that worked in your folder instead of its worktree: tell the user.
- Don't send a follow-up to a child that is still running; wait for its report.
- Don't start more children than the user asked for.

## Changelog
- 2026-10-06 created (coordinator bundle 0.1.0)
