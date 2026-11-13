// The composer's mode on the owner page (used by app.js, the store's
// `composer` redraw): its placeholder, key hint, action button, the attach
// button, the start page's empty state and the delivery line's row, from the
// open session, its owner and whether its turn runs.

// A phone's composer fits a few words and has no Shift+Enter: the short
// placeholder there.
export const NARROW_QUERY = "(max-width: 600px)";

// The key hint under the composer (shown while it has focus; on the start
// page only: in a session the placeholder carries it, the hint row is gone).
export const SEND_HINT = "Enter to send · Shift+Enter for a newline · ↑ history";

// What the composer shows, pure: +selected+ the open session's id (null: the
// start page), +owner+ its owner, +running+ whether its turn runs, +narrow+ a
// phone's width. While a turn runs, Send still sends: the prompt merges into
// the turn at its next step (steering); Cancel is its own button then.
// @return {placeholder, hint, button, disabled, empty, clearHistory,
//   attachHidden, delivery}: +disabled+ undefined while a turn runs (the
//   button keeps whatever a send in flight set); +empty+ the start page's
//   empty state shown, +clearHistory+ #history emptied (the start page only);
//   +delivery+ the delivery line's mode (delivery_line.js show).
export function composerMode({ selected, owner, running, narrow }) {
  const session = !!selected;
  const tui = session && owner === "tui";
  const live = !!running && session;
  const pick = (long, short) => (narrow ? short : long);
  // No images for a session a terminal owns (it takes no message from here);
  // on a phone none while a turn runs either: the row keeps its room for the
  // message box (steering).
  const attachHidden = tui || (live && !!narrow);
  // The delivery line's row in a session: the key hint while idle, where a
  // message goes in while the turn runs. A terminal owns the session: the
  // composer is off, so is its row.
  const delivery = !session || tui ? "off" : running ? "running" : "idle";
  const base = { attachHidden, delivery, empty: false, clearHistory: false };
  if (live) {
    return {
      ...base,
      placeholder: pick("Running… a message goes in at the next step · Enter to send · Alt+Enter queues", "Steer the turn…"),
      hint: SEND_HINT, button: "Send", disabled: undefined,
    };
  }
  if (!session) {
    return {
      ...base,
      placeholder: "Ask chi anything…", hint: "Enter to start · Shift+Enter for a newline", button: "Start", disabled: false,
      empty: true, clearHistory: true,
    };
  }
  if (tui) {
    return {
      ...base,
      placeholder: pick("A terminal chi owns this session · a one-turn chi --non-interactive run or an older chi's terminal", "A terminal chi owns this session"),
      hint: "", button: "Send", disabled: true,
    };
  }
  // The keys are in the delivery line's row above.
  return { ...base, placeholder: "Message chi…", hint: SEND_HINT, button: "Send", disabled: false };
}

// The composer's mode drawn: update() is the store's `composer` redraw, and a
// window crossing the phone's width redraws it too (an input the store
// doesn't hold, with the composer as its only reader: the bar doesn't read it).
//
// +els+: {body, prompt, hint, button, attach, empty, history}. +store+: the
// page's session store (selected, current.owner; read only). +liveTurn+:
// live_turn.js's (running). +startPage+: start_page.js's (restoreStartPick,
// syncModelPick, dropChoices). +deliveryControl+: delivery_line.js's.
// +fitPrompt()+,
// +placeToast()+: the page's. +win+: the window (matchMedia).
export function createComposerMode({
  els, store, liveTurn, startPage, deliveryControl, fitPrompt, placeToast, win = globalThis,
}) {
  const narrowScreen = win.matchMedia(NARROW_QUERY);
  let hadSession = false;

  function update() {
    // In a session the box is one line: its minimum follows the class.
    if (els.body.classList.toggle("has-session", !!store.selected) !== hadSession) {
      hadSession = !hadSession;
      // Back on the start page: its remembered model, not the last link's.
      if (!hadSession) startPage.restoreStartPick();
      fitPrompt();
      placeToast();
    }
    startPage.syncModelPick();
    // The start page's choice was for a new session: opening a session drops it.
    if (store.selected) startPage.dropChoices();
    const mode = composerMode({
      selected: store.selected, owner: store.current.owner, running: liveTurn.running, narrow: narrowScreen.matches,
    });
    if (els.attach) els.attach.hidden = mode.attachHidden;
    deliveryControl.show(mode.delivery);
    els.prompt.placeholder = mode.placeholder;
    els.hint.textContent = mode.hint;
    els.button.textContent = mode.button;
    if (mode.disabled !== undefined) els.button.disabled = mode.disabled;
    els.empty.classList.toggle("hidden", !mode.empty);
    if (mode.clearHistory) els.history.replaceChildren();
  }

  // ⋯'s menu stays open across the width: chip_popover.js turns its sheet
  // into a popover (and back) on the resize.
  narrowScreen.addEventListener("change", () => update());

  return { update };
}
