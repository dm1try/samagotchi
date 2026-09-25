// The turn view of a running turn (web.turn_view): one <details
// class="turn-work"> per turn holding one <details class="gen"> per
// generation, the current one live (open, at the bottom), the earlier ones
// collapsed to one line each. At the turn's end the last generation's
// narration moves out of the block as the answer bubble, so markdown,
// annotate and the turn output dedupe work as in the chat view. The same
// interface as chat_view.js; the grouping rules live in turn_model.js.
//
// A block that holds one gen with no thinking and no tool rows hides its
// chrome (CSS :has), so a plain answer streams like today's bubble, and is
// removed at the end: the answer bubble takes its place.
import { activityStatusClass, activityStatusLabel, fillActivityRow } from "./chat_view.js";
import { copySourceAttr } from "./copy.js";
import { escapeHtml, messageBodyHtml, noteHtml, normalize } from "./format.js";
import { shouldFollowScroll } from "./scroll.js";
import { formatDuration, turnGroups, turnTimingText } from "./timing.js";
import * as model from "./turn_model.js";

export function createTurnView({ historyEl, appendToHistory, isNearBottom, sawText, sessionId }) {
  let turn = null;
  let blockEl = null;
  let blockSummaryEl = null;
  let blockToggled = false;
  // gen → { el, summary, thinking, text, activity, rows: Map(key → el), toggled }
  const genEls = new Map();
  const dirty = new Set();
  let rafPending = false;

  function removeHint() {
    const hint = historyEl.querySelector(".hint");
    if (hint) hint.remove();
  }

  // A hand toggle: the code's auto-collapse then leaves it as the user left it.
  function rememberToggle(summary, mark) {
    summary.addEventListener("click", mark);
  }

  function createBlock() {
    removeHint();
    blockEl = document.createElement("details");
    blockEl.className = "turn-work";
    blockEl.open = true;
    blockToggled = false;
    blockSummaryEl = document.createElement("summary");
    blockEl.appendChild(blockSummaryEl);
    rememberToggle(blockSummaryEl, () => { blockToggled = true; });
    updateBlockSummary();
    appendToHistory(blockEl);
  }

  function updateBlockSummary() {
    if (blockSummaryEl && turn) blockSummaryEl.textContent = model.blockSummary(turn, { running: !turn.ended });
  }

  function createGenEl(gen) {
    const el = document.createElement("details");
    el.className = "gen live";
    el.open = true;
    const summary = document.createElement("summary");
    summary.textContent = `step ${turn.gens.length}`;
    el.appendChild(summary);
    const text = document.createElement("div");
    text.className = "gen-text streaming";
    // A step after the first shows "…" until its text comes (the first one
    // only for a prompt, as the chat view's bubble).
    if (turn.gens.length > 1) text.textContent = "…";
    el.appendChild(text);
    const entry = { el, summary, thinking: null, text, activity: null, rows: new Map(), toggled: false };
    rememberToggle(summary, () => { entry.toggled = true; });
    genEls.set(gen, entry);
    const follow = isNearBottom();
    blockEl.appendChild(el);
    if (follow) historyEl.scrollTop = historyEl.scrollHeight;
    return entry;
  }

  function thinkingEl(gen) {
    const entry = genEls.get(gen);
    if (!entry.thinking) {
      entry.thinking = document.createElement("div");
      entry.thinking.className = "thinking-body";
      entry.el.insertBefore(entry.thinking, entry.text);
    }
    return entry.thinking;
  }

  function activityEl(gen) {
    const entry = genEls.get(gen);
    if (!entry.activity) {
      entry.activity = document.createElement("div");
      entry.activity.className = "activity-body";
      entry.el.appendChild(entry.activity);
    }
    return entry.activity;
  }

  // The gen's text and thinking into its elements (the trailing whitespace
  // is trimmed by the model when it closes).
  function writeGen(gen, { follow = false } = {}) {
    const entry = genEls.get(gen);
    if (!entry) return;
    if (gen.thinking) {
      const body = thinkingEl(gen);
      const followThinking = follow && shouldFollowScroll(body, 24);
      body.textContent = gen.thinking;
      if (followThinking) body.scrollTop = body.scrollHeight;
    }
    // An empty text keeps the "…" placeholder.
    if (gen.text) entry.text.textContent = gen.text;
  }

  function flush() {
    rafPending = false;
    // Runs every animation frame while streaming — must not yank a user who
    // scrolled up to read; only follow when they were already near the bottom.
    const follow = isNearBottom();
    for (const gen of dirty) writeGen(gen, { follow: true });
    dirty.clear();
    if (follow) historyEl.scrollTop = historyEl.scrollHeight;
  }

  function scheduleFlush(gen) {
    dirty.add(gen);
    if (rafPending) return;
    rafPending = true;
    requestAnimationFrame(flush);
  }

  // A closed gen: its final text, collapsed to its label (unless the user
  // opened it by hand), no longer live.
  function closeGenEl(gen) {
    const entry = genEls.get(gen);
    if (!entry) return;
    dirty.delete(gen);
    writeGen(gen);
    if (!gen.text) entry.text.textContent = "";
    entry.text.classList.remove("streaming");
    entry.el.classList.remove("live");
    entry.summary.textContent = model.genLabel(gen);
    if (!entry.toggled) entry.el.open = false;
    // The chat view puts every generation's text in seenContent.
    const k = normalize(gen.text);
    if (k) sawText(k);
  }

  function apply(r) {
    if (!r) return;
    if (r.closed) closeGenEl(r.closed);
    if (r.opened) createGenEl(r.gen);
    if (r.closed || r.opened) updateBlockSummary();
  }

  function toolEvent(r) {
    apply(r);
    const entry = genEls.get(r.gen);
    // A step that wrote no narration before its calls drops the "…".
    if (!r.gen.text) entry.text.textContent = "";
    const body = activityEl(r.gen);
    let el = entry.rows.get(r.row.key);
    if (!el) {
      el = document.createElement("div");
      el.className = "activity-row";
      el.dataset.key = r.row.key;
      for (const [tag, cls] of [["span", "activity-status"], ["span", "activity-tool"], ["span", "activity-params"], ["div", "activity-output"]]) {
        const part = document.createElement(tag);
        part.className = cls;
        el.appendChild(part);
      }
      el.querySelector(".activity-output").style.display = "none";
      entry.rows.set(r.row.key, el);
      const follow = isNearBottom();
      body.appendChild(el);
      fillActivityRow(el, r.row, sessionId());
      if (follow) historyEl.scrollTop = historyEl.scrollHeight;
    } else {
      fillActivityRow(el, r.row, sessionId());
    }
    updateBlockSummary();
  }

  // The answer: the gen's narration moves out of the block as a bubble.
  function promote(gen) {
    const entry = genEls.get(gen);
    const bubble = entry.text;
    bubble.className = "bubble output";
    if (!gen.text) bubble.textContent = "";
    entry.text = document.createElement("div");
    entry.text.className = "gen-text";
    entry.summary.textContent = model.genLabel({ ...gen, text: "" });
    model.takeAnswer(turn, gen);
    if (!gen.thinking && gen.tools.length === 0) entry.el.remove();
    if (turn.gens.length === 1 && gen.tools.length === 0) {
      // A plain answer: no block, the bubble where it was (as the chat
      // view); its thinking, if any, as the chat view's collapsed block.
      const pieces = [];
      if (gen.thinking) {
        const thinking = document.createElement("details");
        thinking.className = "bubble thinking";
        const summary = document.createElement("summary");
        summary.textContent = "thinking";
        thinking.appendChild(summary);
        thinking.appendChild(entry.thinking);
        pieces.push(thinking);
      }
      if (gen.text) pieces.push(bubble);
      blockEl.replaceWith(...pieces);
      blockEl = null;
      blockSummaryEl = null;
    } else if (gen.text) {
      appendToHistory(bubble);
    }
  }

  function turnEnded({ kind }) {
    if (!turn) return;
    const last = model.currentGen(turn);
    apply(model.turnEnded(turn));
    // A completed turn's answer is its last generation's text; a one-step
    // turn without tools leaves the block in any case (canceled, it is the
    // partial text bubble the chat view leaves).
    if (last && (kind === "completed" || (turn.gens.length === 1 && last.tools.length === 0))) promote(last);
    if (blockEl) {
      updateBlockSummary();
      blockEl.classList.add("done");
      if (!blockToggled) blockEl.open = false;
    }
    dirty.clear();
    rafPending = false;
  }

  function reset() {
    turn = null;
    blockEl = null;
    blockSummaryEl = null;
    blockToggled = false;
    genEls.clear();
    dirty.clear();
    rafPending = false;
  }

  return {
    turnStarted(data) {
      reset();
      turn = model.newTurn();
      createBlock();
      const r = model.turnStarted(turn);
      apply(r);
      if (data.prompt) genEls.get(r.gen).text.textContent = "…";
    },
    generationStarted(data) {
      if (!turn) this.turnStarted({});
      apply(model.generationStarted(turn, data.iteration ?? null));
    },
    chunk({ text, thinking, iteration }) {
      if (!text && !thinking) return;
      if (!turn) this.turnStarted({});
      const r = model.chunk(turn, { text, thinking, iteration });
      apply(r);
      scheduleFlush(r.gen);
    },
    generationCompleted() {
      if (!turn) return;
      const r = model.generationCompleted(turn);
      // The text lands on the next animation frame; a generation can end
      // before one runs (a burst of frames, a hidden tab).
      if (r) writeGen(r.gen);
    },
    toolStarted(data) {
      if (!turn) this.turnStarted({});
      toolEvent(model.toolStarted(turn, data));
    },
    toolCompleted(data) {
      if (!turn) this.turnStarted({});
      toolEvent(model.toolCompleted(turn, data));
    },
    turnEnded,
    flush,
    // The live gen's thinking and narration are rewritten every frame.
    containsLive(el) {
      const gen = turn && model.currentGen(turn);
      const entry = gen && genEls.get(gen);
      return !!entry && (entry.text.contains(el) || !!entry.thinking?.contains(el));
    },
    reset,
  };
}

// A reloaded history in the turn view (renderHistory's object path): per
// turn the prompt, a collapsed block of its steps when it had any (texts
// from the saved messages, tool rows from the timing's tool records: name,
// status and duration, no params or output), then the answer with the
// turn's timing. A plain answer renders as the chat view does.
// +thumbs(images)+ draws a prompt's image thumbs.
export function turnHistoryHtml(items, timing, { thumbs }) {
  const timingHtml = (group) => {
    const record = group.record;
    return record && formatDuration(record.duration_ms)
      ? `<div class="turn-timing">${escapeHtml(turnTimingText(group.turnIndex + 1, record.duration_ms, { canceled: record.status === "canceled" }))}</div>`
      : "";
  };
  const answerHtml = (m, timing) => {
    const { body, renderedMarkdown } = messageBodyHtml(m);
    return `<div class="bubble output${renderedMarkdown ? " markdown" : ""}"${copySourceAttr(m, renderedMarkdown)}>${body}${timing}</div>`;
  };
  return turnGroups(items, timing).map((group) => {
    if (group.kind === "note") return `<div class="bubble note">${noteHtml(items[group.i])}</div>`;
    if (group.kind === "answer") return answerHtml(items[group.answer], "");
    const prompt = items[group.user];
    const parts = [`<div class="bubble user"${copySourceAttr(prompt, false)}><div class="user-message">${messageBodyHtml(prompt).body}${thumbs(prompt.images)}</div></div>`];
    if (group.steps.length) {
      const gens = group.steps.map((step) => ({ text: step.i === null ? "" : String(items[step.i].content ?? ""), thinking: "", tools: step.tools }));
      const rows = gens.map((gen) => {
        const text = gen.text ? `<div class="gen-text">${escapeHtml(gen.text)}</div>` : "";
        const tools = gen.tools.length
          ? `<div class="activity-body">${gen.tools.map((r) =>
            `<div class="activity-row" data-key="${escapeHtml(r.key)}"><span class="activity-status ${activityStatusClass(r.status)}">${activityStatusLabel(r.status)}</span>` +
            `<span class="activity-tool">${escapeHtml(r.tool || "tool")}</span><span class="activity-params">${escapeHtml(formatDuration(r.duration_ms))}</span></div>`).join("")}</div>`
          : "";
        return `<details class="gen"><summary>${escapeHtml(model.genLabel(gen))}</summary>${text}${tools}</details>`;
      });
      parts.push(`<details class="turn-work done"><summary>${escapeHtml(model.blockSummary({ gens, ended: true }))}</summary>${rows.join("")}</details>`);
    }
    // A turn with no answer (canceled, or running: no record yet) shows its
    // timing after its prompt and steps, where the live view leaves it.
    if (group.answer === null) parts.push(timingHtml(group));
    else parts.push(answerHtml(items[group.answer], timingHtml(group)));
    return parts.join("");
  }).join("");
}
