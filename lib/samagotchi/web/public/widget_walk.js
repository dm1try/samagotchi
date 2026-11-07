// A chi-ui walk (docs/internals/inline-widgets.md): a scenario stepped through
// one step at a time. On top a swimlane, one column per actor and one row per
// step (the current, the seen and a case's target marked; a click jumps); under
// it the step's card (the actor, what it does, "You see", the dashed "Behind
// it"); a fork asks "Which case?" instead of Next; Back, Next and the path
// taken, and the arrow keys while the widget has the focus. Ported from eval
// 0013's viewer.
//
// The data is P1a's normalised JSON (InlineWidgets): ids are strings, every
// next and goto names a step, round 1's branches are cases. Its strings are
// the model's: they go in as textContent or attributes only, never markup.
// The position lives here, in the widget: a rewrite of the bubble starts over.
//
// A module of its own: static JS is cached at unversioned URLs.

// A case that is no condition: round 1 wrote the usual path as "always".
export const ALWAYS = /^(always|otherwise|then|next)$/i;
export const USUAL = "otherwise (the usual path)";
// A step's `next: end` (InlineWidgets::END_NEXT): the walk ends there, a
// branch that ends early.
export const END = "end";

const isAlways = (when) => ALWAYS.test(String(when ?? "").trim());

// Where each step of +walk+ goes, by index.
// - nextOf(k): the step after k when it isn't a fork: its next, else a case
//   that is no condition, else the step below; null at the end, and at a
//   step whose next is `end`.
// - casesOf(k): a fork's cases, [{when, to}] (to null when the goto names no
//   step), or null when k is no fork. A case that is no condition reads as
//   the usual path, and a step that names a next as well offers it first when
//   no case goes there (round 1's next + branches).
export function walkRoutes(walk) {
  const steps = walk?.steps || [];
  const byId = new Map(steps.map((s, k) => [String(s.id), k]));
  const idx = (id) => (id == null ? null : byId.get(String(id)) ?? null);
  const casesIn = (k) => (Array.isArray(steps[k]?.cases) ? steps[k].cases : []);
  const isFork = (k) => casesIn(k).some((c) => !isAlways(c.when));

  function nextOf(k) {
    const step = steps[k];
    if (!step || step.next === END) return null;
    const named = idx(step.next);
    if (named != null) return named;
    const always = casesIn(k).find((c) => isAlways(c.when) && idx(c.goto) != null);
    if (always && !isFork(k)) return idx(always.goto);
    return k + 1 < steps.length ? k + 1 : null;
  }

  function casesOf(k) {
    if (!isFork(k)) return null;
    const cases = casesIn(k).map((c) => ({ when: isAlways(c.when) ? USUAL : String(c.when ?? ""), to: idx(c.goto) }));
    const named = idx(steps[k].next);
    if (named != null && !cases.some((c) => c.to === named)) cases.unshift({ when: USUAL, to: named });
    return cases;
  }

  return { steps, nextOf, casesOf };
}

// The swimlane's cells: one per step, in its actor's column (1-based, after
// the number column) and its own row (after the actors' row), with a tag that
// says where it leads when that isn't the step below: "N cases", "→ n", "end".
export function swimlaneCells(walk, routes = walkRoutes(walk)) {
  const actors = (walk?.actors || []).map(String);
  const { steps, nextOf, casesOf } = routes;
  return steps.map((s, k) => {
    const cases = casesOf(k);
    const next = nextOf(k);
    let tag = null;
    if (cases) tag = { text: `${cases.length} cases`, fork: true };
    else if (next != null && next !== k + 1) tag = { text: `→ ${next + 1}`, fork: false };
    else if (next == null && k < steps.length - 1) tag = { text: "end", fork: false };
    return { k, column: Math.max(0, actors.indexOf(String(s.actor))) + 2, row: k + 2, text: String(s.does || s.sees || ""), tag };
  });
}

// Where the walker is: the path taken (step indexes) and the steps seen.
// next() at the end starts over.
export function createWalker(routes) {
  let path = [0];
  const seen = new Set([0]);
  return {
    get at() { return path[path.length - 1]; },
    get path() { return [...path]; },
    seen: (k) => seen.has(k),
    go(k) {
      if (k == null || !routes.steps[k] || k === this.at) return;
      path.push(k);
      seen.add(k);
    },
    back() { if (path.length > 1) path.pop(); },
    next() {
      const n = routes.nextOf(this.at);
      if (n != null) { this.go(n); return; }
      path = [0];
      seen.clear();
      seen.add(0);
    },
  };
}

// The path's words under the card, empty before the first move.
export function trailText(path) {
  return path.length > 1 ? `path ${path.map((k) => k + 1).join(" → ")}` : "";
}

function el(doc, tag, className, text) {
  const node = doc.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = String(text);
  return node;
}

function button(doc, className, text) {
  const node = el(doc, "button", className, text);
  node.type = "button";
  return node;
}

// The walk as an element, for a widget host's shadow root.
export function drawWalk(walk, doc = document) {
  const routes = walkRoutes(walk);
  const { steps, nextOf, casesOf } = routes;
  const actors = (walk.actors || []).map(String);
  const walker = createWalker(routes);

  const box = el(doc, "div", "w walk");
  box.tabIndex = 0;
  box.setAttribute("role", "group");
  box.setAttribute("aria-label", `Walk: ${walk.title || "a scenario"}`);
  const head = el(doc, "div", "w-head");
  const count = el(doc, "span", "w-count");
  head.append(el(doc, "span", "w-kind", "Walk"), el(doc, "span", "w-title", walk.title || ""), count);
  const body = el(doc, "div", "w-body");
  box.append(head, body);

  const lane = el(doc, "div", "ww-swim");
  lane.style.setProperty("--actors", String(actors.length));
  lane.append(el(doc, "span"));
  for (const actor of actors) lane.append(el(doc, "span", "ww-swim-actor", actor));
  const cells = swimlaneCells(walk, routes).map((cell) => {
    const num = el(doc, "span", "ww-swim-num", cell.k + 1);
    num.style.gridRow = String(cell.row);
    const node = button(doc, "ww-cell");
    node.style.gridColumn = String(cell.column);
    node.style.gridRow = String(cell.row);
    node.append(el(doc, "span", "ww-cell-t", cell.text));
    if (cell.tag) node.append(el(doc, "span", cell.tag.fork ? "ww-tag fork" : "ww-tag", cell.tag.text));
    const s = steps[cell.k];
    node.title = `${s.does || ""}${s.does && s.sees ? "\n" : ""}${s.sees ? `sees: ${s.sees}` : ""}`;
    node.setAttribute("aria-label", `Step ${cell.k + 1}, ${s.actor}: ${cell.text}`);
    node.addEventListener("click", () => { walker.go(cell.k); render(); });
    lane.append(num, node);
    return node;
  });

  const card = el(doc, "div", "ww-step");
  card.setAttribute("aria-live", "polite");
  const nav = el(doc, "div", "ww-nav");
  const prev = button(doc, "btn", "← Back");
  const next = button(doc, "btn primary", "Next →");
  const trail = el(doc, "span", "ww-trail");
  nav.append(prev, trail, next);
  body.append(lane, card, nav);

  prev.addEventListener("click", () => { walker.back(); render(); });
  next.addEventListener("click", () => { walker.next(); render(); });
  box.addEventListener("keydown", (e) => {
    if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return;
    if (e.key === "ArrowRight" && !next.hidden) { e.preventDefault(); next.click(); }
    if (e.key === "ArrowLeft" && !prev.disabled) { e.preventDefault(); prev.click(); }
  });

  const peek = (k, on) => cells[k]?.classList.toggle("peek", on);

  function pane(className, label, text) {
    const node = el(doc, "div", `ww-pane ${className}`);
    node.append(el(doc, "span", "eyebrow", label), el(doc, "span", null, text));
    return node;
  }

  // A keyboard move can remove, hide or disable the focused button (a case,
  // Next at a fork, Back at the start): the focus stays in the widget.
  function render() {
    const focused = box.getRootNode()?.activeElement;
    const hadFocus = !!focused && box.contains(focused);
    const k = walker.at;
    const s = steps[k] || {};
    card.replaceChildren();
    const top = el(doc, "div", "ww-step-top");
    top.append(el(doc, "span", "ww-actor", s.actor || ""), el(doc, "span", "ww-stepno", `${k + 1} / ${steps.length}`));
    card.append(top);
    if (s.does) card.append(el(doc, "div", "ww-does", s.does));
    if (s.sees) card.append(pane("ww-sees", "You see", s.sees));
    if (s.behind) card.append(pane("ww-behind", "Behind it", s.behind));
    const cases = casesOf(k);
    if (cases) {
      const fork = el(doc, "div", "ww-fork");
      fork.append(el(doc, "span", "eyebrow", "Which case?"));
      for (const c of cases) {
        const b = button(doc, "ww-case");
        b.append(el(doc, "span", null, c.when), el(doc, "span", "ww-case-to", c.to != null ? `step ${c.to + 1} →` : "?"));
        b.disabled = c.to == null;
        b.addEventListener("click", () => { walker.go(c.to); render(); });
        for (const [type, on] of [["mouseenter", true], ["mouseleave", false], ["focus", true], ["blur", false]]) {
          b.addEventListener(type, () => peek(c.to, on));
        }
        fork.append(b);
      }
      card.append(fork);
    }
    cells.forEach((cell, j) => {
      cell.classList.toggle("cur", j === k);
      cell.classList.toggle("seen", walker.seen(j) && j !== k);
      cell.classList.remove("peek");
      if (j === k) cell.setAttribute("aria-current", "step");
      else cell.removeAttribute("aria-current");
    });
    count.textContent = `step ${k + 1} of ${steps.length}`;
    prev.disabled = walker.path.length < 2;
    next.hidden = !!cases;
    next.textContent = nextOf(k) == null ? "Start over" : "Next →";
    trail.textContent = trailText(walker.path);
    if (hadFocus && (!focused.isConnected || focused.hidden || focused.disabled)) box.focus({ preventScroll: true });
  }

  render();
  return box;
}
