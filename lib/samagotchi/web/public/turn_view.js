// The turn view of a running turn (web.view: turn, and the stage's block):
// one <details class="turn-work"> per turn holding one <details
// class="gen"> per generation, the current one live (open, at the bottom),
// the earlier ones collapsed to one line each. At the turn's end the last
// generation's narration moves out of the block as the answer bubble, so
// markdown, annotate and the turn output dedupe work on a plain bubble.
// The grouping rules live in turn_model.js.
//
// A step is ONE lit-html template (stepTemplate) for the live page and a
// reload: the live view keeps each step's state (its rows, the ticker's
// line, the narration's sentences) and renders the template again when an
// event changed it; lit writes only what changed, so a hand toggle, a
// selection in the thinking and a row's kept parts stay.
//
// lit leaves comment nodes in the DOM (its part markers: <!--?lit$…$-->
// and <!---->), in a live step and in a reloaded history alike. Code that
// walks childNodes (or reads firstChild/lastChild) must skip comments;
// element queries, :empty and textContent are unaffected.
//
// A block that holds one gen with no thinking and no tool rows hides its
// chrome (CSS :has), so a plain answer streams like today's bubble, and is
// removed at the end: the answer bubble takes its place.
import { html, nothing, render } from "./vendor/lit-html.js";
import { leavesBlock } from "./card.js";
import { copySourceAttr } from "./copy.js";
import { escapeHtml, failedTurnText, messageBodyHtml, noteHtml, normalize, sourceLabel, steerRowHtml } from "./format.js";
import { thumbsHtml } from "./images.js";
import { shouldFollowScroll } from "./scroll.js";
import { hookNoticeLabel } from "./turn_events.js";
import { commandBubbleHtml, emptyAnswerHtml, htmlElement, shellCommandMessage, toolRowHtml, toolRowInnerHtml, userBubbleHtml } from "./turn_html.js";
import { cancelLineHtml, formatDuration, turnGroups, turnTimingText } from "./timing.js";
import { createSentenceFeed } from "./sentences.js";
import { createTicker } from "./thinking_ticker.js";
import * as model from "./turn_model.js";
import { createHold } from "./hold.js";
import { taskCommand, taskStopButton } from "./task_stop.js";

// ---- The templates: one step, its thinking, its label ----

// A closed step's summary (model.genLabel). When its head is the words the
// body starts with (the narration's first line, the first call's title)
// and it has calls, the summary is marked .repeats and its parts are
// spans: an open step shows only its calls (index.html), so it doesn't say
// the same words twice. Its text stays genLabel's either way.
function closedLabel(gen) {
  const { head, calls, repeats } = model.genLabelParts(gen);
  if (!repeats || !calls) return { repeats: false, content: model.genLabel(gen) };
  return { repeats: true, content: html`<span class="gen-head">${head}</span><span class="gen-sep"> · </span><span class="gen-calls">${calls}</span>` };
}

// A step's thinking: a collapsed <details> whose summary is "thinking" (a
// live step's ticker: "thinking · <newest sentence>") over its body; a
// thinking-only step's body sits bare under the step's own summary (no wrap
// that would repeat "thinking"). +body+ is the text: a string, or the live
// step's Text node (appended by delta: a selection in it survives).
// +cls+ "bubble thinking" is a plain answer's collapsed thinking block.
export function thinkingTemplate({ body, wrapped = true, line = null, cls = "thinking", on = {} }) {
  const inner = html`<div class="thinking-body">${body}</div>`;
  if (!wrapped) return inner;
  const summary = line === null ? "thinking" : html`<span class="thinking-tag">thinking · </span>${line}`;
  return html`<details class=${cls} @toggle=${on.thinkingToggle ?? nothing}><summary @click=${on.thinkingClick ?? nothing}>${summary}</summary>${inner}</details>`;
}

// A step's narration: the live box of complete sentences (one per line,
// the newest last), the live "…" until the first one, or a closed step's
// full text. None when there is nothing to say.
function textTemplate(text, { live, sentences, placeholder }) {
  if (live && sentences?.length) {
    return html`<div class="gen-text streaming"><div class="narration">${sentences.map((s) => html`<div class="sentence">${s}</div>`)}</div></div>`;
  }
  if (live) return placeholder ? html`<div class="gen-text streaming">…</div>` : nothing;
  return text ? html`<div class="gen-text">${text}</div>` : nothing;
}

// One step, live or reloaded. +gen+: { text, thinking, tools, answer } (a
// taken answer's text is out of the step). The live view's state: +live+
// (open, "step N" by its +index+, no failed mark yet), +open+ (lit sets it
// only when it changes: a hand toggle stays), the +steers+ rows it
// answers, its +items+ (tool rows, notices, cards: nodes or templates; a
// reload's are its rows' nodes), the thinking +body+ node, the ticker's
// +line+, the narration's +sentences+ and "…" +placeholder+, +on+ (the
// click and toggle handlers).
export function stepTemplate(gen, st = {}) {
  const { live = false, index = 0, open = live, steers = [], items = [], body = gen.thinking, line = null,
    sentences = null, placeholder = false, on = {} } = st;
  const text = gen.answer ? "" : gen.text || "";
  const label = live ? { repeats: false, content: `step ${index + 1}` } : closedLabel({ ...gen, text });
  const failed = !live && model.failedCount(gen.tools) > 0;
  // A step left with its thinking only reads "thinking" once.
  const wrapped = live || !!text || gen.tools.length > 0;
  return html`<details class=${`gen${live ? " live" : ""}${failed ? " has-failed" : ""}`} .open=${open}><summary class=${label.repeats ? "repeats" : nothing} @click=${on.stepClick ?? nothing}>${label.content}</summary>${steers}${gen.thinking ? thinkingTemplate({ body, wrapped, line, on }) : nothing}${textTemplate(text, { live, sentences, placeholder })}${items.length ? html`<div class="activity-body">${items}</div>` : nothing}</details>`;
}

// A hook's line (hook_notice) as a step's row. data.line is a whole row of
// chi's own (an empty-answer retry), shown as is; data.cls a class of its
// own and data.title its hover (a ✂ row's).
function noticeTemplate(data) {
  const cls = "hook-notice" + (data.level === "warn" ? " warn" : "") + (data.cls ? ` ${data.cls}` : "");
  return html`<div class=${cls} title=${data.title || nothing}>${data.line || `${hookNoticeLabel(data.hook)}: ${data.text || ""}`}</div>`;
}

// +template+ rendered as detached nodes (a fragment).
function nodesOf(template) {
  const frag = document.createDocumentFragment();
  render(template, frag);
  return frag;
}

// +markup+ (any HTML string) as nodes.
function rawNodes(markup) {
  const t = document.createElement("template");
  t.innerHTML = markup;
  return t.content;
}

// ---- The live view ----

// The parts of a drawn tool row a user may have changed (the command's
// raw toggle, an opened diff) or that never change once there (the
// thumbs): a redraw keeps them as they are.
const KEPT_PARTS = ["activity-command", "activity-diff", "thumbs"];

const childWith = (el, cls) => [...el.children].find((c) => c.classList.contains(cls));

// A live tool row drawn again from its activity row (status, title,
// output): the reloaded row's markup (toolRowInnerHtml), the kept parts
// and the stop-task button carried over. +html+ is that markup.
function redrawRow(el, markup) {
  const fresh = htmlElement(`<div>${markup}</div>`);
  for (const cls of KEPT_PARTS) {
    const old = childWith(el, cls);
    const drawn = childWith(fresh, cls);
    if (old && drawn) drawn.replaceWith(old);
  }
  const stop = childWith(el, "task-stop");
  el.replaceChildren(...fresh.childNodes);
  if (stop) rowAnchor(el).after(stop);
}

// Where a row's stop-task button goes: after its title (else its tool).
function rowAnchor(el) {
  return childWith(el, "activity-params") || childWith(el, "activity-tool");
}

// The container seams (the stage view composes this view, stage_view.js):
//   blockHost(el)  puts the turn's block in the page (default: the history);
//   follow()       keeps the live part in view (default: the history's
//                  tail), called only when isNearBottom() said so before
//                  the change;
//   placeAnswer(pieces, { plain, blockEl }) puts the promoted answer (a
//                  plain answer's thinking, cards, bubble) in the page
//                  (default: in the block's place for a plain answer,
//                  else after it in the history);
//   useHold        the answer's pop at the narration box's height (hold.js);
//   newestFirst    a new step goes on top of the block while the turn runs
//                  (chronological() restores the order);
//   onChange()     after anything in the turn changed (the stage redraws
//                  its slots from current());
//   onThinkingLine(sentence) the live step's ticker showed a new line;
//   taskStop       the page's stopper (task_stop.js): a running task_wait
//                  row gets its stop-task button (none: no button).
export function createTurnView({
  historyEl, appendToHistory, isNearBottom, sawText, sessionId,
  blockHost = appendToHistory,
  follow = () => { historyEl.scrollTop = historyEl.scrollHeight; },
  placeAnswer = defaultPlaceAnswer(appendToHistory),
  useHold = true,
  newestFirst = false,
  onChange = () => {},
  onThinkingLine = () => {},
  taskStop = null,
}) {
  let turn = null;
  let blockEl = null;
  let blockSummaryEl = null;
  let blockToggled = false;
  // gen → a step's live state (newStep), its rendered nodes between
  // part.startNode and end.
  const genEls = new Map();
  // Steer rows waiting for the step that answers them (steer()).
  let pendingSteers = [];
  const dirty = new Set();
  let rafPending = false;
  // The promoted answer bubble while it is held at the box's height (the
  // pop, D6).
  const hold = createHold({ isNearBottom, follow });

  function removeHint() {
    const hint = historyEl.querySelector(".hint");
    if (hint) hint.remove();
  }

  function createBlock() {
    removeHint();
    blockEl = document.createElement("details");
    blockEl.className = "turn-work";
    blockEl.open = true;
    blockToggled = false;
    blockSummaryEl = document.createElement("summary");
    blockEl.appendChild(blockSummaryEl);
    blockSummaryEl.addEventListener("click", () => { blockToggled = true; });
    updateBlockSummary();
    blockHost(blockEl);
  }

  function updateBlockSummary() {
    if (blockSummaryEl && turn) blockSummaryEl.textContent = model.blockSummary(turn, { running: !turn.ended });
  }

  // The step rendered again from its state (stepTemplate). Each live step
  // is its own lit root, not an item of one block template: newestFirst
  // puts a new step on top and chronological() reorders them, and lit
  // (without the keyed repeat directive, not vendored) matches list items
  // by index, so a block-wide render would hand step N's <details> (and
  // its hand toggle) to another gen. The root's part lives on entry.end
  // (render's renderBefore), so the step's nodes can move anywhere in the
  // page between lit's start marker and that end comment (stepNodes).
  function draw(entry) {
    entry.part = render(stepTemplate(entry.gen, {
      live: !entry.closed, index: entry.index, open: entry.open, steers: entry.steers, items: entry.items,
      body: entry.thinkingText, line: entry.line, sentences: entry.sentences, placeholder: entry.placeholder, on: entry.on,
    }), entry.frag, { renderBefore: entry.end });
  }

  // A step's nodes (lit's start marker, the <details>, the end marker), to
  // move or remove them together.
  function stepNodes(entry) {
    const nodes = [];
    for (let n = entry.part.startNode; n; n = n.nextSibling) {
      nodes.push(n);
      if (n === entry.end) break;
    }
    return nodes;
  }

  const thinkingWrap = (entry) => entry.el.querySelector(":scope > details.thinking");
  const narrationEl = (entry) => entry.el.querySelector(":scope > .gen-text > .narration");

  function createGenEl(gen) {
    const entry = {
      gen, index: turn.gens.length - 1, frag: document.createDocumentFragment(), end: document.createComment(""),
      part: null, el: null, open: true, toggled: false, closed: false,
      // A plugin's steers merged since the last step: this step answers them.
      steers: pendingSteers, items: [], rows: new Map(),
      // A step after the first shows "…" until its text comes (the first one
      // only for a prompt).
      placeholder: turn.gens.length > 1, sentences: null, feed: createSentenceFeed(),
      thinkingText: null, line: null, ticker: null, tickerTimer: null, thinkingToggled: false, on: null,
    };
    pendingSteers = [];
    // A real click on a summary is a hand toggle: the code's auto-collapse
    // then leaves it as the user left it. A peek at the thinking is per step
    // (the page is for glancing): later steps start closed. The toggle event
    // (queued after <details>.open flips) only scrolls the body to its tail
    // on open.
    entry.on = {
      stepClick: () => { entry.toggled = true; },
      thinkingClick: () => { entry.thinkingToggled = true; },
      thinkingToggle: (e) => {
        const wrap = e.currentTarget;
        const body = wrap.querySelector(".thinking-body");
        if (wrap.open && body) body.scrollTop = body.scrollHeight;
      },
    };
    entry.frag.append(entry.end);
    genEls.set(gen, entry);
    draw(entry);
    entry.el = entry.end.previousElementSibling || entry.frag.querySelector("details.gen");
    const stick = isNearBottom();
    if (newestFirst) blockEl.insertBefore(entry.frag, blockSummaryEl.nextSibling);
    else blockEl.appendChild(entry.frag);
    if (stick) follow();
    return entry;
  }

  function stopTicker(entry) {
    if (entry.tickerTimer) { clearTimeout(entry.tickerTimer); entry.tickerTimer = null; }
    entry.ticker?.close();
  }

  // The ticker's newest sentence into the thinking's summary, with a subtle
  // fade on change; the class is removed at close (reload parity: the
  // re-rendered summary is plain "thinking").
  function setThinkingLine(entry, sentence) {
    entry.line = sentence;
    draw(entry);
    const summary = thinkingWrap(entry)?.querySelector(":scope > summary");
    if (summary) {
      summary.classList.remove("thinking-fade");
      void summary.offsetWidth;
      summary.classList.add("thinking-fade");
    }
    onThinkingLine(sentence);
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

  // Complete sentences into the narration box, which follows its own tail
  // unless the user scrolled up inside it to read (decided before the
  // append: a burst lands several lines at once).
  function addSentences(entry, sentences) {
    if (!sentences.length) return;
    const box = narrationEl(entry);
    const stick = !box || shouldFollowScroll(box, 24);
    entry.sentences = [...(entry.sentences || []), ...sentences];
    draw(entry);
    const drawn = narrationEl(entry);
    if (stick && drawn) drawn.scrollTop = drawn.scrollHeight;
  }

  // The gen's text and thinking into its step. The thinking is appended by
  // delta to one Text node (a selection survives; a full rewrite would drop
  // it) and rewritten only when it shrank (the close's rtrim); the ticker
  // advances from it while the step is live. The live narration goes into
  // the box by complete sentences; a closed gen shows its full text (the
  // close itself, a late chunk via genFor).
  function writeGen(gen, { follow = false } = {}) {
    const entry = genEls.get(gen);
    if (!entry) return;
    if (gen.thinking) {
      const before = entry.thinkingText?.parentNode;
      const stick = follow && before && shouldFollowScroll(before, 24);
      if (!entry.thinkingText) {
        entry.thinkingText = document.createTextNode("");
        entry.ticker = createTicker({ now: () => Date.now(), dwellMs: 1500 });
      }
      const node = entry.thinkingText;
      if (gen.thinking.length > node.length) node.appendData(gen.thinking.slice(node.length));
      else if (gen.thinking.length < node.length) node.data = gen.thinking;
      draw(entry);
      if (stick) before.scrollTop = before.scrollHeight;
      // Late chunks reach closed gens (genFor); their ticker stays still.
      if (!gen.closed) feedTicker(gen);
    }
    if (!gen.text) return;
    if (gen.closed) draw(entry);
    else addSentences(entry, entry.feed.feed(gen.text));
  }

  function flush() {
    rafPending = false;
    // Runs every animation frame while streaming — must not yank a user who
    // scrolled up to read; only follow when they were already near the bottom.
    const stick = isNearBottom();
    for (const gen of dirty) writeGen(gen, { follow: true });
    dirty.clear();
    if (stick) follow();
    onChange();
  }

  function scheduleFlush(gen) {
    dirty.add(gen);
    if (rafPending) return;
    rafPending = true;
    requestAnimationFrame(flush);
  }

  // A closed gen: its final text, collapsed to its label (unless the user
  // opened it by hand), no longer live; its thinking's summary back to the
  // plain "thinking", collapsed unless the user opened it.
  function closeGenEl(gen) {
    const entry = genEls.get(gen);
    if (!entry) return;
    dirty.delete(gen);
    writeGen(gen);
    stopTicker(entry);
    entry.line = null;
    entry.closed = true;
    entry.sentences = null;
    if (!entry.toggled) entry.open = false;
    const wrap = thinkingWrap(entry);
    if (wrap && !entry.thinkingToggled) wrap.open = false;
    draw(entry);
    // The fade gone without a class="" left behind (the reloaded summary has none).
    const summary = thinkingWrap(entry)?.querySelector(":scope > summary");
    if (summary?.classList.contains("thinking-fade")) {
      summary.classList.remove("thinking-fade");
      if (!summary.classList.length) summary.removeAttribute("class");
    }
    // Every generation's text goes into the shown texts (the turn output dedupe).
    const k = normalize(gen.text);
    if (k) sawText(k);
  }

  // A step that closes mid-turn (the next one starts) collapses: a warn card
  // in it would go out of sight until the turn ends. It moves out of the
  // step, right after it in the block (open while the turn runs), where
  // turnEnded still finds it and takes it out of the block (leavesBlock).
  // The card stays in entry.items while it sits outside the step: safe only
  // because the step's items are never removed or reordered after this (a
  // late row is appended, a no-op for the parts before it). A render whose
  // items shifted would make lit insert the card back into the step (or
  // another item into its slot).
  function liftWarnCards(gen) {
    const entry = genEls.get(gen);
    if (!entry) return;
    const cards = [...entry.el.querySelectorAll(".plugin-card.warn")];
    if (cards.length) entry.end.after(...cards);
  }

  function apply(r) {
    if (!r) return;
    if (r.closed && r.opened) liftWarnCards(r.closed);
    if (r.closed) closeGenEl(r.closed);
    if (r.opened) createGenEl(r.gen);
    if (r.closed || r.opened) updateBlockSummary();
    onChange();
  }

  // A tool row is the reloaded row's markup (turn_html.js toolRowHtml),
  // drawn again when an event changed it.
  const rowHtml = new WeakMap();
  const rowThumbs = (images) => thumbsHtml(sessionId(), images);

  // A row, notice or card into the step's activity; a step that wrote no
  // narration before it drops the "…".
  function addItem(entry, item) {
    if (!entry.gen.text) entry.placeholder = false;
    const stick = isNearBottom();
    entry.items.push(item);
    draw(entry);
    if (stick) follow();
  }

  function toolEvent(r) {
    apply(r);
    const entry = genEls.get(r.gen);
    let el = entry.rows.get(r.row.key);
    const inner = toolRowInnerHtml(r.row, { thumbs: rowThumbs });
    if (!el) {
      el = htmlElement(toolRowHtml(r.row, { thumbs: rowThumbs }));
      rowHtml.set(el, inner);
      entry.rows.set(r.row.key, el);
      addItem(entry, el);
    } else {
      if (!r.gen.text) entry.placeholder = false;
      if (rowHtml.get(el) !== inner) redrawRow(el, inner);
      rowHtml.set(el, inner);
      // A late result in a closed step: its label and failed mark.
      draw(entry);
    }
    syncTaskStop(el, r.row);
    updateBlockSummary();
    onChange();
  }

  // The stop-task button after a running task_wait's params; gone once the
  // row completes.
  function syncTaskStop(el, row) {
    const taskId = taskStop?.target(row);
    const btn = el.querySelector(":scope > .task-stop");
    if (!taskId) {
      btn?.remove();
      return;
    }
    if (btn) {
      btn.disabled = taskStop.busy(taskId);
      return;
    }
    const command = () => taskCommand(turn?.gens, taskId);
    rowAnchor(el).after(taskStopButton(taskStop, taskId, { command }));
  }

  // A hook's line (hook_notice) as a row of the current step, above the row
  // of the call it judged; false with no running turn (app.js shows the
  // bubble then).
  function notice(data) {
    const r = turn && model.notice(turn, data);
    if (!r) return false;
    addItem(genEls.get(r.gen), noticeTemplate(data));
    return true;
  }

  // A plugin's steer (pending_input_merged's steers) as the first row of
  // the step that answers it: it joined the turn after the current step's
  // tools, and the next generation (a new, open step) reads it; the
  // current step collapses when that one starts. Held until then (a turn
  // that ends first puts it in its last step). False with no running turn.
  function steer(data) {
    if (!turn || turn.ended) return false;
    pendingSteers.push(htmlElement(steerRowHtml(data)));
    return true;
  }

  // Held steer rows into the last step (the turn ends without another).
  function flushSteers() {
    const gen = turn.gens[turn.gens.length - 1];
    const entry = gen && genEls.get(gen);
    if (entry) {
      entry.steers = [...entry.steers, ...pendingSteers];
      draw(entry);
    }
    pendingSteers = [];
  }

  // A card shown during the turn (a plugin's, app.js draws it) as a row of
  // the current step, like a notice; false with no running turn (app.js
  // puts it between turns then).
  function card(el) {
    const gen = turn && !turn.ended ? model.currentGen(turn) : null;
    const entry = gen && genEls.get(gen);
    if (!entry) return false;
    addItem(entry, el);
    return true;
  }

  // The answer: the gen's narration leaves the block as a bubble. With
  // +heldHeight+ (the live box's height, measured before the step closed) the
  // bubble is held at that height, scrolled to its tail, until answerReady()
  // (the rendered markdown landed) or 1.5 s reveals it.
  // +endNote+: the notice of a turn that ended with no answer (app.js
  // builds it), placed where the answer bubble would go.
  function promote(gen, { heldHeight = 0, endNote = null } = {}) {
    const entry = genEls.get(gen);
    // No text (an empty answer): no bubble.
    let bubble = null;
    if (gen.text) {
      bubble = document.createElement("div");
      bubble.className = "bubble output";
      bubble.textContent = gen.text;
    }
    // A hidden tab gets no pop: nobody sees it, and its timers are throttled.
    const holding = useHold && heldHeight > 0 && !!bubble && !document.hidden;
    model.takeAnswer(turn, gen);
    draw(entry);
    // Cards and hook notices in a step that goes (below, or with the whole
    // block for a plain answer) stay: before the answer, out of the block,
    // where a reload puts a turn's cards; a notice as the bubble it is
    // between turns. These are lit-rendered nodes taken out of the step:
    // safe only because the step is never rendered again with other items
    // or steers (it is removed, its block goes, or it only closes); such a
    // render would move them back in, and a changed class binding on a
    // notice would drop the "bubble" class added here.
    const leaving = !gen.thinking && gen.tools.length === 0;
    const plain = turn.gens.length === 1 && gen.tools.length === 0;
    const cards = leaving || plain ? [...entry.el.querySelectorAll(".plugin-card, .hook-notice, .steer-row")] : [];
    cards.forEach((el) => { if (!el.classList.contains("plugin-card")) el.classList.add("bubble"); });
    if (leaving) stepNodes(entry).forEach((n) => n.remove());
    if (plain) {
      // A plain answer: no block, the bubble where it was; its thinking, if
      // any, as a collapsed thinking block above it.
      const pieces = [];
      if (gen.thinking) pieces.push(nodesOf(thinkingTemplate({ body: gen.thinking, cls: "bubble thinking" })).firstElementChild);
      pieces.push(...cards);
      if (bubble) pieces.push(bubble);
      else if (endNote) pieces.push(endNote);
      placeAnswer(pieces, { plain: true, blockEl });
      blockEl = null;
      blockSummaryEl = null;
    } else {
      placeAnswer(bubble ? [...cards, bubble] : [...cards, ...(endNote ? [endNote] : [])], { plain: false, blockEl });
    }
    if (holding) {
      // Bubbles are border-box: the box's height plus the bubble's own
      // padding and border keeps the same three lines in view.
      const cs = getComputedStyle(bubble);
      const chrome = ["paddingTop", "paddingBottom", "borderTopWidth", "borderBottomWidth"]
        .reduce((sum, k) => sum + (parseFloat(cs[k]) || 0), 0);
      hold.start(bubble, heldHeight + chrome);
    }
  }

  // Returns the cards that left the block (card.js leavesBlock), detached:
  // app.js puts them after the turn's end line. +endNote+ (a completed turn
  // with no answer): its notice, in the answer's place; left unplaced
  // with no turn to end (app.js then shows it itself).
  function turnEnded({ kind, endNote = null }) {
    // Once per turn: a second end (a re-dispatched event) would promote again.
    if (!turn || turn.ended) return [];
    const last = model.currentGen(turn);
    // A completed turn's answer is its last generation's text; a one-step
    // turn without tools leaves the block in any case (canceled, it is the
    // partial text bubble).
    const promoting = last && (kind === "completed" || (turn.gens.length === 1 && last.tools.length === 0));
    // The box's height, measured while it is still in the DOM and the step
    // still open: the apply below swaps it for the full text and collapses
    // the step. Only a completed turn's answer pops; a canceled or failed
    // one shows at once.
    const lastEntry = promoting && kind === "completed" ? genEls.get(last) : null;
    const box = lastEntry ? narrationEl(lastEntry) : null;
    const heldHeight = box ? box.getBoundingClientRect().height : 0;
    if (pendingSteers.length) flushSteers();
    apply(model.turnEnded(turn));
    if (promoting) promote(last, { heldHeight, endNote });
    else if (endNote) placeAnswer([endNote], { plain: false, blockEl });
    const kept = [];
    if (blockEl) {
      updateBlockSummary();
      blockEl.classList.add("done");
      if (!blockToggled) blockEl.open = false;
      for (const el of blockEl.querySelectorAll(".plugin-card")) {
        if (leavesBlock({ warn: el.classList.contains("warn"), kind })) kept.push(el);
      }
      kept.forEach((el) => el.remove());
    }
    dirty.clear();
    rafPending = false;
    onChange();
    return kept;
  }

  function reset() {
    hold.finish();
    turn = null;
    blockEl = null;
    blockSummaryEl = null;
    blockToggled = false;
    // Clear every ticker timer before the map goes (a live step mid-dwell).
    for (const entry of genEls.values()) stopTicker(entry);
    genEls.clear();
    pendingSteers = [];
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
      if (data.prompt) {
        const entry = genEls.get(r.gen);
        entry.placeholder = true;
        draw(entry);
      }
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
    // A dropped stream's step asked again (generation_retrying with
    // restarted): its gen's thinking and narration so far go, the step
    // shows "…" until the new stream's text comes.
    generationRestarted(data) {
      if (!turn) return;
      const r = model.generationRestarted(turn, data?.iteration ?? null);
      const entry = r && genEls.get(r.gen);
      if (!entry) return;
      dirty.delete(r.gen);
      stopTicker(entry);
      Object.assign(entry, { thinkingText: null, line: null, ticker: null, sentences: null, placeholder: true,
        feed: createSentenceFeed() });
      draw(entry);
      onChange();
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
      if (entry && r.gen.text && !r.gen.closed) addSentences(entry, entry.feed.flush(r.gen.text));
    },
    toolStarted(data) {
      if (!turn) this.turnStarted({});
      toolEvent(model.toolStarted(turn, data, Date.now()));
    },
    toolCompleted(data) {
      if (!turn) this.turnStarted({});
      toolEvent(model.toolCompleted(turn, data, Date.now()));
    },
    turnEnded,
    notice,
    steer,
    card,
    flush,
    // The rendered answer landed (or the re-read failed): let the held
    // bubble pop. A no-op with nothing held.
    answerReady() { hold.reveal(); },
    // The live gen's narration box shows complete sentences, its thinking is
    // appended by delta (the ticker); a selection in either is refused while
    // the step is live — the quote lands once it closes (then on the full
    // text).
    containsLive(el) {
      const gen = turn && model.currentGen(turn);
      const entry = gen && genEls.get(gen);
      if (!entry) return false;
      const text = entry.el.querySelector(":scope > .gen-text");
      return !!text?.contains(el) || !!entry.thinkingText?.parentNode?.contains(el);
    },
    reset,
    // For a view that composes this one (the stage): the turn's model and
    // block, a step's elements by index, and the steps back in
    // chronological order after newestFirst.
    current() { return { turn, blockEl }; },
    step(i) {
      const entry = turn && genEls.get(turn.gens[i]);
      return entry ? { el: entry.el, summary: entry.el.querySelector(":scope > summary"), thinkingWrap: thinkingWrap(entry) } : null;
    },
    chronological() {
      if (!blockEl || !turn) return;
      for (const gen of turn.gens) {
        const entry = genEls.get(gen);
        if (entry?.el.parentNode === blockEl) blockEl.append(...stepNodes(entry));
      }
    },
  };
}

// The turn view's answer placement: a plain answer's pieces in its block's
// place (the block goes), else after the block in the history.
function defaultPlaceAnswer(appendToHistory) {
  return (pieces, { plain, blockEl }) => {
    if (plain) blockEl.replaceWith(...pieces);
    else pieces.forEach((el) => appendToHistory(el));
  };
}

// ---- A reload ----

// A re-rendered failed turn's line (a .bubble.cancel, as live's
// addEndBubble), in turn_failed's words (failedTurnText) from what the turn
// record kept of it (SessionMetrics' failure: summary, message,
// error_class, kept_steps); "" for any other record, or a failed one saved
// before records kept that.
function failedLineHtml(record) {
  const failure = record?.status === "failed" ? record.failure : null;
  if (!failure || typeof failure !== "object") return "";
  return `<div class="bubble cancel">${escapeHtml(failedTurnText(failure))}</div>`;
}

// Parts (HTML strings and templates, in order) as one fragment.
function fragmentOf(parts) {
  const out = document.createDocumentFragment();
  let markup = "";
  for (const part of parts) {
    if (typeof part === "string") { markup += part; continue; }
    if (markup) out.append(rawNodes(markup));
    markup = "";
    out.append(nodesOf(part));
  }
  if (markup) out.append(rawNodes(markup));
  return out;
}

// A reloaded history in the turn view (renderHistory's object path), as
// nodes: per turn the prompt, a collapsed block of its steps when it had
// any (stepTemplate, the live page's: texts, and with the server's parts
// the thinking, params and output, from the saved messages; status and
// duration from the timing's tool records), then the answer and the turn's
// timing line under it.
// +thumbs(images)+ draws a prompt's or a tool row's image thumbs.
export function turnHistoryNodes(items, timing, { thumbs }) {
  const timingHtml = (group) => {
    const record = group.record;
    // Numbered by its place in the turn records, as live (a failed turn
    // whose prompt went back still counts).
    const at = (timing?.turnRecords || []).indexOf(record);
    return record && formatDuration(record.duration_ms)
      ? `<div class="turn-timing">${escapeHtml(turnTimingText(at >= 0 ? at + 1 : group.turnIndex + 1, record.duration_ms, { canceled: record.status === "canceled" }))}</div>`
      : "";
  };
  // The timing line after the bubble, not in it: where the live view
  // leaves it at the turn's end.
  const answerHtml = (m, timing) => {
    const { body, renderedMarkdown } = messageBodyHtml(m);
    return `<div class="bubble output${renderedMarkdown ? " markdown" : ""}"${copySourceAttr(m, renderedMarkdown)}>${body}</div>${timing}`;
  };
  // A user's line, labelled when chi brought it in (a delegate report). A
  // `!cmd`'s saved message (the worker's "!(<command>)\n<output>") renders
  // as its command bubble, as live does — not as a user bubble.
  const userHtml = (m, opts = {}) => {
    const shell = shellCommandMessage(m?.content);
    if (shell) return commandBubbleHtml(shell);
    return userBubbleHtml(m, { label: sourceLabel(m?.source), thumbs: thumbs(m.images), ...opts });
  };
  // The first text after a delegate report merged mid-turn, unless it is
  // the turn's answer (shown anyway).
  const reportReplyHtml = (i, group) => {
    if (items[i]?.source !== "delegate_report") return "";
    const j = items.findIndex((m, k) => k > i && m?.role === "assistant" && String(m.content ?? "").trim());
    if (j < 0 || j === group.answer || items.slice(i + 1, j).some((m) => m?.role === "user" && !m.merged)) return "";
    const { body, renderedMarkdown } = messageBodyHtml(items[j]);
    return `<div class="bubble output report-reply${renderedMarkdown ? " markdown" : ""}"${copySourceAttr(items[j], renderedMarkdown)}>${body}</div>`;
  };
  const steerHtml = (i, bubble) => steerRowHtml({ source: items[i].source, text: items[i].content }, { bubble });
  const parts = [];
  for (const group of turnGroups(items, timing)) {
    if (group.kind === "note") { parts.push(`<div class="bubble note">${noteHtml(items[group.i])}</div>`); continue; }
    if (group.kind === "steer") { parts.push(steerHtml(group.i, true)); continue; }
    if (group.kind === "answer") { parts.push(answerHtml(items[group.answer], "")); continue; }
    const prompt = items[group.user];
    // A context wake turn starts with its note.
    parts.push(prompt.role === "note" ? `<div class="bubble note">${noteHtml(prompt)}</div>` : userHtml(prompt));
    const [only] = group.steps;
    const ended = group.answer !== null || group.emptyAnswer != null;
    const textless = only && (only.i === null || !String(items[only.i].content ?? ""));
    // A lone thinking step before an answer (or the notice of a turn with
    // none): no block, the plain answer's collapsed thinking block.
    const plainThinking = group.steps.length === 1 && ended && textless && !only.tools.length && only.thinking;
    const noBlock = !group.steps.length || plainThinking;
    if (plainThinking) {
      parts.push(thinkingTemplate({ body: only.thinking, cls: "bubble thinking" }));
    } else if (group.steps.length) {
      const gens = group.steps.map((step) => ({ text: step.i === null ? "" : String(items[step.i].content ?? ""), thinking: step.thinking || "", tools: step.tools }));
      const steps = gens.map((gen, k) => stepTemplate(gen, {
        // The steers the step answered first, where the live rows went.
        steers: (group.steps[k].steers || []).map((i) => rawNodes(steerHtml(i, false))),
        items: gen.tools.length ? [rawNodes(gen.tools.map((r) => toolRowHtml(r, { thumbs })).join(""))] : [],
      }));
      parts.push(html`<details class="turn-work done"><summary>${model.blockSummary({ gens, ended: true })}</summary>${steps}</details>`);
    }
    // Steers with no step to sit in, or in a turn that shows no block: on
    // their own after the prompt.
    const loose = noBlock ? [...group.steps.flatMap((step) => step.steers || []), ...(group.steers || [])] : group.steers || [];
    parts.push(loose.map((i) => steerHtml(i, true)).join(""));
    // The user's lines merged into the turn: the live "steered" bubbles,
    // after its steps and before its answer. A delegate report's is
    // followed by the text that answered it when that isn't the answer: a
    // small model tells its user about a report before its next tool call,
    // and that step's text would stay folded in the block.
    parts.push((group.merged || []).map((i) =>
      userHtml(items[i], { state: "steered", step: items[i].step }) +
      reportReplyHtml(i, group)).join(""));
    // A turn that ended with no answer: chi's muted notice where the answer
    // would be, before the timing, as live.
    if (group.emptyAnswer != null) parts.push(`${emptyAnswerHtml(items[group.emptyAnswer])}${timingHtml(group)}`);
    // A turn with no answer (canceled, or running: no record yet) shows its
    // timing after its prompt and steps, where the live view leaves it.
    else if (group.answer === null) parts.push(timingHtml(group));
    else parts.push(answerHtml(items[group.answer], timingHtml(group)));
    // A canceled turn ends with its cancel line, a failed one whose steps
    // stayed with its failure line, as the live view left them.
    parts.push(cancelLineHtml(group.record, escapeHtml));
    parts.push(failedLineHtml(group.record));
  }
  return fragmentOf(parts);
}
