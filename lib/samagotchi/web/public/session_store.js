// The owner page's session state in one place: the open session's id
// (selected), its fields (current, session_state.js) and every card
// (sessions, the hub's projection). Writes go through update() (and
// replaceCurrent() for forgetSession's reset); a write marks the redraws
// that read what changed, and they run synchronously at the end of the
// outermost batch(), or at once for a bare write.
// See docs/internals/web-frontend.md ("The session store").
//
// A new module: the page's modules are cached at unversioned URLs, and a
// new export of an old module would leave a cached copy without it.

// The redraws, by name, in the one order a flush runs them: the lists
// before the bar (updateSessionTitle reads the strip's active card), the
// composer before the bar (as setTurnRunning runs them).
export const ORDER = [
  "lists",
  "paintActive",
  "llmContextChip", "thinkingChip", "reasoningChip", "workingSetStrategy",
  "featureGates",
  "composer",
  "infoBar",
];

// What a change of the list or of the open session's id redraws: the bar
// reads the list too (the chain's ← → links, the children chip, the
// archived button, the card's title, the fresh link's picker).
const SESSIONS_REDRAWS = ["lists", "infoBar"];
const SELECTED_REDRAWS = ["paintActive", "composer", "infoBar"];

// A flush whose redraws keep writing stops after this many passes.
export const MAX_PASSES = 3;

// @param initial the open session's fields to start from (emptySessionState())
// @param fields {key: {redraws: [name]}} what each field of `current` redraws
//   (session_fields.js FIELDS); a field it doesn't list redraws nothing
// @param log where a refused batch, a capped flush and a redraw error that
//   can't be thrown go (console by default)
export function createSessionStore({ initial = {}, fields = {}, log = console } = {}) {
  let selected = null;
  let current = initial;
  let sessions = [];
  const redraws = new Map(ORDER.map((name) => [name, []]));
  const pending = new Set();
  let depth = 0;
  let flushing = false;

  const enqueue = (names) => names.forEach((name) => pending.add(name));
  const fieldRedraws = (key) => fields[key]?.redraws || [];

  // Run the pending redraws in ORDER, a pass at a time: a write made during
  // a redraw only enqueues (the flushing flag), and the next pass takes it.
  // A redraw that throws doesn't stop the others; the first error is thrown
  // once the flush is over.
  function flush() {
    if (flushing || depth > 0) return;
    flushing = true;
    let error = null;
    try {
      for (let pass = 0; pending.size > 0; pass += 1) {
        if (pass === MAX_PASSES) {
          log.error(`session store: still redrawing after ${MAX_PASSES} passes: ${[...pending].join(", ")}`);
          pending.clear();
          break;
        }
        const names = ORDER.filter((name) => pending.has(name));
        pending.clear();
        for (const name of names) {
          for (const fn of redraws.get(name)) {
            try {
              fn();
            } catch (e) {
              error ??= e;
            }
          }
        }
      }
    } finally {
      flushing = false;
    }
    if (error) throw error;
  }

  const store = {
    get selected() { return selected; },
    get current() { return current; },
    get sessions() { return sessions; },

    // Write the given parts: +selected+ (an id or null), +current+ (fields
    // written into the open session's object, which stays the same object),
    // +sessions+ (a new list: one changed in place isn't seen). A changed
    // value (!==) marks its redraws.
    update(patch = {}) {
      if ("selected" in patch && patch.selected !== selected) {
        selected = patch.selected;
        enqueue(SELECTED_REDRAWS);
      }
      if (patch.current) {
        for (const [key, value] of Object.entries(patch.current)) {
          if (current[key] === value) continue;
          current[key] = value;
          enqueue(fieldRedraws(key));
        }
      }
      if ("sessions" in patch && patch.sessions !== sessions) {
        sessions = patch.sessions;
        enqueue(SESSIONS_REDRAWS);
      }
      flush();
    },

    // A new open session's fields (forgetSession only): always a new object,
    // so a stale async writer still holding the old one writes into it alone.
    replaceCurrent(state) {
      current = { ...state };
      enqueue(Object.keys(current).flatMap(fieldRedraws));
      flush();
    },

    // Run +fn+ (synchronous) with its writes' redraws held to its end; nested
    // batches join the outermost. The redraws run even when +fn+ throws (the
    // page shows what was written), then its error is rethrown. An +fn+ that
    // returns a promise is refused: its writes after an await would land
    // outside the batch, so batch only an async function's synchronous parts.
    batch(fn) {
      depth += 1;
      let result;
      let failed = false;
      let error;
      try {
        result = fn();
      } catch (e) {
        failed = true;
        error = e;
      } finally {
        depth -= 1;
      }
      if (result && typeof result.then === "function") {
        log.error("session store: batch() takes a synchronous function; batch an async one's synchronous parts");
      }
      if (failed) {
        try {
          flush();
        } catch (e) {
          log.error(e);
        }
        throw error;
      }
      flush();
      return result;
    },

    // Something the store doesn't hold changed (the clock, versions, the
    // stream): +name+'s redraw runs.
    touch(name) {
      enqueue([name]);
      flush();
    },

    // Register +fn+ as (one of) the redraw(s) called +name+ (one of ORDER).
    on(name, fn) {
      if (!redraws.has(name)) throw new Error(`session store: no redraw called ${name}`);
      redraws.get(name).push(fn);
    },
  };
  return store;
}
