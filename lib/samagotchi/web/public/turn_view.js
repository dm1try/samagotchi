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
import { createSentenceFeed } from "./sentences.js";
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
  // The promoted answer bubble while it is held at the box's height (the
  // pop, D6): { bubble, timer, follow }.
  let held = null;

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
      thinkingWrap: null, thinkingLine: null, ticker: null, tickerTimer: null, thinkingWritten: 0, thinkingToggled: false,
      feed: createSentenceFeed(), box: null };
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
      // A real click on the summary is a hand toggle of *this* step: its wrap
      // then stays as the user left it at the step's end. A peek is per step
      // (the page is for glancing): later steps start closed. The toggle
      // event (queued after <details>.open flips) only scrolls the body to
      // its tail on open.
      rememberToggle(entry.thinkingLine, () => { entry.thinkingToggled = true; });
      entry.thinkingWrap.addEventListener("toggle", () => {
        if (entry.thinkingWrap.open) entry.thinking.scrollTop = entry.thinking.scrollHeight;
      });
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

  // The live step's narration box (D1–D4 of the narration-box plan): the
  // complete sentences so far, one per line, the newest last, inside
  // entry.text (so the plain-answer chrome and containsLive see one element).
  // Created on the first sentence, in place of the "…" placeholder.
  function narrationBox(entry) {
    if (!entry.box) {
      entry.text.textContent = "";
      entry.box = document.createElement("div");
      entry.box.className = "narration";
      entry.text.appendChild(entry.box);
    }
    return entry.box;
  }

  // Append complete sentences to the box, which follows its own tail unless
  // the user scrolled up inside it to read (decided before the append: a
  // burst lands several lines at once).
  function appendSentences(entry, sentences) {
    if (!sentences.length) return;
    const box = narrationBox(entry);
    const stick = shouldFollowScroll(box, 24);
    for (const sentence of sentences) {
      const line = document.createElement("div");
      line.className = "sentence";
      line.textContent = sentence;
      box.appendChild(line);
    }
    if (stick) box.scrollTop = box.scrollHeight;
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
  // the step is live. The live narration goes into the box by complete
  // sentences; a closed gen's text (the close itself, a late chunk via genFor)
  // is written in full. The trailing whitespace is trimmed by the model at
  // close.
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
    if (!gen.text) return;
    if (gen.closed) entry.text.textContent = gen.text;
    else appendSentences(entry, entry.feed.feed(gen.text));
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

  // A step left with its thinking only would read "thinking" twice (its own
  // summary and its wrap's): the wrap goes and the body sits directly under
  // the step's summary, as turnHistoryHtml draws it.
  function unwrapThinking(entry) {
    if (!entry.thinkingWrap) return;
    if (entry.tickerTimer) { clearTimeout(entry.tickerTimer); entry.tickerTimer = null; }
    entry.ticker.close();
    entry.thinkingWrap.replaceWith(entry.thinking);
    entry.thinkingWrap = null;
    entry.thinkingLine = null;
  }

  // A closed gen: its final text, collapsed to its label (unless the user
  // opened it by hand), no longer live.
  function closeGenEl(gen) {
    const entry = genEls.get(gen);
    if (!entry) return;
    dirty.delete(gen);
    writeGen(gen);
    // The box gone: the step's full text (rtrimmed by the model at close),
    // today's closed-step DOM and the reloaded one.
    entry.text.textContent = gen.text;
    entry.box = null;
    entry.text.classList.remove("streaming");
    entry.el.classList.remove("live");
    if (entry.thinkingWrap) {
      // Stop the ticker, revert its summary to the plain "thinking" (reload
      // parity: no span, no fade class) and close the wrap unless the user
      // opened it by hand.
      if (entry.tickerTimer) { clearTimeout(entry.tickerTimer); entry.tickerTimer = null; }
      entry.ticker.close();
      entry.thinkingLine.textContent = "thinking";
      entry.thinkingLine.classList.remove("thinking-fade");
      if (!entry.thinkingToggled) entry.thinkingWrap.open = false;
      // A thinking-only middle step (a single-gen turn is promote's plain
      // answer, which reuses the wrap).
      if (!gen.text && !gen.tools.length && turn.gens.length > 1) unwrapThinking(entry);
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

  // A card shown during the turn (a plugin's, app.js draws it) as a row of
  // the current step, like a notice; false with no running turn (app.js
  // puts it between turns then).
  function card(el) {
    const gen = turn && !turn.ended ? model.currentGen(turn) : null;
    const entry = gen && genEls.get(gen);
    if (!entry) return false;
    if (!gen.text) entry.text.textContent = "";
    const follow = isNearBottom();
    activityEl(gen).appendChild(el);
    if (follow) historyEl.scrollTop = historyEl.scrollHeight;
    return true;
  }

  // The answer: the gen's narration moves out of the block as a bubble. With
  // +heldHeight+ (the live box's height, measured before the step closed) the
  // bubble is held at that height, scrolled to its tail, until answerReady()
  // (the rendered markdown landed) or 1.5 s reveals it.
  function promote(gen, { heldHeight = 0 } = {}) {
    const entry = genEls.get(gen);
    const bubble = entry.text;
    bubble.className = "bubble output";
    if (!gen.text) bubble.textContent = "";
    const hold = heldHeight > 0 && !!gen.text;
    if (hold) {
      bubble.classList.add("boxed");
      // Bubbles are border-box: the box's height plus the bubble's own
      // padding and border keeps the same three lines in view.
      const cs = getComputedStyle(bubble);
      const chrome = ["paddingTop", "paddingBottom", "borderTopWidth", "borderBottomWidth"]
        .reduce((sum, k) => sum + (parseFloat(cs[k]) || 0), 0);
      bubble.style.maxHeight = `${heldHeight + chrome}px`;
    }
    entry.text = document.createElement("div");
    entry.text.className = "gen-text";
    entry.summary.textContent = model.genLabel({ ...gen, text: "" });
    model.takeAnswer(turn, gen);
    // Cards in a step that goes (below) stay: before the answer, out of the
    // block, where a reload puts a turn's cards.
    const leaving = !gen.thinking && gen.tools.length === 0;
    const cards = leaving ? [...entry.el.querySelectorAll(".plugin-card")] : [];
    if (leaving) entry.el.remove();
    if (turn.gens.length === 1 && gen.tools.length === 0) {
      // A plain answer: no block, the bubble where it was (as the chat
      // view); its thinking, if any, as the chat view's collapsed block.
      const pieces = [];
      if (gen.thinking) {
        if (!entry.thinkingWrap) thinkingEl(gen);
        // Reuse the live step's thinking wrap, re-classed as the plain
        // answer's collapsed block (the same element, not a new one): plain
        // summary, no timer, closed.
        if (entry.tickerTimer) { clearTimeout(entry.tickerTimer); entry.tickerTimer = null; }
        entry.ticker.close();
        entry.thinkingWrap.className = "bubble thinking";
        entry.thinkingWrap.open = false;
        entry.thinkingLine.textContent = "thinking";
        pieces.push(entry.thinkingWrap);
      }
      pieces.push(...cards);
      if (gen.text) pieces.push(bubble);
      blockEl.replaceWith(...pieces);
      blockEl = null;
      blockSummaryEl = null;
    } else {
      cards.forEach((el) => appendToHistory(el));
      if (gen.text) appendToHistory(bubble);
      // The last step, left with its thinking only, reads "thinking" once.
      if (!gen.tools.length && gen.thinking) unwrapThinking(entry);
    }
    if (hold) {
      bubble.scrollTop = bubble.scrollHeight;
      held = { bubble, timer: setTimeout(reveal, 1500), follow: false };
    }
  }

  // The pop: the held bubble grows to its content under the CSS transition
  // while the content fades in; the class and the inline style go 400 ms
  // later (reload parity: a plain bubble). A timer, not transitionend: under
  // reduced motion and in a hidden tab none fires. No rAF either (a hidden
  // tab has none): the height is read synchronously.
  function reveal() {
    if (!held) return;
    clearTimeout(held.timer);
    const { bubble } = held;
    held.follow = isNearBottom();
    bubble.scrollTop = 0;
    bubble.style.maxHeight = `${bubble.scrollHeight}px`;
    bubble.classList.add("revealing");
    held.timer = setTimeout(finishHold, 400);
  }

  // The held bubble as a plain answer bubble, at once (also what reset()
  // does: a queued prompt's turn can start while the tail re-read is still
  // pending, and a bubble left clipped for good would be the worst outcome).
  function finishHold() {
    if (!held) return;
    clearTimeout(held.timer);
    const { bubble, follow } = held;
    held = null;
    bubble.classList.remove("boxed", "revealing");
    bubble.removeAttribute("style");
    if (follow) historyEl.scrollTop = historyEl.scrollHeight;
  }

  function turnEnded({ kind }) {
    if (!turn) return;
    const last = model.currentGen(turn);
    // A completed turn's answer is its last generation's text; a one-step
    // turn without tools leaves the block in any case (canceled, it is the
    // partial text bubble the chat view leaves).
    const promoting = last && (kind === "completed" || (turn.gens.length === 1 && last.tools.length === 0));
    // The box's height, measured while it is still in the DOM and the step
    // still open: the apply below swaps it for the full text and collapses
    // the step. Only a completed turn's answer pops; a canceled or failed
    // one shows at once.
    const box = promoting && kind === "completed" ? genEls.get(last)?.box : null;
    const heldHeight = box ? box.getBoundingClientRect().height : 0;
    apply(model.turnEnded(turn));
    if (promoting) promote(last, { heldHeight });
    if (blockEl) {
      updateBlockSummary();
      blockEl.classList.add("done");
      if (!blockToggled) blockEl.open = false;
    }
    dirty.clear();
    rafPending = false;
  }

  function reset() {
    finishHold();
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
      if (!r) return;
      // The text lands on the next animation frame; a generation can end
      // before one runs (a burst of frames, a hidden tab).
      writeGen(r.gen);
      // The remainder is the step's last line: narration without a final
      // period ("Let me check the shell first") would otherwise never show.
      const entry = genEls.get(r.gen);
      if (entry && r.gen.text && !r.gen.closed) appendSentences(entry, entry.feed.flush(r.gen.text));
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
    card,
    flush,
    // The rendered answer landed (or the re-read failed): let the held
    // bubble pop. A no-op with nothing held.
    answerReady() { reveal(); },
    // The live gen's narration box shows complete sentences, its thinking is
    // appended by delta (the ticker); a selection in either is refused while
    // the step is live — the quote lands once it closes (then on the full
    // text).
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
        // A thinking-only step: the body directly under the step's own
        // "thinking" summary (no wrap that would repeat it), as live.
        const body = gen.thinking ? `<div class="thinking-body">${escapeHtml(gen.thinking)}</div>` : "";
        const thinking = body && (gen.text || gen.tools.length) ? `<details class="thinking"><summary>thinking</summary>${body}</details>` : body;
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
