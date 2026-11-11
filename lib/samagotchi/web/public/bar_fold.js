// The session bar's fold (#infoBar): the bar is one row at every width, and
// what doesn't fit folds into ⋯ (more_sheet.js), the lowest rank first
// (info_bar_model.js BAR_ITEMS). foldPlan is the rule, pure, over measured
// widths; createBarFold is its watcher on the page: it measures, caches the
// widths, recomputes only when an input changes and writes the plan as three
// attributes on #infoBar that index.html's CSS hides by:
//   data-folded="notes toolkit dir"   (the folded keys: display:none, still in
//                                      the DOM, so a click from ⋯ reaches them)
//   data-compact="settings"           (⚙ as its icon, the dot when own)
//   data-empty-groups="relations"     (a group with nothing on the row, and
//                                      the hairline before it)
// lit renders into #infoText, inside #infoBar, so the attributes survive its
// redraws. docs/internals/web-frontend.md ("The session bar: one row").

import { BAR_ITEMS } from "./info_bar_model.js";
import { chipModel as settingsChipModel } from "./settings_chip.js";

// The page's phone width (index.html's 600 px cut): only phone: "row" items
// are row candidates there.
export const PHONE_QUERY = "(max-width: 600px)";

// The .meta's groups, left to right (info_bar.js infoBarHtml); the actions
// (#infoActions and ⋯) follow them.
export const META_GROUPS = Object.freeze(["identity", "setup", "relations", "trail"]);

// The chips a running turn rewrites: their text changes every tick, so they
// are left out of the signature and kept within a width budget instead.
export const LIVE_KEYS = Object.freeze(["ctx", "speed", "time"]);

// Items that are always in ⋯ and so don't count on it (more_sheet.js moreCount).
const UNCOUNTED = new Set(["archive", "delete", "more"]);

const pinned = (item) => item.rank === "pinned";
const rankOf = (item) => (pinned(item) ? Infinity : item.rank);

// The row's width with +row+ (items) on it, +compact+ (keys) in their compact
// form. +spacing+: {item: the gap between two chips of a group, group: from
// one group's last chip to the next's first (its hairline and gaps), bar:
// #infoBar's gap (between .info, #infoActions and ⋯), actions: the gap
// between two buttons}. +countWidth+: what the count on ⋯ adds, when any.
export function rowWidth(row, { widths, compact = new Set(), spacing, countWidth = 0, counted = false }) {
  const w = (item) => {
    const m = widths[item.key] || { full: 0 };
    return compact.has(item.key) && m.compact !== undefined ? m.compact : m.full;
  };
  let meta = 0;
  let drawn = 0;
  for (const group of META_GROUPS) {
    const its = row.filter((item) => item.group === group);
    if (!its.length) continue;
    meta += (drawn ? spacing.group : 0) + its.reduce((sum, item) => sum + w(item), 0) + spacing.item * (its.length - 1);
    drawn += 1;
  }
  const buttons = row.filter((item) => item.group === "actions" && item.key !== "more");
  const acts = buttons.reduce((sum, item) => sum + w(item), 0) + spacing.actions * Math.max(0, buttons.length - 1);
  const more = row.find((item) => item.key === "more");
  return meta + spacing.bar + acts + (more ? spacing.bar + w(more) + (counted ? countWidth : 0) : 0);
}

// The fold for +items+ (the BAR_ITEMS the session's bar has), +widths+
// ({key: {full, compact?}}, px), +available+ (the bar's content width, px)
// and +profile+ ("desktop" | "phone"):
//   1. every row candidate at its full form (on the phone only phone: "row"
//      ones, ⚙ there compact from the start; "menu" items never);
//   2. while the row is wider than +available+: the lowest rank still on it
//      (all of that rank together) goes compact when it has a compact form
//      not yet used, else it folds;
//   3. pinned items never fold: with only those left the row clips.
// @return {folded: Set, compact: Set, emptyGroups: [group]} (emptyGroups: the
//   META_GROUPS with no item on the row, in their order)
export function foldPlan({ items, widths, available, profile = "desktop", spacing, countWidth = 0 }) {
  const phone = profile === "phone";
  const candidate = (item) => item.rank !== "menu" && (!phone || item.phone === "row");
  const folded = new Set(items.filter((item) => !candidate(item)).map((item) => item.key));
  const compact = new Set(phone ? items.filter((item) => candidate(item) && item.compact).map((item) => item.key) : []);
  const onRow = () => items.filter((item) => !folded.has(item.key));
  const counted = () => [...folded].some((key) => !UNCOUNTED.has(key));
  const fits = () => rowWidth(onRow(), { widths, compact, spacing, countWidth, counted: counted() }) <= available;
  while (!fits()) {
    const foldable = onRow().filter((item) => !pinned(item));
    if (!foldable.length) break;
    const low = Math.min(...foldable.map(rankOf));
    const its = foldable.filter((item) => rankOf(item) === low);
    const shrink = its.filter((item) => item.compact && !compact.has(item.key));
    if (shrink.length) shrink.forEach((item) => compact.add(item.key));
    else its.forEach((item) => { folded.add(item.key); compact.delete(item.key); });
  }
  const row = onRow();
  const emptyGroups = META_GROUPS.filter((group) => !row.some((item) => item.group === group));
  return { folded, compact, emptyGroups };
}

// What, besides the bar's width, changes the fold: the items present and the
// text of each one that isn't live (a status, "set 9" → "set 10", a delegate
// starting to wait, the model's name), as one string. +bar+, +buttons+:
// info_bar_model.js sessionBar's.
export function foldSignature(bar, buttons) {
  if (!bar) return "";
  const gear = bar.settings ? settingsChipModel(bar.settings) : null;
  return JSON.stringify([
    bar.id, bar.status, bar.statusText, bar.model?.text, bar.model?.mismatch, gear?.text, gear?.own,
    bar.toolkit?.summary?.name, bar.toolkit?.summary?.label, bar.toolkit?.defaultKit, bar.notes?.text,
    bar.workingSet ? [bar.workingSet.chip?.n] : (bar.memories || []).join(","),
    bar.participants?.text, bar.participants?.count,
    bar.chain?.prev?.date, bar.chain?.prev?.id, bar.chain?.next?.date, bar.chain?.next?.id, bar.chain?.pruned,
    bar.parent?.id, bar.kids?.text, bar.kids?.waitingText, bar.dir, !!bar.speed,
    bar.worker?.badge?.text, bar.worker?.badge?.restart, bar.worker?.busy,
    buttons?.continue?.shown, buttons?.continue?.text, buttons?.stop?.shown,
    buttons?.archive?.shown, buttons?.delete?.shown,
  ]);
}

const px = (value) => parseFloat(value) || 0;

// The watcher. +barEl+: #infoBar; +win+: the window (matchMedia,
// ResizeObserver, getComputedStyle; a fake in the tests); +keysFor(bar,
// buttons)+: the BAR_ITEMS keys present (info_bar_model.js barItemKeys).
// update({bar, buttons}) after each render (app.js updateInfoBar, in the
// same task, before paint) → {folded, compact} (Sets); it recomputes only
// when the signature, the profile or the bar's width changed, or a live chip
// outgrew its budget. +onChange()+: a recompute the watcher started by itself
// (a resize, the fonts, a zoom), so the page can redraw ⋯ from the new fold.
// @return {update, recompute, folded(), compact()}
export function createBarFold({ barEl, keysFor, win = globalThis, doc = win.document, onChange = () => {} }) {
  const phoneQuery = win.matchMedia(PHONE_QUERY);
  // Natural widths per key + text (+ form); the live chips' budgets per key.
  const cache = new Map();
  const budgets = new Map();
  let last = { bar: null, buttons: null };
  let signature = null;
  let profile = null;
  let width = null;
  let plan = { folded: new Set(), compact: new Set(), emptyGroups: [] };

  const elOf = (item) => barEl.querySelector(item.selector);
  const textOf = (el) => `${el.className}|${el.textContent}`;
  const live = (item) => LIVE_KEYS.includes(item.key);
  // ⋯'s own width is read with its count blank (the count is countWidth).
  const cacheKey = (item, el, form) => (live(item) || item.key === "more" ? `${item.key}|${form}` : `${item.key}|${form}|${textOf(el)}`);
  const boxWidth = (el) => (el.getClientRects().length ? el.getBoundingClientRect().width : 0);
  const contentWidth = () => {
    const style = win.getComputedStyle(barEl);
    return barEl.clientWidth - px(style.paddingLeft) - px(style.paddingRight);
  };

  function setAttr(name, values) {
    const text = [...values].join(" ");
    if (text) barEl.setAttribute(name, text);
    else barEl.removeAttribute(name);
  }

  function apply(next) {
    plan = next;
    setAttr("data-folded", next.folded);
    setAttr("data-compact", next.compact);
    setAttr("data-empty-groups", next.emptyGroups);
  }

  // The spacing the row's CSS has now (a phone's groups are display:contents
  // with no hairline; a desktop's are flex boxes with one).
  function spacing() {
    const meta = barEl.querySelector(".meta");
    const group = barEl.querySelector(".meta .bar-group");
    const sep = barEl.querySelector(".meta .bar-sep");
    const metaGap = meta ? px(win.getComputedStyle(meta).columnGap) : 0;
    const groupStyle = group ? win.getComputedStyle(group) : null;
    const item = groupStyle && groupStyle.display !== "contents" ? px(groupStyle.columnGap) : metaGap;
    const sepWidth = sep && win.getComputedStyle(sep).display !== "none" ? boxWidth(sep) : 0;
    const actions = barEl.querySelector("#infoActions");
    return {
      item,
      group: sepWidth ? sepWidth + 2 * metaGap : metaGap,
      bar: px(win.getComputedStyle(barEl).columnGap),
      actions: actions ? px(win.getComputedStyle(actions).columnGap) : 0,
    };
  }

  // Every candidate's width, measured where none is cached: with the fold's
  // attributes off (a folded item has no box to read), and the row's children are
  // flex:none (index.html), so a width is its natural one. Synchronous: no
  // paint sees the unfolded row. The count on ⋯ is measured with two digits.
  function measure(items) {
    const forms = items.flatMap((item) => [["full", item], ...(item.compact ? [["compact", item]] : [])]);
    const need = () => forms.some(([form, item]) => { const el = elOf(item); return el && !cache.has(cacheKey(item, el, form)); })
      || !cache.has("more|count");
    if (need()) {
      const saved = ["data-folded", "data-compact", "data-empty-groups"].map((name) => [name, barEl.getAttribute(name)]);
      saved.forEach(([name]) => barEl.removeAttribute(name));
      const read = (form) => forms.filter(([f]) => f === form).forEach(([, item]) => {
        const el = elOf(item);
        if (el) cache.set(cacheKey(item, el, form), boxWidth(el));
      });
      const more = barEl.querySelector("#infoMoreBtn");
      const count = more?.querySelector(".more-count");
      const before = count ? count.textContent : "";
      if (count) count.textContent = "";
      read("full");
      if (count) {
        const bare = boxWidth(more);
        count.textContent = "88";
        cache.set("more|count", Math.max(0, boxWidth(more) - bare));
        count.textContent = before;
      } else {
        cache.set("more|count", 0);
      }
      barEl.setAttribute("data-compact", items.filter((item) => item.compact).map((item) => item.key).join(" "));
      read("compact");
      saved.forEach(([name, value]) => (value === null ? barEl.removeAttribute(name) : barEl.setAttribute(name, value)));
    }
    const widths = {};
    for (const item of items) {
      const el = elOf(item);
      if (!el) continue;
      const full = cache.get(cacheKey(item, el, "full")) || 0;
      const entry = { full: live(item) ? Math.max(full, budgets.get(item.key) || 0) : full };
      if (item.compact) entry.compact = cache.get(cacheKey(item, el, "compact")) || 0;
      if (live(item)) budgets.set(item.key, entry.full);
      widths[item.key] = entry;
    }
    return widths;
  }

  function recompute() {
    const { bar, buttons } = last;
    if (!bar) {
      apply({ folded: new Set(), compact: new Set(), emptyGroups: [] });
      return plan;
    }
    const available = contentWidth();
    width = barEl.clientWidth;
    // A bar with no box (the start page, a hidden view): nothing to measure;
    // the resize that gives it one recomputes.
    if (!width) return plan;
    const keys = new Set(keysFor(bar, buttons));
    const items = BAR_ITEMS.filter((item) => keys.has(item.key));
    const phone = profile === "phone";
    const candidates = items.filter((item) => item.rank !== "menu" && (!phone || item.phone === "row"));
    const widths = measure(candidates);
    apply(foldPlan({ items, widths, available: available - 1, profile, spacing: spacing(),
                     countWidth: phone ? 0 : cache.get("more|count") || 0 }));
    return plan;
  }

  // A live chip on the row wider than its budget (a 3-digit speed, ctx ~100%).
  function outgrown() {
    return LIVE_KEYS.some((key) => {
      const item = BAR_ITEMS.find((i) => i.key === key);
      if (plan.folded.has(key)) return false;
      const el = elOf(item);
      if (!el || !el.getClientRects().length) return false;
      const w = boxWidth(el);
      if (w <= (budgets.get(key) || 0) + 0.5) return false;
      budgets.set(key, w);
      return true;
    });
  }

  function update({ bar, buttons }) {
    last = { bar, buttons };
    const sig = foldSignature(bar, buttons);
    const prof = phoneQuery.matches ? "phone" : "desktop";
    if (sig !== signature || prof !== profile || barEl.clientWidth !== width || (bar && outgrown())) {
      // The phone's CSS sizes every chip anew.
      if (prof !== profile) { cache.clear(); budgets.clear(); }
      signature = sig;
      profile = prof;
      recompute();
    }
    return { folded: plan.folded, compact: plan.compact };
  }

  // Inputs the page's redraws don't carry: the bar's width, the profile, the
  // fonts (a webfont swapped in) and the zoom (both change every width).
  const again = ({ clear = false } = {}) => {
    const prof = phoneQuery.matches ? "phone" : "desktop";
    if (clear || prof !== profile) { cache.clear(); budgets.clear(); }
    profile = prof;
    recompute();
    onChange();
  };
  if (win.ResizeObserver) {
    new win.ResizeObserver(() => { if (barEl.clientWidth !== width) again(); }).observe(barEl);
  }
  phoneQuery.addEventListener?.("change", () => again());
  doc?.fonts?.ready?.then?.(() => again({ clear: true }));
  const watchZoom = () => {
    const query = win.matchMedia(`(resolution: ${win.devicePixelRatio || 1}dppx)`);
    query.addEventListener?.("change", () => { again({ clear: true }); watchZoom(); }, { once: true });
  };
  watchZoom();

  return { update, recompute, folded: () => plan.folded, compact: () => plan.compact };
}
