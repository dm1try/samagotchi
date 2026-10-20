import { routeComposerLine, routeSessionLine } from "./composer.js";
import { chipsAfterSend, restoredChips, turnRefs, turnText, uploadChips } from "./images.js";
import { cantText, firstPreview } from "./format.js";
import { setBubbleDelivery } from "./bubbles.js";
import { composerAfterAck, dropEarlyRestores, restoreOnAck } from "./restore.js";

// The composer's send (used by app.js): a line into the open session, or
// on the start page a new session first (an idle one, then the line as for
// any later one, so a failed first turn's prompt comes back into the
// composer too). The route (composer.js), the echo, the images' upload, the
// /turn and its ack, a fast failure's restore (restore.js) and the error's
// words.
//
// Hooks: +session()+ the open session's id or null; +state()+ its fields
// (session_state.js: owner, commands, firstPreview); +running()+ a turn
// runs; +clientId+; +sentIds+ / +earlyRestores+ (restore.js' bookkeeping);
// +api+: {createIdleSession, uploadImage, sendTurn} (data.js); +dir+: the
// page's scope folder (new sessions start there); +startPage+
// (start_page.js: pendingPick(), chosenModel(), newChoices(),
// clearChoices()); +takeDelivery()+ the delivery line's armed choice;
// +composer+: {el (the text box), button (Send/Start), chips(),
// setChips(list), fit(), clear(), openForVisit(), focus()}; +historyEl+,
// +turnDom+; +makeUserBubble(prompt, opts)+, +bubbleById(id)+,
// +addCommandBubble(view)+; +addCreatedSession(created)+, +select(id)+,
// +showNotice(text)+, +updateInfoBar()+, +updateComposerMode()+,
// +followWokenWorker()+, +refreshHistory()+, +leaveGoneSession(id, why)+,
// +runCommand(command)+ (composer.js send), +toast(text, action, options)+;
// +alert+: the browser's.
export function createSendTurn({
  session, state, running, clientId, sentIds, earlyRestores, api, dir, startPage, takeDelivery, composer,
  historyEl, turnDom, makeUserBubble, bubbleById, addCommandBubble,
  addCreatedSession, select, showNotice, updateInfoBar, updateComposerMode, followWokenWorker, refreshHistory,
  leaveGoneSession, runCommand, toast, alert = (text) => globalThis.alert(text),
}) {
  const promptEl = composer.el;
  const actionBtn = composer.button;

  // +delivery+: the composer's choice for a running turn (Alt+Enter: queue;
  // a delivery-line link: cut or queue); else the armed one; a typed /cut or
  // /queue wins over both.
  async function send({ delivery: chosen = null } = {}) {
    if (state().owner === "tui") return;
    // A fresh link's pick first: its /model is queued in the worker once
    // acked, and the worker runs queued commands before a turn's input.
    const pick = startPage.pendingPick();
    if (pick) await pick;
    let prompt = turnText(promptEl.value, composer.chips());
    if (!prompt) return;
    const armed = takeDelivery();
    // An image-only send's text is its placeholders: not for ↑.
    const typed = promptEl.value.trim() !== "";
    // The composer holds the line as typed until the ack (composerAfterAck).
    const line = prompt;
    // Where the line goes (composer.js): the page's own reply, a session to
    // make first (the start page), a command, or a turn.
    let route = routeComposerLine(prompt, {
      session: !!session(), running: running(), commands: state().commands, images: composer.chips().length,
    });
    if (route.create) {
      actionBtn.disabled = true;
      try {
        const s = await api.createIdleSession({ dir, model: startPage.chosenModel(), preview: route.send,
                                                ...startPage.newChoices() });
        // The choice was for this chat only.
        startPage.clearChoices();
        addCreatedSession(s);
        await select(s.id);
      } catch (e) {
        alert(e.message);
        return;
      } finally {
        actionBtn.disabled = false;
      }
      // In the new session, by its command list (select read it).
      route = routeSessionLine(route.send, { commands: state().commands, images: composer.chips().length, delivery: route.delivery });
    }
    if (route.reply) {
      // The start page's reply is a notice: no session is made for it (2.29).
      if (session()) addCommandBubble({ label: null, line: route.line, text: route.reply });
      else showNotice(route.reply);
      composer.clear();
      return;
    }
    if (route.command) return runCommand(route.command);
    prompt = route.send;
    const isRunning = running() && !!session();
    const delivery = route.delivery || (isRunning ? chosen || armed : null);
    const hint = historyEl.querySelector(".hint");
    if (hint) hint.remove();
    // Sending moves a finished turn out of the stage at once (else the echo
    // would land among its rows); into a running one it is a queued row there.
    turnDom.handOff?.({ immediate: true });
    const sending = composer.chips().slice();
    // Into a running turn the echo says what it waits for (its delivery); a
    // line with images always waits for the turn's end (the worker queues it).
    const shownDelivery = isRunning ? (sending.length ? "queue" : delivery || "next_step") : null;
    const echo = makeUserBubble(prompt, { state: "queued", own: true, images: sending, delivery: shownDelivery });
    if (!turnDom.holds?.()) historyEl.scrollTop = historyEl.scrollHeight;
    if (!state().firstPreview || state().firstPreview === "—") {
      state().firstPreview = firstPreview(prompt);
      updateInfoBar();
    }
    actionBtn.disabled = true;
    // The session the line goes to: the page may switch to another while an
    // image uploads or the turn is sent, and what follows stays with this one.
    const sentTo = session();
    try {
      await uploadChips(sending, sentTo, { upload: api.uploadImage });
      const ack = await api.sendTurn(sentTo, prompt, { clientId, images: turnRefs(sending), history: typed, delivery });
      if (ack?.command_id) {
        // The worker knew it as a command (its list was newer than ours):
        // its command_ran shows it, not a prompt bubble.
        echo.remove();
        composer.clear();
        if (sentTo === session()) followWokenWorker();
        return;
      }
      if (ack?.enqueued_id) sentIds.add(ack.enqueued_id);
      // A cut the worker didn't take (no thinking-only step: cut off) goes in
      // at the next step; a queue whose turn ended meanwhile is the next turn.
      if (ack?.cut === "off" || (ack?.delivery === "next_step" && echo.dataset.delivery === "queue")) {
        setBubbleDelivery(echo, ack.cut === "off" ? "next_step" : null);
      }
      refreshHistory();
      // A turn that failed fast was restored before this ack: its prompt
      // (and images) go back into the composer, without replacing text typed
      // since (4.13). The composer still holds the text just sent: it goes.
      const restored = restoreOnAck(ack?.enqueued_id, earlyRestores, { myId: clientId, sentIds });
      // A restored line must be seen: the composer opens for this visit.
      if (restored?.refill && sentTo === session()) composer.openForVisit();
      promptEl.value = composerAfterAck({ sent: line, current: promptEl.value, refill: restored?.refill || "" });
      composer.fit();
      // Only the sent chips go: images added since stay (they go up at their own send).
      const kept = chipsAfterSend(composer.chips(), sending);
      composer.setChips(restored?.images?.length ? kept.concat(restoredChips(sentTo, restored.images)) : kept);
      // Its turn_enqueued usually tagged the echo already; the ack covers a
      // worker that wasn't live (no turn_enqueued then).
      if (ack?.enqueued_id && !echo.dataset.enqueuedId && !bubbleById(ack.enqueued_id)) {
        echo.dataset.enqueuedId = ack.enqueued_id;
      }
      // A live stream carries this turn already; restarting it would drop the
      // events in between. Without one, POST /turn just woke a worker: its
      // events start after the seq the session was rendered at (0 for a new
      // worker process). A switch since then opened the other session's own.
      if (sentTo === session()) followWokenWorker();
    } catch (e) {
      echo.remove();
      // The turn never reached the worker's queue: an early restore waiting
      // for its ack is never taken back (4.13), so drop it here. The prompt
      // is still in the composer, as the echo was removed.
      dropEarlyRestores(earlyRestores);
      // The chips stay (uploaded ones keep their ref, to sentTo) for another try: an
      // image refused (bad_image, too_large, bad_images) says why below.
      if (e.code === "owned_by_tui") {
        if (sentTo !== session()) return toast(cantText(`send to ${sentTo.slice(0, 8)}`, e), null, { sticky: true });
        state().owner = "tui";
        updateComposerMode();
        return;
      }
      // A stale tab sent into a session deleted meanwhile: the start page
      // says so, and the line stays in the composer.
      if (e.code === "not_found") return leaveGoneSession(sentTo, "not_found");
      // A /queue to a worker that can't queue (it would steer): its words, the text kept.
      if (e.code === "delivery_unavailable" && sentTo === session()) return addCommandBubble({ label: null, line, text: e.body?.detail || e.message, failed: true });
      toast(cantText("send", e), null, { sticky: true });
    } finally {
      actionBtn.disabled = state().owner === "tui";
      composer.focus();
    }
  }

  return { send };
}
