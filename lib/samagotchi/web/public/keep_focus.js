// lit reuses a list's nodes by position (vendor/lit-html.js has no keyed
// repeat): after an item is inserted before the focused one, the focused
// node holds another item. keepFocus draws with +draw+ and puts the focus
// back on the item it was on, by its +attr+ (data-id, data-name): the same
// node inside it (by class), the item itself else; blurred when the item is
// gone, so no other item keeps it. Nothing is done when the focus wasn't
// inside +root+.
export function keepFocus(root, attr, draw) {
  const doc = root.ownerDocument;
  const itemOf = (node) => (node && node !== root && root.contains(node) ? node.closest(`[${attr}]`) : null);
  const was = doc.activeElement;
  const item = itemOf(was);
  const key = item && root.contains(item) ? item.getAttribute(attr) : null;
  const inner = item && was !== item ? was.className : null;
  draw();
  if (key === null || itemOf(doc.activeElement)?.getAttribute(attr) === key) return;
  const target = [...root.querySelectorAll(`[${attr}]`)].find((el) => el.getAttribute(attr) === key);
  if (!target) {
    if (root.contains(doc.activeElement)) doc.activeElement.blur?.();
    return;
  }
  const same = inner && [...target.querySelectorAll("*")].find((el) => el.className === inner);
  (same || target).focus();
}
