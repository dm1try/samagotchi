// A drawn diagram's regions, cleaned: what a renderer reported beside its SVG
// (block_frame.js), made safe to keep. Pure: no DOM, `node --test`.
// docs/internals/block-renderers.md, Regions.
//
// A region: {kind, id, label, box?, points?, from?, to?}; boxes and points are
// fractions of the picture (0..1). The bundle is trusted, its input is
// model-written: so nothing here stringifies the raw data (structured clone keeps
// cycles and BigInt), only an own key of a known name is read, strings are only
// ever strings, and the result is new objects. Over the caps the list goes whole
// (null), never cut: a picture with half its nodes tappable lies.
//
// What the page may do with a region's text: textContent, an aria-label, and
// composer text. Never markup, a selector, a URL, a data-* value another module
// reads back, or a key into an object.
//
// A module of its own: its exports are new (docs/internals/web-frontend.md).

export const REGION_KINDS = new Set(["node", "group", "edge", "note"]);
export const MAX_REGIONS = 600;
// The budget over the cleaned fields: the kept strings' lengths, plus 12 per number.
export const MAX_REGION_BYTES = 128 * 1024;
const NUMBER_BYTES = 12;
const ID_CHARS = 80;
const LABEL_CHARS = 120;
const MIN_POINTS = 2;
const MAX_POINTS = 16;

const own = (obj, key) => (Object.hasOwn(obj, key) ? obj[key] : undefined);

function plainObject(v) {
  if (v === null || typeof v !== "object" || Array.isArray(v)) return false;
  const proto = Object.getPrototypeOf(v);
  return proto === null || proto === Object.prototype || Object.getPrototypeOf(proto) === null;
}

const clamp = (n) => Math.min(1, Math.max(0, n));
const finite = (n) => typeof n === "number" && Number.isFinite(n);

// One line of text, or "": controls and line separators a space, bidi and
// zero-width format characters and lone surrogates gone, whitespace runs one
// space, cut by code points (a cut never splits a pair: Ruby's JSON refuses a
// lone surrogate, and the text can reach a prompt). The raw string is sliced
// first, so a megabyte label costs what a short one does.
export function cleanText(raw, max) {
  if (typeof raw !== "string") return "";
  const text = raw.slice(0, max * 8)
    .replace(/[\p{Cc}\p{Zl}\p{Zp}]/gu, " ")
    .replace(/[\p{Cf}\p{Cs}]/gu, "")
    .replace(/\s+/gu, " ")
    .trim();
  const points = Array.from(text);
  return points.length > max ? points.slice(0, max).join("").trimEnd() : text;
}

// [x, y, w, h] clamped and cut to the picture, or null: no area, or not 4
// finite numbers.
function cleanBox(raw) {
  if (!Array.isArray(raw) || raw.length !== 4 || !raw.every(finite)) return null;
  const x = clamp(raw[0]);
  const y = clamp(raw[1]);
  const w = Math.min(clamp(raw[2]), 1 - x);
  const h = Math.min(clamp(raw[3]), 1 - y);
  return w > 0 && h > 0 ? [x, y, w, h] : null;
}

function cleanPoints(raw) {
  if (!Array.isArray(raw) || raw.length < MIN_POINTS || raw.length > MAX_POINTS) return null;
  const out = [];
  for (const p of raw) {
    if (!Array.isArray(p) || p.length !== 2 || !finite(p[0]) || !finite(p[1])) return null;
    out.push([clamp(p[0]), clamp(p[1])]);
  }
  return out;
}

function cleanRegion(raw) {
  if (!plainObject(raw)) return null;
  const kind = own(raw, "kind");
  if (typeof kind !== "string" || !REGION_KINDS.has(kind)) return null;
  const region = { kind, id: cleanText(own(raw, "id"), ID_CHARS), label: cleanText(own(raw, "label"), LABEL_CHARS) };
  const box = cleanBox(own(raw, "box"));
  if (kind !== "edge") {
    if (!box) return null;
    region.box = box;
    return region;
  }
  const points = cleanPoints(own(raw, "points"));
  if (!points) return null;
  region.points = points;
  if (box) region.box = box;
  region.from = cleanText(own(raw, "from"), ID_CHARS);
  region.to = cleanText(own(raw, "to"), ID_CHARS);
  return region;
}

function weight(region) {
  const texts = region.id.length + region.label.length + (region.from?.length ?? 0) + (region.to?.length ?? 0);
  const numbers = (region.box ? 4 : 0) + (region.points ? region.points.length * 2 : 0);
  return texts + numbers * NUMBER_BYTES;
}

// @param raw what the frame's done carried (any value)
// @return a new array of clean regions, or null: none sent, not an array, over
//   MAX_REGIONS entries or past MAX_REGION_BYTES; entries that aren't regions are
//   skipped
export function cleanRegions(raw) {
  if (!Array.isArray(raw) || raw.length > MAX_REGIONS) return null;
  const out = [];
  let budget = MAX_REGION_BYTES;
  for (let i = 0; i < raw.length; i++) {
    const region = cleanRegion(raw[i]);
    if (!region) continue;
    budget -= weight(region);
    if (budget < 0) return null;
    out.push(region);
  }
  return out;
}
