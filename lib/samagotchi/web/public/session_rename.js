// The info bar's ✎ (Rename this session): a small input in its place,
// prefilled with the session's title ("" for none). Enter sends
// `/title TEXT` (blank: `/title --clear`) through the chips' command path
// (composer.js run: the reply shows as a command bubble, a refusal in the
// failed bubble, the composer untouched); leaving the field saves the same
// way (a phone's keyboard dismissed keeps what was typed). Esc, or opening
// another session, closes it unsent. The cards follow from the saved file
// (the hub's scan), as for any title.
import { normalize } from "./format.js";

// As long as a title may be (TitleCommand::LIMIT).
const TITLE_CHARS = 80;

// The line the input's +text+ sends.
export function titleLine(text) {
  const title = normalize(text);
  return title ? `/title ${title}` : "/title --clear";
}

// @param button the ✎ button (it hides while the input shows)
// @param session () => the open session's id, or null
// @param titleOf (id) => that session's title, or null
// @param run (line) => composer.js run's promise
export function createRename({ button, session, titleOf, run }) {
  let input = null;
  let openFor = null;

  function close() {
    if (!input) return;
    const el = input;
    input = null;
    openFor = null;
    el.remove();
    button.hidden = false;
  }

  // Enter's and blur's: once (closing it blurs it again), and only to the
  // session it was opened for.
  function submit() {
    if (!input) return null;
    const id = openFor;
    const before = normalize(input.dataset.before);
    const text = input.value;
    close();
    if (!id || session() !== id || normalize(text) === before) return null;
    return run(titleLine(text));
  }

  function open() {
    const id = session();
    if (input || !id) return;
    const el = document.createElement("input");
    el.type = "text";
    el.className = "rename-input";
    el.maxLength = TITLE_CHARS;
    el.placeholder = "Session title";
    el.setAttribute("aria-label", "Session title (Enter saves, empty clears, Esc cancels)");
    el.value = titleOf(id) || "";
    el.dataset.before = el.value;
    el.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        submit();
      } else if (e.key === "Escape") {
        e.preventDefault();
        close();
      }
    });
    el.addEventListener("blur", () => submit());
    input = el;
    openFor = id;
    button.hidden = true;
    button.after(el);
    el.focus();
    el.select();
  }

  // The info bar redrew for +id+ (app.js updateInfoBar): an input opened
  // for another session closes.
  function follow(id) {
    if (input && openFor !== id) close();
  }

  button.addEventListener("click", () => open());
  return { open, close, follow, isOpen: () => !!input };
}
