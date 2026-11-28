// The composer's drafts: the one writer of the message box (#prompt) and its
// image chips. Every write of text or chips into the composer comes through
// here, by the key of the draft it is for ("" the start page, else the
// session's id): a pick, a quote, a failed turn's line back, the send's ack,
// a recalled history entry, a / pick. The ESLint block
// samagotchi/prompt-writes (eslint.config.js) keeps the other modules off
// #prompt's value and the mount's setChips.
//
// One slot for now: the key is taken and not yet read, so every draft is the
// one box, as before (a draft per session window comes next).
//
// deps: +promptEl+ the message box; +view+ the mounted composer's chips
// ({chips(), setChips(list, opts)}: composer_mount.js); +fit()+ its height;
// +shownKey()+ the key of the window on view; +reveal+: {openForVisit(),
// focusPrompt()} the composer's (composer_grip.js), for a write that must be
// seen.
//
// @return {text(key), chips(key), has(key), setText(key, text, opts),
//   clear(key), putChips(key, list), move(from, to), show(key),
//   syncFromView()}
// A module of its own: new exports go in new modules (web-frontend.md).
export function createDrafts({ promptEl, view, fit = () => {}, shownKey = () => "", reveal = {} }) {
  // The caret at the end, the box scrolled to it.
  function caretToEnd() {
    const end = promptEl.value.length;
    promptEl.setSelectionRange?.(end, end);
    promptEl.scrollTop = promptEl.scrollHeight;
  }

  // +key+'s text (the box's).
  function text(_key = shownKey()) {
    return promptEl.value;
  }

  // +key+'s chips (the mount's list).
  function chips(_key = shownKey()) {
    return view.chips();
  }

  // Whether +key+'s draft holds anything: text or a chip.
  function has(key = shownKey()) {
    return !!(text(key).trim() || chips(key).length);
  }

  // +key+'s text becomes +value+. +reveal+: the composer opens for this
  // visit first; +focus+: the box takes the focus; +caretEnd+: the caret at
  // the end of the text.
  function setText(_key, value, { reveal: open = false, focus = false, caretEnd = false } = {}) {
    if (open) reveal.openForVisit?.();
    promptEl.value = String(value ?? "");
    fit();
    if (focus) reveal.focusPrompt?.();
    if (caretEnd) caretToEnd();
  }

  // +key+'s text emptied; its chips stay.
  function clear(key) {
    setText(key, "");
  }

  // +key+'s chips become +list+ (a chip left out frees its preview).
  function putChips(_key, list) {
    view.setChips(list);
  }

  // One slot: nothing moves, nothing to swap, the box is the draft.
  function move(_from, _to) {}
  function show(_key) {}
  function syncFromView() {}

  return { text, chips, has, setText, clear, putChips, move, show, syncFromView };
}
