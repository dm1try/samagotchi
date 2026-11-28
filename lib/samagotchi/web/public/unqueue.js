// The × on a message queued for after the running turn (its badge,
// turn_html.js stateBadgeTemplate): POST …/turn/:enqueued_id/dequeue
// (Bridge#handle_dequeue_turn) takes it back before it runs. The bubble
// goes with the turn_dequeued every tab gets (bubbles.js op "remove"), and
// here at the 200 already. Its text comes back (edit) into the draft of the
// session it was queued in when that draft is empty, to change and send
// again: the open session's, or after a switch meanwhile the one left (a
// toast says where); over a draft only in a toast (the draft stays), after a
// switch a sticky one naming its session, with Copy. Its images don't come
// back. A refusal keeps it
// and says why in a toast. No confirm: nothing is lost. Pure but for the
// injected calls, so `node --test` covers it; app.js binds onClick to the
// turn roots.
import { dequeueTurn as postDequeue } from "./data.js";
import { removeQueuedBubble } from "./bubbles.js";

// Why a removal didn't happen, in words.
export function unqueueFailureText(error) {
  if (error?.code === "already_started") return "Not removed: it already started";
  if (error?.code === "not_queued") return "Not removed: it goes in at the running turn's next step";
  if (error?.status === 404 && error?.code === "unknown_enqueued_id") return "Not removed: it is already gone";
  return `Not removed: ${error?.message || "the worker did not answer"}`;
}

// The removed text in a toast, clipped.
const SHOWN = 200;
function clipped(text) {
  const line = String(text || "").replace(/\s+/g, " ").trim();
  return line.length > SHOWN ? `${line.slice(0, SHOWN)}\u2026` : line;
}

// +sessionId+ is read at each click (the open session); +clientId+ is this
// tab's (the turn_dequeued names who removed it); +putBackTo(text, id)+
// puts it into session id's draft when that is empty: "shown" (the open
// one's), "stored" (another's), false (a draft was there); an older cached
// app.js passes only +putBack(text)+, the open composer's (true when it took
// it), and a switch meanwhile leaves the text to the toast; +copy(text)+ says
// whether the clipboard took it; +toast(text, action, options)+ as showToast.
export function createUnqueue({ sessionId, clientId = null, dequeue = postDequeue, toast = () => {}, putBack = () => false, putBackTo = null, copy = null }) {
  // A click on a queued bubble's ×; any other click is left alone.
  async function onClick(e) {
    const button = e.target?.closest?.("button.unqueue");
    if (!button || button.disabled) return null;
    const bubble = button.closest(".bubble.user");
    const enqueuedId = bubble?.dataset.enqueuedId;
    const id = sessionId();
    if (!enqueuedId || !id) return null;
    e.stopPropagation?.();
    button.disabled = true;
    try {
      const result = await dequeue(id, enqueuedId, { clientId });
      removeQueuedBubble(bubble);
      const text = String(result?.prompt || "");
      if (!text.trim()) return result;
      if (putBackTo) {
        const put = putBackTo(text, id);
        if (put === "stored") toast(`Removed: back in ${id.slice(0, 8)}'s draft`);
        else if (!put && sessionId() !== id) movedOn(id, text);
        else if (!put) toast(`Removed (your draft stays): ${clipped(text)}`);
        return result;
      }
      // Another session opened meanwhile: its composer isn't where this
      // text goes, so only the toast has it.
      if (sessionId() !== id) {
        movedOn(id, text);
        return result;
      }
      if (!putBack(text)) toast(`Removed (your draft stays): ${clipped(text)}`);
      return result;
    } catch (error) {
      if (button.isConnected) button.disabled = false;
      toast(unqueueFailureText(error));
      return null;
    }
  }
  // The removed text after a switch: in a sticky toast, its Copy takes the
  // whole text (the toast clips it); a failed copy shows the toast again.
  function movedOn(id, text) {
    const line = `Removed from ${id.slice(0, 8)}: ${clipped(text)}`;
    const show = () => toast(line, copy ? action : null, { sticky: true });
    const action = { label: "Copy", run: async () => { if (await copy(text)) toast("Copied"); else show(); } };
    show();
  }
  return { onClick };
}
