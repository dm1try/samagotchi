// The working-set list's order (docs/internals/working-set.md, The list's
// order): last touched first, and held still while the list is open.
//   recencyOrder  newest `last` (else `at`) first: turn, then step, then
//                 row; the items with neither (a preloaded memory never
//                 read, a used memory no row explains) after the rest, in
//                 the order they came.
//   heldOrder     the order taken at the open (+openKeys+, the item keys
//                 drawn then): the items not in it on top, newest first,
//                 the others where they stood.
// Only the popover's list is ordered this way; the rail, the footprints and
// the reader's side list keep the set's entry order.
//
// No DOM: `node --test` covers the rules; working_set_view.js uses them.
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.
import { itemKey } from "./working_set.js";

// An item's newest place: its last touch, else its first entry (an older
// page's item has no `last`), else null.
const placeOf = (item) => item?.last || item?.at || null;

// Which of two places is newer: > 0 when +a+ is.
function newer(a, b) {
  return (a.turn - b.turn) || (a.step - b.step) || (a.row - b.row);
}

// +items+ newest first (a copy; stable on ties).
export function recencyOrder(items) {
  return (items || [])
    .map((item, i) => ({ item, i, at: placeOf(item) }))
    .sort((x, y) => {
      if (x.at && y.at) return newer(y.at, x.at) || x.i - y.i;
      if (x.at || y.at) return x.at ? -1 : 1;
      return x.i - y.i;
    })
    .map((x) => x.item);
}

// +items+ in the order of +openKeys+ (the keys drawn at the open), the ones
// it doesn't hold before them, newest first; an item that left the set is
// simply not there. Without +openKeys+: recencyOrder.
export function heldOrder(items, openKeys) {
  if (!Array.isArray(openKeys)) return recencyOrder(items);
  const place = new Map(openKeys.map((key, i) => [key, i]));
  const fresh = recencyOrder((items || []).filter((item) => !place.has(itemKey(item))));
  const kept = (items || []).filter((item) => place.has(itemKey(item))).sort((a, b) => place.get(itemKey(a)) - place.get(itemKey(b)));
  return [...fresh, ...kept];
}
