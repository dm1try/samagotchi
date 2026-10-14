// ── / autocomplete ─────────────────────────────────────────────────────────
// While the composer holds one "/word", a small glass list above it offers
// the session's commands (its worker's, plugins' too): arrows move, ⏎/Tab
// pick, Esc closes, a tap picks. A closed list takes no keys.
//
// The matching is command_complete.js'; this is the list's DOM (a lit-html
// template).

import { commandMatches, commandRow, moveSelection, pickCommand } from "./command_complete.js";
import { html, nothing, render as draw } from "./vendor/lit-html.js";

// One option row; +active+ is the arrows' row.
function optionTemplate(command, i, active) {
  const row = commandRow(command);
  return html`<div class=${`command-option${active ? " active" : ""}`} role="option" id=${`command-option-${i}`} aria-selected=${String(active)} data-index=${i}><span class="command-name">${row.name}</span><span class="command-desc">${row.description}</span>${
    row.note ? html`<span class="command-note">${row.note}</span>` : nothing}</div>`;
}

// @param list the list element (#commandList)
// @param prompt the composer's textarea
// @param commands () => the open session's commands ([] when it takes none)
// @param afterPick () runs after a pick changed the composer's text (fit it)
// @return {update(), close(), handleKey(e)}; handleKey returns whether the
//   open list took the key
export function createCommandList({ list, prompt, commands, afterPick = () => {} }) {
  let shown = [];
  let index = 0;

  const isOpen = () => !list.hidden && shown.length > 0;

  function update() {
    const next = commandMatches(commands(), prompt.value);
    if (!next.length) return close();
    const keep = shown[index]?.name;
    shown = next;
    index = Math.max(0, next.findIndex((c) => c.name === keep));
    render();
  }

  function render() {
    draw(shown.map((c, i) => optionTemplate(c, i, i === index)), list);
    list.hidden = false;
    prompt.setAttribute("aria-expanded", "true");
    prompt.setAttribute("aria-activedescendant", `command-option-${index}`);
    list.querySelector(".command-option.active")?.scrollIntoView({ block: "nearest" });
  }

  function close() {
    shown = [];
    index = 0;
    list.hidden = true;
    draw(nothing, list);
    prompt.setAttribute("aria-expanded", "false");
    prompt.removeAttribute("aria-activedescendant");
  }

  // @return whether the pick took the key (false: ⏎ on a full name sends it)
  function accept(at, { enter = false } = {}) {
    const command = shown[at];
    if (!command) return false;
    const pick = pickCommand(command.name, prompt.value, { enter });
    close();
    if (pick.send) return false;
    prompt.value = pick.text;
    prompt.setSelectionRange(pick.text.length, pick.text.length);
    afterPick();
    prompt.focus();
    return true;
  }

  // @return whether the open list took the key
  function handleKey(e) {
    if (!isOpen() || e.isComposing) return false;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      index = moveSelection(index, shown.length, e.key === "ArrowDown" ? 1 : -1);
      render();
    } else if (e.key === "Tab" && !e.shiftKey) {
      accept(index);
    } else if (e.key === "Enter" && !e.shiftKey) {
      if (!accept(index, { enter: true })) return false;
    } else if (e.key === "Escape") {
      close();
      e.stopPropagation();
    } else {
      return false;
    }
    e.preventDefault();
    return true;
  }

  prompt.addEventListener("input", update);
  prompt.addEventListener("blur", close);
  // Keep the focus in the composer: the pick happens on click.
  list.addEventListener("pointerdown", (e) => e.preventDefault());
  list.addEventListener("click", (e) => {
    const option = e.target.closest(".command-option");
    if (option) accept(Number(option.dataset.index));
  });

  return { update, close, handleKey };
}
