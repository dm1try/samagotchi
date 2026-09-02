# opencode review of idle_reminders_plan
## Model: muse-spark-1.2-contributor-free
## Session: ses_f9dd49186ffeQ14xgflI8gg3ch
## Date: 2026-09-02

## Verdict: NOT SAFE to implement as described

## (a) Risks / Gaps Found (8 issues)

1. **Plan vs. code divergence - feature is dead as written.**
   Plan says `Engine#initialize` creates `@reminders` via `build_reminders` and `run_turn` injects reminders + `auto_create_turn`.
   Actual `engine.rb:49-62` creates `@reminder_store` but never assigns `@reminders`; `start_reminders`/`collect_due_reminders` are `&.` no-ops.
   `SessionManager.run_session_loop` and `TerminalUI` never call `start_reminders`.
   `idle_reminders.rb:111-127` explicitly says `does NOT auto-run a turn - waits for next natural pause`.
   → The feature is already partially implemented but inert.

2. **Contradictory auto-turn mechanism = TOCTOU race.**
   Plan defines both `Background thread: if due && !turn_running? -> engine.auto_create_turn` and `Main thread: run_turn checks due_reminders`.
   `turn_running?` is a Monitor-guarded flag, not a lock. Sequence: background checks !running → main enters run_turn → sets_running(true) → background calls auto_create_turn → run_turn produces two concurrent `KernelLoop#run` mutating `session.messages`.
   IdleRecap avoids this by never touching conversation; reminders MUST be serialized.

3. **Single-slot queue starves multiple reminders.**
   Plan: `due_reminders: [String]` injected together.
   Impl: `idle_reminders.rb:39 @due_reminder_name:String|nil`, `reminder_store.rb:88-95 next_due_name` returns first `next_fire_at <= now`. Only 1/interval delivered; others delayed indefinitely.
   `engine.rb:225-234 collect_due_reminders` also returns at most 1.

4. **Idle-gated periodicity != periodic.**
   `idle_reminders.rb:84-89 should_check?` requires `last_idle_seconds >= @inactivity (60s)` + `reminder_store` interval.
   If user types continuously, `record_activity` resets clock so 5m reminder never fires.
   Conversely idle 60s triggers even if interval not elapsed.
   No `last_fire_at` vs `last_activity_at` disambiguation.

5. **Model cannot discover tools.**
   `kernel_loop.rb:99-106` registers 3 tools and dispatches, but `tool_declarations.rb` and `terminal_ui.rb` contain NO `register_reminder/cancel/list` declarations.
   System prompt built at `engine.rb:584` never advertises them — LLM will not call them without prompt injection.

6. **Session-lifecycle leak.**
   Plan says per-session in-memory cleared on end.
   `SessionManager.resume_session` forks new process/new Engine = new ReminderStore; `Session.load` does not persist reminders.
   Expected persistent health-check vanishes on crash/resume. No `clear_all` hook on `Session.mark_stopped`.

7. **Unbounded cost / context bloat loop.**
   Auto-turn does `backend.complete` per interval even with no user demand.
   `record_activity` re-arms after auto-turn, so if agent ignores reminder, it fires again next interval and each injection is appended permanently to `session.messages`.
   No deduplication, max cap, or exponential backoff; 5m reminder = 288 LLM calls/day per session.

8. **Thread-safety of `collect_due_reminders` is non-atomic.**
   `engine.rb:226 clear_due + 233 mark_fired` span 2 monitors (idle_reminders and reminder_store).
   Background `tick` blocks on `return if @due_reminder_name` but can race between `due_reminder_name` read and `clear_due`.

## (b) Concrete Improvement Suggested

Make delivery **pull-based, single-threaded** and fix wiring; do NOT `Thread.new{ engine.run_turn }` from detector.

- `engine.rb:49` add `build_reminders` mirroring `build_recap` at `engine.rb:468`, assign `@reminders` unconditionally (or when `ENV` enables), expose `maybe_inject_reminders` called *synchronously* at top of `run_turn` (before `set_turn_running(true)`) that atomically `pop_all_due` -> returns `Array<{name,desc}>` and does `mark_fired` under one `ReminderStore` lock.
- For `SessionManager` background workers: in `session_manager.rb:212-216` 1s `find_new_input_files` loop, after `idle_seconds >= 60 && next_due_name` write a synthetic file `__REMINDER__.txt` via `write_turn_input` instead of direct `run_turn`. Existing file-IPC serializes turns, reuses `record_activity`, and preserves `status`/`last_prompt` semantics.
- For `TerminalUI`: drive same check in `read_input` idle path or before `Reline.readline`, not via detector thread spawning turns. This removes `auto_create_turn` entirely and matches IdleRecap's terminal-only pattern.
- Fix declarations: add 3 tools to `ToolDeclarations` and `QWEN_TOOLS_JSON`, fix `ReminderStore#register` parsing at `reminder_store.rb:33` (`call[:interval_minutes].to_i` silently coerces `"5m"` -> 5) and add `interval <= 1440` validation.

## (c) Safe to implement?

**No.** Verbose auto-turn from background thread violates `Engine#run_turn`'s non-reentrant contract and introduces data race + unbounded LLM invocations. As currently committed (only store+dispatch, no `build_reminders`, no injection, no `TerminalUI`/`SessionManager` start), feature is inert; implementing plan verbatim would deadlock/starve or corrupt `session.messages`. Ship only after (b) plus tests for `concurrent turn_running?`, `multiple due`, and `declaration visibility`.