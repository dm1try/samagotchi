// The composer's drafts: one per session window ("" the start page, else
// the session's id), and the one writer of the message box (#prompt) and its
// image chips. Every write of text or chips into the composer comes through
// here, by the key of the draft it is for: a pick, a quote, a failed turn's
// line back, the send's ack, a recalled history entry, a / pick. The ESLint
// block samagotchi/prompt-writes (eslint.config.js) keeps the other modules
// off #prompt's value and the mount's setChips.
//
// The box and the mount's chips are the draft on view (+painted+): the
// truth for it, read and written in place. The other drafts are kept here
// ({text, chips}, per tab). show(key) swaps them (session_view.js
// forgetSession, and app.js at boot): the outgoing draft is taken from the
// box and saved, the next one painted. A draft's text is saved in this
// browser on every write and input (session_prefs.js, COMPOSER_DRAFT:
// <key>:<session>, swept with the view settings; the start page's under
// START_DRAFT, one per browser): a reload or the Home Screen app's
// relaunch finds it. Chips live in memory only (a reload loses them); a
// chip's preview is freed on its ×, at its send, or when its draft is
// dropped, never on a swap.
//
// While a line is in flight (sending(key, line)), the saved copy leaves it
// out (restore.js composerAfterAck): a reload or an iOS kill right after
// Send doesn't bring back a line already sent.
//
// deps: +promptEl+ the message box; +view+ the mounted composer
// (composer_mount.js: chips(), setChips(list, {revoke}), resetHistory());
// +fit()+ its height; +shownKey()+ the key of the window on view; +reveal+:
// {openForVisit(), focusPrompt()} the composer's (composer_grip.js), for a
// write that must be seen; +revoke(src)+ frees a chip's preview.
//
// @return {text(key), chips(key), has(key), setText(key, text, opts),
//   putBack(key, text), clear(key), putChips(key, list), move(from, to),
//   handOver(from, to, opener), drop(key), show(key),
//   syncFromView(), sending(key, line), settle(key, line)}
// A module of its own: new exports go in new modules (web-frontend.md).
import { COMPOSER_DRAFT, START_DRAFT } from "./draft_keys.js";
import { forget as forgetPref, read as readPref, write as writePref } from "./session_prefs.js";
import { readStored, removeStored, writeStored } from "./storage.js";
import { composerAfterAck, restoreInto } from "./restore.js";

export function createDrafts({
  promptEl, view, fit = () => {}, shownKey = () => "", reveal = {},
  revoke = (src) => URL.revokeObjectURL(src),
}) {
  // The drafts not on view, by key: {text, chips, sent} (+sent+: the line in
  // flight, left out of the saved copy).
  const kept = new Map();
  // The draft the box and the chips show; null until the first show (boot).
  let painted = null;

  function stored(key) {
    return (key ? readPref(COMPOSER_DRAFT, key, "") : readStored(START_DRAFT, "")) ?? "";
  }

  // +key+'s entry, its text read from storage the first time this tab sees it.
  function entry(key) {
    let e = kept.get(key);
    if (!e) {
      e = { text: stored(key), chips: [], sent: null };
      kept.set(key, e);
    }
    return e;
  }

  // An older cached session_view.js never calls show(): the box stays the one
  // for every window, as before, and is the draft of the window on view (an
  // empty box over a draft kept for it paints that draft).
  function heal() {
    const key = shownKey();
    if (painted === null || key === painted) return;
    painted = key;
    if (!promptEl.value.trim() && !view.chips().length && hasKept(entry(key))) paint(key);
  }
  const hasKept = (e) => !!(e.text.trim() || e.chips.length);

  function paint(key) {
    const e = entry(key);
    promptEl.value = e.text;
    view.setChips(e.chips.slice(), { revoke: false });
    fit();
    view.resetHistory?.();
  }

  // The box's draft back into its entry (a copy: the mount changes its list in place).
  function flush() {
    const e = entry(painted);
    e.text = promptEl.value;
    e.chips = view.chips().slice();
  }

  // +key+'s text as saved: empty (white space only) is no key at all.
  function save(key) {
    const e = entry(key);
    const current = key === painted ? promptEl.value : e.text;
    const text = e.sent ? composerAfterAck({ sent: e.sent, current }) : current;
    if (!text.trim()) {
      if (key) forgetPref(COMPOSER_DRAFT, key);
      else removeStored(START_DRAFT);
    } else if (key) writePref(COMPOSER_DRAFT, key, text);
    else writeStored(START_DRAFT, text);
  }

  function caretToEnd() {
    const end = promptEl.value.length;
    promptEl.setSelectionRange?.(end, end);
    promptEl.scrollTop = promptEl.scrollHeight;
  }

  function freePreviews(list, keep = []) {
    for (const c of list) if (c.file && c.src && !keep.includes(c)) revoke(c.src);
  }

  function text(key = shownKey()) {
    heal();
    return key === painted ? promptEl.value : entry(key).text;
  }

  function chips(key = shownKey()) {
    heal();
    return key === painted ? view.chips() : entry(key).chips;
  }

  // Whether +key+'s draft holds anything: text or a chip.
  function has(key = shownKey()) {
    return !!(text(key).trim() || chips(key).length);
  }

  // +key+'s text becomes +value+, saved. On view only: +reveal+ opens the
  // composer for this visit first, +focus+ gives the box the focus,
  // +caretEnd+ puts the caret at the end.
  function setText(key, value, { reveal: open = false, focus = false, caretEnd = false } = {}) {
    heal();
    const next = String(value ?? "");
    if (key === painted) {
      if (open) reveal.openForVisit?.();
      promptEl.value = next;
      fit();
      if (focus) reveal.focusPrompt?.();
      if (caretEnd) caretToEnd();
    } else {
      entry(key).text = next;
    }
    save(key);
  }

  // +text+ into +key+'s draft when it is empty, never over one: "shown" (on
  // view: the composer opens, the box takes the focus), "stored", or false.
  function putBack(key, text) {
    if (has(key)) return false;
    const shown = key === painted;
    setText(key, text, { reveal: shown, focus: shown });
    return shown ? "shown" : "stored";
  }

  // +key+'s text emptied; its chips stay.
  function clear(key) {
    setText(key, "");
  }

  // +key+'s chips become +list+ (a chip left out frees its preview).
  function putChips(key, list) {
    heal();
    if (key === painted) {
      view.setChips(list);
      return;
    }
    const e = entry(key);
    freePreviews(e.chips, list);
    e.chips = list.slice();
  }

  // Empties +key+'s draft in place (its previews kept: they moved).
  function empty(key) {
    const e = entry(key);
    e.sent = null;
    if (key === painted) {
      promptEl.value = "";
      view.setChips([], { revoke: false });
      fit();
    } else {
      e.text = "";
      e.chips = [];
    }
    save(key);
  }

  // +from+'s draft goes to +to+: into an empty one as it is, else its text
  // under +to+'s and its chips after them. +from+ is emptied, its saved copy
  // gone.
  function move(from, to) {
    heal();
    if (from === to) return;
    const movedText = text(from);
    const movedChips = chips(from).slice();
    const sent = entry(from).sent;
    empty(from);
    if (!movedText.trim() && !movedChips.length) return;
    const had = has(to);
    const nextText = had ? restoreInto(movedText, text(to)) : movedText;
    const nextChips = had ? chips(to).concat(movedChips) : movedChips;
    if (!had) entry(to).sent = sent;
    if (to === painted) {
      promptEl.value = nextText;
      view.setChips(nextChips, { revoke: false });
      fit();
    } else {
      const e = entry(to);
      e.text = nextText;
      e.chips = nextChips;
    }
    save(to);
  }

  // Continue →: +from+'s draft goes to the next link +to+ (text or chips:
  // the whole draft, from emptied); an empty one leaves +to+ the +opener+
  // (none: nothing). A link with a draft of its own (one continued already)
  // keeps it.
  function handOver(from, to, opener = null) {
    if (has(to)) return;
    if (has(from)) move(from, to);
    else if (opener) setText(to, opener);
  }

  // +key+'s draft forgotten, here and in storage (its session was deleted):
  // its previews freed.
  function drop(key) {
    heal();
    freePreviews(chips(key));
    if (key === painted) {
      promptEl.value = "";
      view.setChips([], { revoke: false });
      fit();
    }
    kept.delete(key);
    if (key) forgetPref(COMPOSER_DRAFT, key);
    else removeStored(START_DRAFT);
  }

  // The window +key+ on view: the box and the chips swap to its draft. The
  // same key again changes nothing.
  function show(key) {
    if (key === painted) return;
    if (painted !== null) {
      flush();
      save(painted);
    }
    painted = key;
    paint(key);
  }

  // The box's input: saved as the draft on view.
  function syncFromView() {
    heal();
    if (painted !== null) save(painted);
  }

  // +line+ is in flight from +key+'s draft: the saved copy leaves it out.
  function sending(key, line) {
    entry(key).sent = line;
    save(key);
  }

  // The send of +line+ is over: the saved copy is the draft as it is again.
  function settle(key, line) {
    const e = entry(key);
    if (e.sent !== line) return;
    e.sent = null;
    save(key);
  }

  return { text, chips, has, setText, putBack, clear, putChips, move, handOver, drop, show, syncFromView, sending, settle };
}
