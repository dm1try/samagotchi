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
import { hookNoticeLabel } from "./turn_events.js";
import { cancelLineHtml, formatDuration, turnGroups, turnTimingText } from "./timing.js";
import { createTicker } from "./thinking_ticker.js";
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
    const entry = { el, summary, thinking: null, text, activity: null, rows: new Map(), toggled: false,
      thinkingWrap: null, thinkingLine: null, ticker: null, tickerTimer: null, thinkingWritten: 0, thinkingToggled: false };
    rememberToggle(summary, () => { entry.toggled = true; });
    genEls.set(gen, entry);
    const follow = isNearBottom();
    blockEl.appendChild(el);
    if (follow) historyEl.scrollTop = historyEl.scrollHeight;
    return entry;
  }

  // The step's thinking as its own collapsed <details class="thinking"> (the
  // ticker lives in its summary) before the narration; entry.thinking stays
  // the body, entry.thinkingWrap the <details>, entry.thinkingLine its summary.
  function thinkingEl(gen) {
    const entry = genEls.get(gen);
    if (!entry.thinking) {
      entry.thinkingWrap = document.createElement("details");
      entry.thinkingWrap.className = "thinking";
      entry.thinkingLine = document.createElement("summary");
      entry.thinkingLine.textContent = "thinking";
      entry.thinkingWrap.appendChild(entry.thinkingLine);
      entry.thinking = document.createElement("div");
      entry.thinking.className = "thinking-body";
      entry.thinkingWrap.appendChild(entry.thinking);
      // A hand toggle: the ticker collapses back to one line, but a just-opened
      // body sits at scrollTop 0, so scroll it to its tail.
      entry.thinkingWrap.addEventListener("toggle", () => {
        if (entry.thinkingWrap.open) entry.thinking.scrollTop = entry.thinking.scrollHeight;
      });
      rememberToggle(entry.thinkingLine, () => { entry.thinkingToggled = true; });
      entry.ticker = createTicker({ now: () => Date.now(), dwellMs: 1500 });
      entry.el.insertBefore(entry.thinkingWrap, entry.text);
    }
    return entry.thinking;
  }

  // The ticker's newest sentence into the summary: "thinking · <line>", the
  // prefix a <span class="thinking-tag">, the sentence a text node.
  function setThinkingLine(entry, sentence) {
    entry.thinkingLine.textContent = "";
    const tag = document.createElement("span");
    tag.className = "thinking-tag";
    tag.textContent = "thinking · ";
    entry.thinkingLine.appendChild(tag);
    entry.thinkingLine.appendChild(document.createTextNode(sentence));
    // A subtle fade on change; the class is removed at close (reload parity:
    // the re-rendered summary is plain "thinking").
    entry.thinkingLine.classList.remove("thinking-fade");
    void entry.thinkingLine.offsetWidth;
    entry.thinkingLine.classList.add("thinking-fade");
  }

  // Feed the step's ticker from its accumulated thinking; the caller's timer
  // (entry.tickerTimer) shows a pending line when its dwell elapses.
  function feedTicker(gen) {
    const entry = genEls.get(gen);
    const { line, changed, dueIn } = entry.ticker.feed(gen.thinking);
    if (changed) setThinkingLine(entry, line);
    else if (dueIn > 0 && !entry.tickerTimer) {
      entry.tickerTimer = setTimeout(() => {
        entry.tickerTimer = null;
        const r = entry.ticker.tick();
        if (r.changed) setThinkingLine(entry, r.line);
      }, dueIn);
    }
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

  // The gen's text and thinking into its elements. The thinking is appended by
  // delta (a selection survives; a full rewrite would drop it) and rewritten
  // only when it shrank (the close's rtrim); the ticker advances from it while
  // the step is live. The trailing whitespace is trimmed by the model at close.
  function writeGen(gen, { follow = false } = {}) {
    const entry = genEls.get(gen);
    if (!entry) return;
    if (gen.thinking) {
      const body = thinkingEl(gen);
      const written = entry.thinkingWritten;
      if (gen.thinking.length >= written) {
        if (gen.thinking.length > written) {
          body.appendChild(document.createTextNode(gen.thinking.slice(written)));
          entry.thinkingWritten = gen.thinking.length;
        }
      } else {
        body.textContent = gen.thinking;
        entry.thinkingWritten = gen.thinking.length;
      }
      if (follow && shouldFollowScroll(body, 24)) body.scrollTop = body.scrollHeight;
      // Late chunks reach closed gens (genFor); their ticker stays still.
      if (!gen.closed) feedTicker(gen);
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
    if (entry.thinkingWrap) {
      // Stop the ticker, revert its summary to the plain "thinking" (reload
      // parity: no span, no fade class) and close the wrap — unless the user
      // opened it by hand. Flag the programmatic close so the toggle handler
      // does not mistake it for a hand toggle.
      if (entry.tickerTimer) { clearTimeout(entry.tickerTimer); entry.tickerTimer = null; }
      entry.ticker.close();
      entry.thinkingLine.textContent = "thinking";
      entry.thinkingWrap.classList.remove("thinking-fade");
      entry._autoClose = true;
      entry.thinkingWrap.open = !entry.thinkingToggled;
    }
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

  // A hook's line (hook_notice) as a row of the current step, above the row
  // of the call it judged; false with no running turn (app.js shows the
  // bubble then).
  function notice(data) {
    const r = turn && model.notice(turn, data);
    if (!r) return false;
    const entry = genEls.get(r.gen);
    if (!r.gen.text) entry.text.textContent = "";
    const el = document.createElement("div");
    el.className = "hook-notice" + (data.level === "warn" ? " warn" : "");
    el.textContent = `${hookNoticeLabel(data.hook)}: ${data.text || ""}`;
    const follow = isNearBottom();
    activityEl(r.gen).appendChild(el);
    if (follow) historyEl.scrollTop = historyEl.scrollHeight;
    return true;
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
        if (!entry.thinkingWrap) thinkingEl(gen);
        // Reuse the live step's thinking wrap, re-classed as the plain
        // answer's collapsed block (the same element, not a new one): plain
        // summary, no timer, closed unless the user toggled it.
        if (entry.tickerTimer) { clearTimeout(entry.tickerTimer); entry.tickerTimer = null; }
        entry.ticker.close();
        entry.thinkingWrap.className = "bubble thinking";
        entry.thinkingWrap.open = false;
        entry.thinkingLine.textContent = "thinking";
        pieces.push(entry.thinkingWrap);
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
    // Clear every ticker timer before the map goes (a live step mid-dwell).
    for (const entry of genEls.values()) {
      if (entry.tickerTimer) { clearTimeout(entry.tickerTimer); entry.tickerTimer = null; }
    }
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
    notice,
    flush,
    // The live gen's narration is rewritten each frame; its thinking is
    // appended by delta (the ticker), but a selection is still refused while
    // the step is live — the quote lands once it closes.
    containsLive(el) {
      const gen = turn && model.currentGen(turn);
      const entry = gen && genEls.get(gen);
      return !!entry && (entry.text.contains(el) || !!entry.thinking?.contains(el));
    },
    reset,
  };
}

// A reloaded tool row, the live row's markup (chat_view.js
// fillActivityRow): status, tool, params, output (its "[tool]" tag dropped,
// 300 chars, the rest on hover), plus the call's duration from its record.
// Params and output come from the saved messages' parts; without them the
// row has the record's name, status and duration only.
function reloadRowHtml(r) {
  const params = r.params ? `<span class="activity-params">${escapeHtml(r.params)}</span>` : "";
  const duration = formatDuration(r.duration_ms);
  const full = String(r.output || "").replace(/^\[[^\]]*\]\s*/, "");
  const output = full
    ? `<div class="activity-output" title="${escapeHtml(full)}">${escapeHtml(full.length > 300 ? `${full.slice(0, 300)}…` : full)}</div>`
    : "";
  return `<div class="activity-row" data-key="${escapeHtml(r.key)}"><span class="activity-status ${activityStatusClass(r.status)}">${activityStatusLabel(r.status)}</span>` +
    `<span class="activity-tool">${escapeHtml(r.tool || "tool")}</span>${params}${duration ? `<span class="activity-duration">${escapeHtml(duration)}</span>` : ""}${output}</div>`;
}

// A reloaded history in the turn view (renderHistory's object path): per
// turn the prompt, a collapsed block of its steps when it had any (texts,
// and with the server's parts the thinking, params and output, from the
// saved messages; status and duration from the timing's tool records),
// then the answer and the turn's timing line under it.
// +thumbs(images)+ draws a prompt's image thumbs.
export function turnHistoryHtml(items, timing, { thumbs }) {
  const timingHtml = (group) => {
    const record = group.record;
    return record && formatDuration(record.duration_ms)
      ? `<div class="turn-timing">${escapeHtml(turnTimingText(group.turnIndex + 1, record.duration_ms, { canceled: record.status === "canceled" }))}</div>`
      : "";
  };
  // The timing line after the bubble, not in it: where the live view
  // leaves it at the turn's end.
  const answerHtml = (m, timing) => {
    const { body, renderedMarkdown } = messageBodyHtml(m);
    return `<div class="bubble output${renderedMarkdown ? " markdown" : ""}"${copySourceAttr(m, renderedMarkdown)}>${body}</div>${timing}`;
  };
  return turnGroups(items, timing).map((group) => {
    if (group.kind === "note") return `<div class="bubble note">${noteHtml(items[group.i])}</div>`;
    if (group.kind === "answer") return answerHtml(items[group.answer], "");
    const prompt = items[group.user];
    const parts = [`<div class="bubble user"${copySourceAttr(prompt, false)}><div class="user-message">${messageBodyHtml(prompt).body}${thumbs(prompt.images)}</div></div>`];
    const [only] = group.steps;
    if (group.steps.length === 1 && group.answer !== null && only.i === null && !only.tools.length && only.thinking) {
      // A plain answer with thinking: the chat view's collapsed block, as live.
      parts.push(`<details class="bubble thinking"><summary>thinking</summary><div class="thinking-body">${escapeHtml(only.thinking)}</div></details>`);
    } else if (group.steps.length) {
      const gens = group.steps.map((step) => ({ text: step.i === null ? "" : String(items[step.i].content ?? ""), thinking: step.thinking || "", tools: step.tools }));
      const rows = gens.map((gen) => {
        const thinking = gen.thinking ? `<div class="thinking-body">${escapeHtml(gen.thinking)}</div>` : "";
        const text = gen.text ? `<div class="gen-text">${escapeHtml(gen.text)}</div>` : "";
        const tools = gen.tools.length ? `<div class="activity-body">${gen.tools.map(reloadRowHtml).join("")}</div>` : "";
        return `<details class="gen"><summary>${escapeHtml(model.genLabel(gen))}</summary>${thinking}${text}${tools}</details>`;
      });
      parts.push(`<details class="turn-work done"><summary>${escapeHtml(model.blockSummary({ gens, ended: true }))}</summary>${rows.join("")}</details>`);
    }
    // A turn with no answer (canceled, or running: no record yet) shows its
    // timing after its prompt and steps, where the live view leaves it.
    if (group.answer === null) parts.push(timingHtml(group));
    else parts.push(answerHtml(items[group.answer], timingHtml(group)));
    // A canceled turn ends with its cancel line, as the live view left it.
    parts.push(cancelLineHtml(group.record, escapeHtml));
    return parts.join("");
  }).join("");
}
