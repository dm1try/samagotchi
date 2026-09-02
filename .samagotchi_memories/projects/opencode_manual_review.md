# Opencode Review of Implementation (muse-spark-1.2-contributor-free)
## Date: 2026-09-02
## Session: ses_f9dd49186ffeQ14xgflI8gg3ch (plan review) / ses_f9d9dcf1dffeP7MYGk82lZpL1G (impl review hung)
## Manual review findings (post-implementation):
### Critical #1: Injection lost in run_turn ✅ FIXED
- Bug: `maybe_inject_reminders(session.messages)` mutates session.messages, then `messages[0] = system_message` overwrites the injected reminder
- Fix: Moved injection AFTER system prompt construction, appending to `system_message[:content]`
### Critical #2: register_reminder never receives params ✅ FIXED
- Bug: `tool.call(call[:content], reminder_store: @reminder_store)` discards `call[:description]` and `call[:interval_minutes]`
- Fix: Dispatch now forwards description/interval_minutes, RegisterReminder.call merges them
### High #3: REPL bypass ✅ OPEN (noted, lower priority)
- Bug: REPL calls `@kernel.run` directly, bypassing `Engine#run_turn`/`maybe_inject_reminders`
- Impact: Interactive users won't see reminders unless they use Engine path
- Mitigation: User must use `-p`/`--resume`/`--non-interactive` to trigger Engine path
### Medium #4: Dead IdleReminders thread ✅ Noted
- Thread polls every 500ms, sets `@due_reminder_name`, but Engine reads ReminderStore directly
- Harmless waste of CPU, no functional impact
### Low #5: collect_due_reminders API inconsistency
- Returns `{name, description}` while maybe_inject returns `{name, description, interval_minutes}`
- collect_due_reminders is legacy compat, low impact
### Verification:
- 778 examples, 0 failures, 4 pending
- Both critical bugs reproduced and fixed