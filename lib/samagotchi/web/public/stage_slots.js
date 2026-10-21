// The stage view's live slots (stage_view.js): the headline, the asking
// text, the "now" row, the trail and the chip's ticks, each drawn from
// liveSlots (stage_model.js) and patched only when what it shows changes
// (+shown+), so an unchanged slot keeps its nodes: a selection in it
// survives, and its animations never restart (the ticks' blink; the
// headline's fade restarts on purpose at a new text).
import { FLASH_MARKS, trailFlashText, trailItemText, trailTone } from "./stage_model.js";
import { taskCommand, taskStopButton } from "./task_stop.js";

// The stage's one element helper (stage_view.js builds its skeleton with it).
export function node(tag, cls, parent = null) {
  const el = document.createElement(tag);
  if (cls) el.className = cls;
  if (parent) parent.appendChild(el);
  return el;
}

// +headline+, +asking+, +now+, +trail+, +ticks+: the slots' elements.
// +taskStop+: the page's stopper (task_stop.js), for the stop-task button
// on a running task_wait; +gens()+ the running turn's gens (the button's
// command, read at its click); +onChange+ redraws (the stage's
// scheduleRefresh). +renderMarkdown(text)+: the asking text's HTML
// (Promise<string|null>; null keeps the raw text: markdown off, a failed
// read); +linkRefs(el, refs)+: the page's ref pass on the slot (a
// plugin's +refs+ paired first, then the path:line ones).
export function createStageSlots({
  headline, asking, now, trail, ticks, taskStop = null, gens, onChange,
  renderMarkdown = () => Promise.resolve(null), linkRefs = () => {},
}) {
  // What each slot shows, so an unchanged slot is left alone.
  const shown = { headline: null, now: null, trail: null, asking: null, askingRefs: "" };
  // The refs the asking text is paired with (its pending question's).
  let askingRefs = null;
  // The last asking text sent to render and its answer (in flight or
  // done, HTML only): the same question drawn again (after a reset, a
  // blank between) asks no second time.
  let rendering = { text: null, html: null };

  function drawHeadline({ text, thinking }) {
    const key = `${thinking ? "t" : "n"}|${text}`;
    if (shown.headline === key) return;
    shown.headline = key;
    headline.replaceChildren();
    headline.classList.toggle("thinking", thinking);
    if (thinking) {
      const tag = node("span", "ts-think-tag", headline);
      tag.textContent = "thinking";
    }
    headline.appendChild(document.createTextNode(text));
    headline.classList.remove("fresh");
    void headline.offsetWidth;
    headline.classList.add("fresh");
  }

  // Patched only when the text changes (a late chunk to the closed gen
  // rewrites the same text): a selection in it survives. A new text reads
  // from its top: drawn raw at once, then swapped for its markdown when
  // that comes back while the slot still shows the same text (the text is
  // final: it shows only once the call that asks runs). +refs+: a plugin's
  // refs on it (the pending question's), paired on both draws; new refs on
  // the same text (a second question in the step) are paired in place.
  function drawAsking(text, refs = null) {
    asking.hidden = !text;
    const refsKey = text && Array.isArray(refs) && refs.length ? JSON.stringify(refs) : "";
    if (shown.asking === text) {
      if (shown.askingRefs === refsKey) return;
      shown.askingRefs = refsKey;
      askingRefs = refsKey ? refs : null;
      linkRefs(asking, askingRefs);
      return;
    }
    shown.asking = text;
    shown.askingRefs = refsKey;
    askingRefs = refsKey ? refs : null;
    asking.classList.remove("markdown", "md-compact");
    asking.textContent = text;
    asking.scrollTop = 0;
    if (!text) return;
    linkRefs(asking, askingRefs);
    if (rendering.text !== text) {
      let html;
      try { html = Promise.resolve(renderMarkdown(text)).catch(() => null); } catch (_) { html = Promise.resolve(null); }
      rendering = { text, html };
    }
    const pending = rendering;
    pending.html.then((html) => {
      // A null isn't kept: the next draw of this text asks again.
      if (!html && rendering === pending) rendering = { text: null, html: null };
      // Swapped once: a blank-then-same draw while in flight waits twice.
      if (!html || shown.asking !== text || asking.classList.contains("markdown")) return;
      // Sanitised on the server (POST /api/render), as an answer's HTML is.
      asking.innerHTML = html;
      asking.classList.add("markdown", "md-compact");
      asking.scrollTop = 0;
      linkRefs(asking, askingRefs);
      // Its height changed: the stage measures again (the question room).
      onChange?.();
    });
  }

  function drawNow(tool, quiet) {
    // A task_wait's stop button, as the row's (task_stop.js): in the key
    // with its in-flight state, so a redraw keeps a clicked one disabled.
    const stopId = tool?.taskId && taskStop?.target({ tool: "task_wait", status: "running", view: { task_id: tool.taskId } });
    const stopKey = stopId ? `|stop:${tool.key}:${taskStop.busy(stopId)}` : "";
    const key = tool ? `run|${tool.name}|${tool.title}|${tool.command || ""}${stopKey}` : `quiet|${quiet}`;
    if (shown.now === key) return;
    shown.now = key;
    now.replaceChildren();
    now.classList.toggle("running", !!tool);
    node("span", tool ? "ts-spin" : "ts-idle", now);
    if (tool) {
      const name = node("span", `ts-tool ${tool.kind}`, now);
      name.textContent = tool.name;
      const title = node("span", "ts-title", now);
      title.textContent = tool.title;
      // The full command when the call has one (the title is its first step +N).
      title.title = tool.command || tool.title;
      if (stopId) {
        const command = () => taskCommand(gens(), stopId);
        now.appendChild(taskStopButton(taskStop, stopId, { command, onChange }));
      }
    } else if (quiet) {
      const word = node("span", "ts-title quiet", now);
      word.textContent = quiet;
    }
  }

  // +flash+: the trail's flash ({ kind, text, until }), shown ahead of the
  // calls until its time is up.
  function drawTrail(items, flash) {
    const flashing = flash && flash.until > Date.now() ? flash : null;
    const key = JSON.stringify([flashing?.kind, flashing?.text, items]);
    if (shown.trail === key) return;
    shown.trail = key;
    trail.replaceChildren();
    if (flashing) {
      const flash = trailFlashText(flashing, FLASH_MARKS[flashing.kind]);
      const el = node("span", `ts-trail-item ${flashing.kind}`, trail);
      el.textContent = flash.text;
      el.title = flash.hover;
    }
    for (const item of items) {
      const tone = trailTone(item.status);
      const el = node("span", `ts-trail-item${tone ? ` ${tone}` : ""}`, trail);
      const { text, hover } = trailItemText(item);
      el.textContent = text;
      el.title = hover;
    }
    if (!flashing && !items.length) node("span", "ts-trail-item none", trail).textContent = "no tool calls yet";
  }

  function drawTicks(list) {
    list.forEach((tick, i) => {
      let el = ticks.children[i];
      if (!el) {
        el = node("span", "", ticks);
        el.setAttribute("role", "button");
      }
      const cls = `ts-tick ${tick.kind} ${tick.status}`;
      if (el.className !== cls) el.className = cls;
      el.dataset.step = String(tick.step);
      el.title = `step ${tick.step + 1}`;
    });
    while (ticks.children.length > list.length) ticks.lastChild.remove();
  }

  // A new turn (or none): the slots empty, the asking text hidden, the next
  // draw of each slot a fresh one.
  function reset() {
    for (const slot of [headline, asking, now, trail, ticks]) slot.replaceChildren();
    asking.hidden = true;
    asking.classList.remove("markdown", "md-compact");
    shown.headline = shown.now = shown.trail = shown.asking = null;
    shown.askingRefs = "";
    askingRefs = null;
  }

  return { drawHeadline, drawAsking, drawNow, drawTrail, drawTicks, reset };
}
