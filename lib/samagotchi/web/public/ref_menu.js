// A ref's menu (refs.js): the small ▾ that shows next to a hovered or
// focused ref with more than one target, and the menu of its targets it
// opens (a tap and ↓ open it too). One of each per page, placed next to
// the ref (position: fixed); a scroll, a resize, a click elsewhere, Esc or
// Tab closes them. Keyboard: ↑/↓ (Home/End) move, Enter picks, Esc closes
// back to the ref.

// How long the ▾ stays after the pointer leaves the ref: long enough to
// reach it.
const HIDE_MS = 300;
// Kept from the viewport's edges (a phone's width).
const EDGE = 8;

// +doc+'s ▾ and menu. open(el, items, {focus}) shows +items+ ({id, label,
// run}) under +el+; showMore(el, onOpen) puts the ▾ after +el+, whose click
// calls +onOpen+; hideMoreSoon(el) takes it away unless the pointer reaches
// it; close({refocus}) closes the menu.
export function createRefMenu(doc = globalThis.document) {
  let more = null;
  let menu = null;
  let moreFor = null;
  let menuFor = null;
  let onMore = null;
  let hideTimer = null;
  const win = doc.defaultView || globalThis;

  function moreButton() {
    if (more) return more;
    more = doc.createElement("button");
    more.type = "button";
    more.className = "ref-more";
    more.textContent = "▾";
    more.title = "More for this ref";
    more.setAttribute("aria-label", "More for this ref");
    more.setAttribute("aria-haspopup", "menu");
    more.tabIndex = -1;
    more.hidden = true;
    more.addEventListener("mouseenter", () => clearTimeout(hideTimer));
    more.addEventListener("mouseleave", () => hideMoreSoon(moreFor));
    more.addEventListener("mousedown", (e) => e.preventDefault()); // keeps the ref's focus
    more.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      onMore?.();
    });
    doc.body.appendChild(more);
    return more;
  }

  function showMore(el, onOpen) {
    clearTimeout(hideTimer);
    const button = moreButton();
    moreFor = el;
    onMore = onOpen;
    button.hidden = false;
    const rect = lastRect(el);
    const top = rect.top + (rect.height - (button.offsetHeight || rect.height)) / 2;
    button.style.left = `${Math.min(rect.right + 2, win.innerWidth - (button.offsetWidth || 16) - 2)}px`;
    button.style.top = `${top}px`;
  }

  function hideMore() {
    clearTimeout(hideTimer);
    if (more) more.hidden = true;
    moreFor = null;
  }

  function hideMoreSoon(el) {
    if (!more || (el && el !== moreFor)) return;
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      if (menu && menuFor === moreFor) return;
      if (doc.activeElement && doc.activeElement === moreFor) return;
      hideMore();
    }, HIDE_MS);
  }

  function open(el, items, { focus = true } = {}) {
    close();
    menuFor = el;
    menu = doc.createElement("div");
    menu.className = "ref-menu";
    menu.setAttribute("role", "menu");
    for (const item of items) {
      const button = doc.createElement("button");
      button.type = "button";
      button.setAttribute("role", "menuitem");
      button.tabIndex = -1;
      button.dataset.target = item.id;
      button.textContent = item.label;
      button.addEventListener("click", (e) => {
        e.preventDefault();
        e.stopPropagation();
        close({ refocus: false });
        hideMore();
        item.run();
      });
      menu.appendChild(button);
    }
    menu.addEventListener("keydown", onMenuKey);
    menu.addEventListener("focusout", (e) => {
      if (menu && !menu.contains(e.relatedTarget) && e.relatedTarget) close({ refocus: false });
    });
    doc.body.appendChild(menu);
    place(menu, el);
    el.setAttribute("aria-expanded", "true");
    doc.addEventListener("pointerdown", onOutside, true);
    win.addEventListener("scroll", onScroll, true);
    win.addEventListener("resize", onScroll);
    if (focus) menuItems()[0]?.focus();
    return menu;
  }

  function close({ refocus = false } = {}) {
    if (!menu) return;
    const el = menuFor;
    menu.remove();
    menu = null;
    menuFor = null;
    el?.removeAttribute("aria-expanded");
    doc.removeEventListener("pointerdown", onOutside, true);
    win.removeEventListener("scroll", onScroll, true);
    win.removeEventListener("resize", onScroll);
    if (refocus) el?.focus?.();
  }

  function menuItems() {
    return menu ? [...menu.querySelectorAll('[role="menuitem"]')] : [];
  }

  function onMenuKey(e) {
    const items = menuItems();
    const at = items.indexOf(doc.activeElement);
    const go = (index) => items[(index + items.length) % items.length]?.focus();
    if (e.key === "ArrowDown") go(at + 1);
    else if (e.key === "ArrowUp") go(at < 0 ? -1 : at - 1);
    else if (e.key === "Home") go(0);
    else if (e.key === "End") go(-1);
    else if (e.key === "Escape") close({ refocus: true });
    else if (e.key === "Tab") { close({ refocus: true }); return; }
    else return;
    e.preventDefault();
    e.stopPropagation();
  }

  function onOutside(e) {
    if (menu?.contains(e.target) || more?.contains(e.target)) return;
    close();
  }

  function onScroll(e) {
    if (menu?.contains(e?.target)) return;
    close();
    hideMore();
  }

  // Under the ref's last line, flipped above it when there is no room
  // below, kept inside the viewport.
  function place(box, el) {
    const rect = lastRect(el);
    const first = el.getClientRects?.()[0] || rect;
    const width = box.offsetWidth;
    const height = box.offsetHeight;
    const left = Math.max(EDGE, Math.min(rect.left, win.innerWidth - width - EDGE));
    const below = rect.bottom + 4;
    const top = below + height > win.innerHeight - EDGE && first.top - height - 4 >= EDGE ? first.top - height - 4 : below;
    box.style.left = `${left}px`;
    box.style.top = `${top}px`;
  }

  return {
    open,
    close,
    showMore,
    hideMore,
    hideMoreSoon,
    get isOpen() { return !!menu; },
    get element() { return menu; },
    get moreButton() { return more; },
  };
}

// The ref's last line box (a ref wrapped over two lines ends on the
// second); its whole box when it has none.
function lastRect(el) {
  const rects = el.getClientRects?.() || [];
  return rects.length ? rects[rects.length - 1] : el.getBoundingClientRect();
}
