# Chi Self-Review of Reminder Implementation
## Date: 2026-09-02
## Method: Spawning separate chi instance with --non-interactive to review implementation
## Verdict: NEEDS CHANGES (but fixable without architectural changes)
## 8 Risks Found:
1. **SessionManager double-signaling** (HIGH RISK) — Worker writes synthetic input AND engine injects system message = agent gets 2 reminder signals
2. **Two parallel signal paths** — `collect_due_reminders` reads IdleReminders' @due_reminder_name, `maybe_inject_reminders` reads ReminderStore directly — could diverge
3. **Legacy `collect_due_reminders` is dead code** — Confusing dual API
4. **ReminderStore returns frozen array but engine mutates messages** — Injected reminder stays in session even on cancel
5. **`clear_all_due` is misleading** — Just clears a single name field, same as `clear_due`
6. **No test for `Engine#maybe_inject_reminders`** — Critical integration point uncovered
7. **IdleReminders thread killed mid-Monitor** — Ruby Monitor should be ok, but worth noting
8. **No full Engine turn test** — No spec from Engine.new → maybe_inject_reminders → verify

## 5 Improvements Suggested:
1. **Remove SessionManager synthetic input path** (redundant with engine injection)
2. **Consolidate dual signal paths** (collect_due_reminders vs maybe_inject_reminders)
3. **Add Engine-level tests for maybe_inject_reminders**
4. **Consider clearing injected reminders on turn cancellation**
5. **Rename clear_all_due** to be more accurate

## Key Insight:
The core design is sound. Issues are integration-level (SessionManager) and completeness-level (missing Engine tests, dead code).