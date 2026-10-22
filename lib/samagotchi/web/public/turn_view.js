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
import { answerRefsOf, setAnswerRefs } from "./answer_refs.js";
import { bindRowRefs } from "./refs.js";
import { leavesBlock } from "./card.js";
import { failedTurnText, normalize, sourceLabel } from "./format.js";
import { thumbsTemplate } from "./images.js";
import { shouldFollowScroll } from "./scroll.js";
import { hookNoticeLabel } from "./turn_events.js";
import {
  answerBubbleTemplate, cancelLineTemplate, commandBubbleTemplate, elementOf, emptyAnswerTemplate, noteBubbleTemplate, shellCommandMessage,
  steerRowTemplate, toolRowInnerTemplate, toolRowTemplate, userBubbleTemplate,
} from "./turn_html.js";
import { formatDuration, turnGroups, turnTimingText } from "./timing.js";
import { createSentenceFeed } from "./sentences.js";
import { createTicker } from "./thinking_ticker.js";
import * as model from "./turn_model.js";
import { createHold } from "./hold.js";
import { linkedLine } from "./notice_links.js";
import { taskCommand, taskStopButton } from "./task_stop.js";
import { footprintTemplate, groupItems, stampHistory } from "./working_set_view.js";

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
function thinkingTemplate({ body, wrapped = true, line = null, cls = "thinking", on = {} }) {
  const inner = html`<div class="thinking-body">${body}</div>`;
  if (!wrapped) return inner;
  const summary = line === null ? "thinking" : html`<span class="thinking-tag">thinking · </span>${line}`;
  return html`<details class=${cls} @toggle=${on.thinkingToggle ?? nothing}><summary @click=${on.thinkingClick ?? nothing}>${summary}</summary>${inner}</details>`;
}

// A step's narration: the live box of complete sentences (one per line,
// the newest last), the live "…" until the first one, or a closed step's
// full text. None when there is nothing to say. A closed step's text is
// set whole (.textContent): its refs (ref_scan.js) split it into spans
// that a text part's update would leave behind. +at+: a reloaded step's
// message index, for its refs (data-answer-at, as an answer's). A
// reloaded step's +rendered+ markdown (its message's html, sanitised on the
// server, as an answer's) shows in place of the text, which it keeps as
// its source (stepText); a live step's renders once it closed
// (markdown_place.js renderStepTexts).
function textTemplate(text, { live, sentences, placeholder, at = null, rendered = null }) {
  if (live && sentences?.length) {
    return html`<div class="gen-text streaming"><div class="narration">${sentences.map((s) => html`<div class="sentence">${s}</div>`)}</div></div>`;
  }
  if (live) return placeholder ? html`<div class="gen-text streaming">…</div>` : nothing;
  if (!text) return nothing;
  if (typeof rendered === "string" && rendered) {
    return html`<div class="gen-text markdown md-compact" data-answer-at=${at ?? nothing} data-copy-source=${text} .innerHTML=${rendered}></div>`;
  }
  return html`<div class="gen-text" data-answer-at=${at ?? nothing} .textContent=${text}></div>`;
}

// One step, live or reloaded. +gen+: { text, thinking, tools, answer } (a
// taken answer's text is out of the step). The live view's state: +live+
// (open, "step N" by its +index+, no failed mark yet), +open+ (lit sets it
// only when it changes: a hand toggle stays), the +steers+ rows it
// answers, its +items+ (tool rows, notices, cards: nodes or templates; a
// reload's are its rows' nodes), the thinking +body+ node, the ticker's
// +line+, the narration's +sentences+ and "…" +placeholder+, +on+ (the
// click and toggle handlers). A reload's +at+: the step's message index
// (textTemplate).
export function stepTemplate(gen, st = {}) {
  const { live = false, index = 0, open = live, steers = [], items = [], body = gen.thinking, line = null,
    sentences = null, placeholder = false, on = {}, at = null } = st;
  const text = gen.answer ? "" : gen.text || "";
  const label = live ? { repeats: false, content: `step ${index + 1}` } : closedLabel({ ...gen, text });
  const failed = !live && model.failedCount(gen.tools) > 0;
  // A step left with its thinking only reads "thinking" once.
  const wrapped = live || !!text || gen.tools.length > 0;
  return html`<details class=${`gen${live ? " live" : ""}${failed ? " has-failed" : ""}`} .open=${open}><summary class=${label.repeats ? "repeats" : nothing} @click=${on.stepClick ?? nothing}>${label.content}</summary>${steers}${gen.thinking ? thinkingTemplate({ body, wrapped, line, on }) : nothing}${textTemplate(text, { live, sentences, placeholder, at, rendered: gen.html })}${items.length ? html`<div class="activity-body">${items}</div>` : nothing}</details>`;
}

// A hook's line (hook_notice) as a step's row. data.line is a whole row of
// chi's own (an empty-answer retry), shown as is; data.cls a class of its
// own and data.title its hover (a ✂ row's). Its http(s) URLs are links.
function noticeTemplate(data) {
  const cls = "hook-notice" + (data.level === "warn" ? " warn" : "") + (data.cls ? ` ${data.cls}` : "");
  return html`<div class=${cls} title=${data.title || nothing}>${linkedLine(data.line || `${hookNoticeLabel(data.hook)}: ${data.text || ""}`)}</div>`;
}

// +template+ rendered as detached nodes (a fragment).
function nodesOf(template) {
  const frag = document.createDocumentFragment();
  render(template, frag);
  return frag;
}

// ---- A finished block's outline ----

// A finished block as its outline (turn_model.js outlineRuns of +gens+, its
// steps in order): open, each narrated step a one-line row as before, each
// run of steps that said nothing hidden behind one "N steps" fold that
// shows them. The live turn's end and a reload call it alike. The folds sit
// between the steps, not in them (`:scope > .gen` still counts steps), each
// before its run's first step and before that step's lit marker comment, so
// a later render of the step leaves it alone. False when there is nothing
// to outline (no step said anything): the block stays as it is.
export function outlineBlock(blockEl, gens) {
  const runs = model.outlineRuns(gens);
  const steps = blockEl ? [...blockEl.querySelectorAll(":scope > .gen")] : [];
  if (!runs.length || steps.length !== gens.length) return false;
  blockEl.classList.add("outline");
  // A folded step → its fold's opener: a ref's "show in turn" (refs.js
  // showInTurn dispatches ref:reveal on the row before it scrolls) unfolds
  // the run its row is in, or the row stays hidden.
  const unfold = new Map();
  for (const { fold } of runs) {
    if (!fold) continue;
    const folded = fold.map((i) => steps[i]);
    folded.forEach((el) => el.classList.add("folded"));
    const marker = document.createElement("div");
    marker.className = "outline-fold";
    marker.setAttribute("role", "button");
    marker.tabIndex = 0;
    marker.setAttribute("aria-expanded", "false");
    marker.textContent = `${fold.length} step${fold.length === 1 ? "" : "s"}`;
    const toggle = () => {
      const open = marker.classList.toggle("open");
      marker.setAttribute("aria-expanded", String(open));
      folded.forEach((el) => el.classList.toggle("unfolded", open));
    };
    folded.forEach((el) => unfold.set(el, () => { if (!marker.classList.contains("open")) toggle(); }));
    marker.addEventListener("click", toggle);
    marker.addEventListener("keydown", (e) => {
      if (e.key !== "Enter" && e.key !== " ") return;
      e.preventDefault();
      toggle();
    });
    const first = folded[0];
    const anchor = first.previousSibling?.nodeType === 8 ? first.previousSibling : first;
    anchor.before(marker);
  }
  blockEl.addEventListener("ref:reveal", (e) => {
    const step = e.target.closest?.(".gen.folded");
    if (step?.parentElement === blockEl) unfold.get(step)?.();
  });
  blockEl.open = true;
  return true;
}

// Reloaded tool rows (turn_html.js toolRowTemplate) as nodes, each row's
// plugin refs bound to its title (refs.js bindRowRefs).
function rowNodes(rows, thumbs) {
  const nodes = nodesOf(rows.map((r) => toolRowTemplate(r, { thumbs })));
  [...nodes.children].forEach((el, i) => bindRowRefs(el, rows[i]));
  return nodes;
}

// ---- The live view ----

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
    // A closed step that asked a question knows its refs (model.questionRefs):
    // the page pairs them with its text at the turn's end (linkTextRefs).
    const text = entry.closed && entry.gen.refs ? entry.el?.querySelector(":scope > .gen-text") : null;
    if (text && !answerRefsOf(text)) setAnswerRefs(text, entry.gen.refs);
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

  // A live tool row is its own element, the reloaded row's template
  // (turn_html.js toolRowInnerTemplate) rendered into it on each event.
  const rowThumbs = (images) => thumbsTemplate(sessionId(), images);
  // A row element → its stop-task button (syncTaskStop).
  const rowStops = new WeakMap();

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
    if (!el) {
      el = document.createElement("div");
      el.className = "activity-row";
      el.dataset.key = r.row.key;
      entry.rows.set(r.row.key, el);
      drawRow(el, r.row);
      addItem(entry, el);
    } else {
      if (!r.gen.text) entry.placeholder = false;
      drawRow(el, r.row);
      // A late result in a closed step: its label and failed mark.
      draw(entry);
    }
    updateBlockSummary();
    onChange();
  }

  // The row rendered again (lit writes only what changed: a toggled raw
  // command, an opened diff or read and the thumbs stay), its stop-task
  // button in its slot, its plugin refs bound to its title (refs.js).
  function drawRow(el, row) {
    render(toolRowInnerTemplate(row, { thumbs: rowThumbs, stop: syncTaskStop(el, row) }), el);
    bindRowRefs(el, row);
  }

  // The stop-task button of a running task_wait's row (after its title),
  // nothing once the row completes.
  function syncTaskStop(el, row) {
    const taskId = taskStop?.target(row);
    let btn = rowStops.get(el);
    if (!taskId) {
      rowStops.delete(el);
      return nothing;
    }
    if (btn) {
      btn.disabled = taskStop.busy(taskId);
      return btn;
    }
    const command = () => taskCommand(turn?.gens, taskId);
    btn = taskStopButton(taskStop, taskId, { command });
    rowStops.set(el, btn);
    return btn;
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
    pendingSteers.push(elementOf(steerRowTemplate(data)));
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
      // The outline (turn_model.js outlineRuns): open on its narrated steps'
      // rows, as a reload draws it; a block with nothing said closes.
      if (newestFirst) chronological();
      const outlined = outlineBlock(blockEl, model.blockGens(turn));
      if (!blockToggled) blockEl.open = outlined;
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

  // The steps back in chronological order after newestFirst (a no-op
  // otherwise); a fold (outlineBlock) stays before its run's first step.
  function chronological() {
    if (!blockEl || !turn) return;
    for (const gen of turn.gens) {
      const entry = genEls.get(gen);
      if (entry?.el.parentNode !== blockEl) continue;
      const nodes = stepNodes(entry);
      const fold = nodes[0].previousSibling;
      if (fold?.classList?.contains("outline-fold")) nodes.unshift(fold);
      blockEl.append(...nodes);
    }
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
    // +now+: the page's clock at a live start (stream_handlers.js), null
    // for a replayed one.
    generationStarted(data, now = null) {
      if (!turn) this.turnStarted({});
      apply(model.generationStarted(turn, data.iteration ?? null, now));
    },
    chunk({ text, thinking, iteration, now = null }) {
      if (!text && !thinking) return;
      if (!turn) this.turnStarted({});
      const r = model.chunk(turn, { text, thinking, iteration, now });
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
    // The running turn's asking reply (turn_model.js askingText): what a
    // question or approval card keeps once answered.
    askingText: () => model.askingText(turn),
    // A question's refs (its pending question's) on the step that asks it.
    questionRefs(refs) {
      if (turn) model.questionRefs(turn, refs);
    },
    step(i) {
      const entry = turn && genEls.get(turn.gens[i]);
      return entry ? { el: entry.el, summary: entry.el.querySelector(":scope > summary"), thinkingWrap: thinkingWrap(entry) } : null;
    },
    chronological,
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

// The text of a reloaded block's step +iteration+ (1-based, as the snapshot's
// cards count), "" when it has none: a reloaded question card's asking
// reply, as written (a rendered step keeps it as data-copy-source).
export function stepText(block, iteration) {
  const step = block?.querySelectorAll(":scope > .gen")[Number(iteration) - 1];
  const text = step?.querySelector(":scope > .gen-text");
  return text?.getAttribute("data-copy-source") ?? text?.textContent ?? "";
}

// A re-rendered failed turn's line (a .bubble.cancel, as live's
// addEndBubble), in turn_failed's words (failedTurnText) from what the turn
// record kept of it (SessionMetrics' failure: summary, message,
// error_class, kept_steps); nothing for any other record, or a failed one
// saved before records kept that.
function failedLineTemplate(record) {
  const failure = record?.status === "failed" ? record.failure : null;
  if (!failure || typeof failure !== "object") return nothing;
  return html`<div class="bubble cancel">${failedTurnText(failure)}</div>`;
}

// A reloaded history in the turn view (renderHistory's object path), as
// nodes: per turn the prompt, a collapsed block of its steps when it had
// any (stepTemplate, the live page's: texts, and with the server's parts
// the thinking, params and output, from the saved messages; status and
// duration from the timing's tool records), then the answer and the turn's
// timing line under it.
// +thumbs(images)+ draws a prompt's or a tool row's image thumbs (a
// template, images.js thumbsTemplate). +workingSet+ (the stage view's
// web.working_set, never the turn view's): each block stamped with its
// turn's ordinal and its rows with theirs (working_set_view.js), and the
// turn's footprint line after it.
export function turnHistoryNodes(items, timing, { thumbs, workingSet = false }) {
  const timingTemplate = (group) => {
    const record = group.record;
    // Numbered by its place in the turn records, as live (a failed turn
    // whose prompt went back still counts).
    const at = (timing?.turnRecords || []).indexOf(record);
    return record && formatDuration(record.duration_ms)
      ? html`<div class="turn-timing">${turnTimingText(at >= 0 ? at + 1 : group.turnIndex + 1, record.duration_ms, { canceled: record.status === "canceled" })}</div>`
      : nothing;
  };
  // An answer's bubble; +at+, the message's index, is for its refs
  // (data-answer-at, gone before the nodes are returned).
  const answerBubble = (at, cls = "") => answerBubbleTemplate(items[at], { cls, at });
  // The timing line after the bubble, not in it: where the live view
  // leaves it at the turn's end.
  const answerTemplate = (at, timing) => html`${answerBubble(at)}${timing}`;
  // A user's line, labelled when chi brought it in (a delegate report). A
  // `!cmd`'s saved message (the worker's "!(<command>)\n<output>") renders
  // as its command bubble, as live does — not as a user bubble.
  const userTemplate = (m, opts = {}) => {
    const shell = shellCommandMessage(m?.content);
    if (shell) return commandBubbleTemplate(shell);
    return userBubbleTemplate(m, { label: sourceLabel(m?.source), thumbs: thumbs(m.images), ...opts });
  };
  // The first text after a delegate report merged mid-turn, unless it is
  // the turn's answer (shown anyway).
  const reportReplyTemplate = (i, group) => {
    if (items[i]?.source !== "delegate_report") return nothing;
    const j = items.findIndex((m, k) => k > i && m?.role === "assistant" && String(m.content ?? "").trim());
    if (j < 0 || j === group.answer || items.slice(i + 1, j).some((m) => m?.role === "user" && !m.merged)) return nothing;
    return answerBubble(j, " report-reply");
  };
  const steerTemplate = (i, bubble) => steerRowTemplate({ source: items[i].source, text: items[i].content }, { bubble });
  const parts = [];
  // Each block's steps, in order: its outline once the nodes exist; and
  // its turn's place among the turns (the working set's stamp).
  const outlines = [];
  const blockTurns = [];
  let turnOrdinal = -1;
  for (const group of turnGroups(items, timing)) {
    if (group.kind === "note") { parts.push(noteBubbleTemplate(items[group.i])); continue; }
    if (group.kind === "steer") { parts.push(steerTemplate(group.i, true)); continue; }
    if (group.kind === "answer") { parts.push(answerTemplate(group.answer, nothing)); continue; }
    turnOrdinal += 1;
    const prompt = items[group.user];
    // A context wake turn starts with its note.
    parts.push(prompt.role === "note" ? noteBubbleTemplate(prompt) : userTemplate(prompt));
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
      // A step's text with its message's rendered markdown (html: web.markdown on).
      const gens = group.steps.map((step) => ({
        text: step.i === null ? "" : String(items[step.i].content ?? ""),
        html: step.i === null ? null : items[step.i].html ?? null,
        thinking: step.thinking || "", tools: step.tools,
      }));
      const steps = gens.map((gen, k) => stepTemplate(gen, {
        // The steers the step answered first, where the live rows went.
        steers: (group.steps[k].steers || []).map((i) => steerTemplate(i, false)),
        items: gen.tools.length ? [rowNodes(gen.tools, thumbs)] : [],
        // Its text knows its message's refs (a question's), as an answer does.
        at: group.steps[k].i,
      }));
      parts.push(html`<details class="turn-work done"><summary>${model.blockSummary({ gens, ended: true })}</summary>${steps}</details>`);
      outlines.push(gens);
      blockTurns.push(turnOrdinal);
      if (workingSet) parts.push(footprintTemplate(groupItems(group, turnOrdinal), turnOrdinal));
    }
    // Steers with no step to sit in, or in a turn that shows no block: on
    // their own after the prompt.
    const loose = noBlock ? [...group.steps.flatMap((step) => step.steers || []), ...(group.steers || [])] : group.steers || [];
    parts.push(loose.map((i) => steerTemplate(i, true)));
    // The user's lines merged into the turn: the live "steered" bubbles,
    // after its steps and before its answer. A delegate report's is
    // followed by the text that answered it when that isn't the answer: a
    // small model tells its user about a report before its next tool call,
    // and that step's text would stay folded in the block.
    parts.push((group.merged || []).map((i) =>
      html`${userTemplate(items[i], { state: "steered", step: items[i].step })}${reportReplyTemplate(i, group)}`));
    // A turn that ended with no answer: chi's muted notice where the answer
    // would be, before the timing, as live.
    if (group.emptyAnswer != null) parts.push(html`${emptyAnswerTemplate(items[group.emptyAnswer])}${timingTemplate(group)}`);
    // A turn with no answer (canceled, or running: no record yet) shows its
    // timing after its prompt and steps, where the live view leaves it.
    else if (group.answer === null) parts.push(timingTemplate(group));
    else parts.push(answerTemplate(group.answer, timingTemplate(group)));
    // A canceled turn ends with its cancel line, a failed one whose steps
    // stayed with its failure line, as the live view left them.
    parts.push(cancelLineTemplate(group.record));
    parts.push(failedLineTemplate(group.record));
  }
  const out = nodesOf(parts);
  // A finished turn's block as the live end leaves it: its outline, open.
  const blocks = [...out.children].filter((el) => el.matches(".turn-work"));
  blocks.forEach((block, i) => outlineBlock(block, outlines[i] || []));
  if (workingSet) stampHistory(blocks, blockTurns);
  // Each answer bubble and step text knows its message's refs
  // (answer_refs.js; the page pairs them after the render), the index
  // stays out of the DOM.
  for (const bubble of out.querySelectorAll("[data-answer-at]")) {
    setAnswerRefs(bubble, items[Number(bubble.dataset.answerAt)]?.display_refs);
    bubble.removeAttribute("data-answer-at");
  }
  return out;
}
