// The composer's / autocomplete: pure helpers over the session GET's
// `commands` (Commands::Registry#listing: name, description, anytime,
// local, uis, source).

// The commands to offer while the composer holds one "/word" being typed
// (no space or newline yet): the session's slash commands that start with
// it, by name. The terminal UIs' own (local: /stats, /exit …) don't run here.
export function commandMatches(commands, text) {
  const typed = String(text || "");
  if (!/^\/\S*$/.test(typed)) return [];
  const needle = typed.toLowerCase();
  return (Array.isArray(commands) ? commands : [])
    .filter((c) => c && !c.local && typeof c.name === "string" && c.name.startsWith("/"))
    .filter((c) => c.name.toLowerCase().startsWith(needle))
    .sort((a, b) => a.name.localeCompare(b.name));
}

// What picking +name+ does to the composer: {text, send}. The name
// completes with a space for its arguments; ⏎ on a name already typed in
// full sends it as it is (⏎ on "/help" runs /help).
export function pickCommand(name, text, { enter = false } = {}) {
  if (enter && String(text || "") === name) return { text: name, send: true };
  return { text: `${name} `, send: false };
}

// The highlighted row after an arrow key (+delta+ ±1), wrapping.
export function moveSelection(index, count, delta) {
  if (!count) return -1;
  return (((index + delta) % count) + count) % count;
}

// One row's parts: the name, its description, and a note (the bundle it
// comes from; "mid-turn too" for an anytime one, "show: mid-turn too" for
// one whose show form is), "" when there is none.
export function commandRow(command) {
  const notes = [];
  if (command.source && command.source !== "core") notes.push(command.source);
  if (command.anytime) notes.push("mid-turn too");
  else if (command.mid_turn === "depends") notes.push("show: mid-turn too");
  return { name: command.name, description: command.description || "", note: notes.join(" · ") };
}
