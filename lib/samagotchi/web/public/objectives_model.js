// The session's objectives as the page reads them (pure, no DOM): the fold the
// server sends (Objectives.view: {items: [{id, text, status, done_when?,
// move?}], pending}) and what a list note's entry says (Objectives.entry:
// {items, changes?}). See docs/internals/objectives.md.

export const ACTIVE = "active";
export const DONE = "done";
export const DROPPED = "dropped";

const itemsOf = (list) => (Array.isArray(list?.items) ? list.items : []);

// The objectives the strip shows: active first, then done; a dropped one only
// in the edit list.
export function stripItems(list) {
  const items = itemsOf(list);
  return [...items.filter((i) => i.status === ACTIVE), ...items.filter((i) => i.status === DONE)];
}

// Done of the ones still meant (a dropped one doesn't count).
export function progress(list) {
  const kept = itemsOf(list).filter((i) => i.status !== DROPPED);
  return { done: kept.filter((i) => i.status === DONE).length, total: kept.length };
}

// The one objective a one-line strip names: the first still active, else the
// last one done.
export function headline(list) {
  const items = stripItems(list);
  return items.find((i) => i.status === ACTIVE) || items[items.length - 1] || null;
}

// One change as words after "You": "marked O2 done", "reworded O3: old → new".
export function changeText(change) {
  const { id, kind, text, was } = change || {};
  switch (kind) {
    case "added": return `added ${id} ${text}`;
    case "reworded": return `reworded ${id}: ${was} → ${text}`;
    case DONE: return `marked ${id} done`;
    case DROPPED: return `dropped ${id} ${text}`;
    case "reopened": return `reopened ${id}`;
    default: return String(id ?? "");
  }
}

// An entry's line: what the user did, or null when it has nothing to say (a
// first list, a list sent again), which then shows the list itself.
export function entryLine(entry) {
  const changes = Array.isArray(entry?.changes) ? entry.changes : [];
  return changes.length ? `You ${changes.map(changeText).join(" · ")}` : null;
}

// The one route to an edit: the lines /objectives takes (ObjectivesCommand).
const oneLine = (text) => String(text ?? "").replace(/\s+/g, " ").trim();
export const markLine = (verb, id) => `/objectives ${verb} ${id}`;
export const addLine = (text) => (oneLine(text) ? `/objectives add ${oneLine(text)}` : null);
export const rewordLine = (id, text) => (oneLine(text) ? `/objectives edit ${id} ${oneLine(text)}` : null);

// An item's text as the edit box shows it: the form /objectives reads back.
export function editableText(item) {
  return item?.done_when ? `${item.text} (done when: ${item.done_when})` : String(item?.text ?? "");
}

// What the strip says about an edit waiting for the running turn's end. Idle,
// it lands in a moment and says nothing.
export function pendingText(list, running) {
  return list?.pending && running ? "Applies after this turn" : null;
}

// What a tap on Not yet tells the agent: a normal message, as if typed.
export function notYetText(item) {
  return `Not yet on ${item.id} (${item.text}).`;
}
