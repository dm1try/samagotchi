// The × on a message queued for after the running turn (its badge,
// turn_html.js stateBadgeTemplate): POST …/turn/:enqueued_id/dequeue
// (Bridge#handle_dequeue_turn) takes it back before it runs. The bubble
// goes with the turn_dequeued every tab gets (bubbles.js op "remove"), and
// here at the 200 already. A refusal keeps it and says why in a toast. No
// confirm: nothing is lost that the user can't type again. Pure but for the
// injected calls, so `node --test` covers it; app.js binds onClick to the
// turn roots.
import { dequeueTurn as postDequeue } from "./data.js";

// Why a removal didn't happen, in words.
export function unqueueFailureText(error) {
  if (error?.code === "already_started") return "Not removed: it already started";
  if (error?.code === "not_queued") return "Not removed: it goes in at the running turn's next step";
  if (error?.status === 404 && error?.code === "unknown_enqueued_id") return "Not removed: it is already gone";
  return `Not removed: ${error?.message || "the worker did not answer"}`;
}

// +sessionId+ is read at each click (the open session); +clientId+ is this
// tab's (the turn_dequeued names who removed it).
export function createUnqueue({ sessionId, clientId = null, dequeue = postDequeue, toast = () => {} }) {
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
      bubble.remove();
      return result;
    } catch (error) {
      if (button.isConnected) button.disabled = false;
      toast(unqueueFailureText(error));
      return null;
    }
  }
  return { onClick };
}
