# Plan: Periodic Reminders with Auto-Turn

## Problem
The agent has no way to schedule periodic checks without blocking itself. Current workaround:
```
task_create { command: "sleep 300 && curl /api/health" }
task_wait { id: ..., timeout: 350 }
```
This blocks the agent for the full interval. No other work can happen. The harness sits idle.

## Solution
Three tools (`register_reminder`, `cancel_reminder`, `list_reminders`) + a new `IdleReminders` component that mirrors IdleRecap's architecture but with a fundamentally different output: inject reminders into the agent's conversation via auto-created turns.

## Architecture

### Components

1. **IdleReminders** (new, `lib/samagotchi/idle_reminders.rb`)
   - Sibling to IdleRecap, but different direction: harness → agent
   - Background thread polls every 500ms, reads Engine's shared inactivity clock
   - Tracks registered reminders (name, description, interval_minutes, action, last_fired_at)
   - When `last_activity_at > interval` for a reminder, marks it as "due"
   - Public `due_reminders` method returns list of due reminder names (read by Engine on main thread)
   - Thread-safe: background thread only modifies its own data structures; Engine reads on main thread

2. **Tools** (3 new files)
   - `register_reminder { name, description, interval_minutes, action }` — adds to engine's reminders registry
   - `cancel_reminder { name }` — removes from registry
   - `list_reminders` — lists all active reminders

3. **Engine integration**
   - `@reminders = IdleReminders.new(engine: self)` (injected in `initialize`, built via `build_reminders`)
   - `start_reminders()` / `stop_reminders()` (like `start_recap`/`stop_recap`)
   - `run_turn` checks `@reminders.due_reminders` at start, injects `[SYSTEM: REMINDERS DUE]` message
   - When a reminder is due and NO turn is running → **auto-create a turn**:
     - Use the session's last user prompt (or empty string)
     - Inject due reminders into conversation
     - Run `run_turn` synchronously on the main thread (not from background thread)
     - Capture result, write back to session
   - Engine owns the reminder registry (reminders are in-memory per-session)

4. **TerminalUI integration**
   - `start_reminders()` called alongside `start_recap()` before REPL
   - `stop_reminders()` called on exit
   - No new UI rendering needed (reminders go into conversation, not terminal)

5. **SessionManager integration**
   - Background workers call `engine.start_reminders()` at session start
   - Reminders persist across turns (same engine instance)
   - Workers poll for input files as usual; auto-turns happen between polls

### Auto-Turn Logic

The auto-turn happens on the **main thread**, triggered by the background detector:

```
Background thread (every 500ms):
  detect due reminders → @due_reminders << reminder
  if due and no turn running:
    engine.auto_create_turn

Main thread (in Engine#run_turn):
  check @reminders.due_reminders
  if any: inject [SYSTEM: REMINDERS DUE] message
  clear @reminders.due_reminders
```

The `auto_create_turn` method:
1. Gets the session (from @session)
2. Gets the last user prompt (or empty string)
3. Calls `run_turn(session, prompt, ...)` synchronously
4. The run_turn flow handles reminder injection natively
5. Returns the result (which can be written to session)

### Conversation Injection Format

When reminders are due, the engine injects this into the conversation as a system message:

```
[SYSTEM: REMINDERS DUE]
- api_health: "Check the API health endpoint every 5 minutes. Action: use web_fetch on https://api.example.com/health"
[END REMINDERS]
```

The agent sees this in its context, acts on it (runs web_fetch, processes result), and the reminder stays registered for the next interval. The agent can call `cancel_reminder` when done.

### Reminder Lifecycle

1. Agent calls `register_reminder { name: "api_health", description: "Check API health", interval_minutes: 5 }`
2. Reminder is stored in Engine's registry (`@reminders`)
3. Agent continues working on other things
4. After 5 minutes of inactivity, IdleReminders detects it's due
5. If no turn is running, Harness auto-creates a turn with reminder injected
6. Agent sees reminder, acts on it
7. Reminder stays registered for next 5-minute interval
8. Agent calls `cancel_reminder { name: "api_health" }` when done
9. Session ends → reminders cleared

### Edge Cases

- **Agent never goes idle**: Reminder stays pending until the agent takes a break. Acceptable — agent is busy.
- **Multiple reminders due at once**: All injected together. Agent can batch-process.
- **Reminder fires during mid-turn**: Won't happen — injection only at `run_turn` start.
- **Agent ignores the reminder**: Stays registered, fires again on next interval.
- **Session resume**: Reminders are in-memory only (per-session). For persistent reminders, agent writes to memory directly.
- **Auto-turn while user is typing**: Won't happen — `turn_running?` guard prevents overlapping.
- **Auto-turn fails (LLM error, etc.)**: Caught by Engine's error handling, never crashes session. Reminder stays registered for next interval.
- **Background worker process death**: Reminders lost (per-session in-memory). Worker restart = fresh start.

## Implementation Steps

### Step 1: Tool files
- `lib/samagotchi/tools/register_reminder.rb`
- `lib/samagotchi/tools/cancel_reminder.rb`
- `lib/samagotchi/tools/list_reminders.rb`
- Each stores/reads reminders from Engine's registry via a shared data structure

### Step 2: IdleReminders component
- `lib/samagotchi/idle_reminders.rb`
- Background thread, 500ms polling
- `due_reminders` public method
- `start`/`stop` lifecycle
- Thread-safe data access

### Step 3: Engine integration
- Add `@reminders` ivar, `build_reminders` method
- `start_reminders`/`stop_reminders` public methods
- `run_turn` checks for due reminders, auto-creates turn if needed
- System prompt injection of due reminders
- Config resolution (like `build_recap`)

### Step 4: Tool declarations
- Update `lib/samagotchi/tool_declarations.rb` with 3 new tool declarations

### Step 5: TerminalUI integration
- `start_reminders()`/`stop_reminders()` calls alongside recap

### Step 6: SessionManager integration
- `start_reminders()` in `run_session_loop`

### Step 7: Tests
- Unit tests for IdleReminders (mirroring idle_recap_spec)
- Unit tests for each tool
- Integration test for auto-turn flow

### Step 8: System prompt update
- Add hint about reminders so the agent knows how to use them

## Acceptance Criteria

- [ ] Agent can register a reminder with `register_reminder { name, description, interval_minutes }`
- [ ] Agent can cancel a reminder with `cancel_reminder { name }`
- [ ] Agent can list active reminders with `list_reminders`
- [ ] When a reminder is due and no turn is running, harness auto-creates a turn
- [ ] Auto-created turn injects due reminders as [SYSTEM:] messages
- [ ] Agent sees reminders in context and can act on them
- [ ] Reminders fire on every interval until canceled
- [ ] Thread-safe: no race conditions between background detector and main thread
- [ ] Error isolation: failed auto-turns never crash session
- [ ] All 759+ existing tests still pass
- [ ] New tests cover auto-turn flow

## Files Changed (Summary)

New files:
- `lib/samagotchi/tools/register_reminder.rb`
- `lib/samagotchi/tools/cancel_reminder.rb`
- `lib/samagotchi/tools/list_reminders.rb`
- `lib/samagotchi/idle_reminders.rb`
- `spec/tools/register_reminder_spec.rb`
- `spec/tools/cancel_reminder_spec.rb`
- `spec/tools/list_reminders_spec.rb`
- `spec/idle_reminders_spec.rb`
- `spec/integration/reminder_auto_turn_spec.rb`

Modified files:
- `lib/samagotchi/engine.rb`
- `lib/samagotchi/terminal_ui.rb`
- `lib/samagotchi/session_manager.rb`
- `lib/samagotchi/tool_declarations.rb`
- `spec/engine_spec.rb` (add reminder injection tests)

## Risks

1. **Auto-turn flooding**: If a reminder fires every 5 minutes and the agent keeps ignoring it, will it flood? → No, because auto-turn only fires when the agent is idle. If the agent is working (turn running), the reminder waits.
2. **Context bloat**: Repeated reminder injections could fill context. → Mitigation: reminders only inject when due. Once injected, they stay in context. The agent can cancel. After many intervals, the reminder text is still just a few lines — not cumulative.
3. **Thread safety**: Background thread modifying data that Engine reads. → Solution: all reminder state is owned by IdleReminders; Engine only reads via `due_reminders` which returns a frozen snapshot. No shared mutable state.
4. **SessionManager auto-turn**: Background workers already poll every 1 second for input. Auto-turn adds another loop. → Solution: auto-turn is checked at the same poll interval, not in a separate loop. It's just another check in the existing poll loop.
