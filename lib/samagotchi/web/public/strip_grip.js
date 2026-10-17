import { GRIP_OPEN_PX } from "./composer_size.js";
import { stripGripAction, stripGripTitle } from "./strip.js";

// The latest-sessions strip's grip (used by app.js): the handle on the edge
// between the strip and the chat, the composer's grip's twin, mirrored. A
// drag up (or a tap) hides the strip, a drag down (or a tap) shows it, and
// Enter or Space toggles too. The strip snaps: unlike the composer's box it
// does not follow the pointer, so nothing is measured while dragging — only
// whether the release would act (.will-toggle, the pill in the accent).
// The grip owns its title and aria-expanded (composer_grip.js's
// drawFoldControls does the same for the composer's): app.js calls the
// returned refresh() from applyStripHidden, and nothing else writes them.
// No click listener: a click still fires after pointerdown's preventDefault
// and would toggle twice. No document listener either: the composer's grip
// needs one for typing on the page, this one acts only on itself.
// +setHidden(true)+ hides the strip, +isHidden()+ says whether it is hidden.
export function createStripGrip({ gripEl, isHidden, setHidden }) {
  let willToggle = false;

  function refresh() {
    const hidden = isHidden();
    gripEl.setAttribute("aria-expanded", hidden ? "false" : "true");
    gripEl.title = stripGripTitle({ hidden, willToggle });
  }

  function setWillToggle(will) {
    if (will === willToggle) return;
    willToggle = will;
    gripEl.classList.toggle("will-toggle", will);
    refresh();
  }

  gripEl.addEventListener("pointerdown", (e) => {
    e.preventDefault();
    gripEl.setPointerCapture(e.pointerId);
    gripEl.classList.add("dragging");
    const startY = e.clientY;
    // Past a tap's size, and the release would act: the pill promises. A
    // tap-sized move never flickers it (that stays a tap).
    const willAfter = (dy) => Math.abs(dy) >= GRIP_OPEN_PX && stripGripAction({ hidden: isHidden(), dy }) !== null;
    const move = (ev) => setWillToggle(willAfter(ev.clientY - startY));
    const end = () => {
      gripEl.classList.remove("dragging");
      gripEl.removeEventListener("pointermove", move);
      gripEl.removeEventListener("pointerup", up);
      gripEl.removeEventListener("pointercancel", cancel);
    };
    const up = (ev) => {
      const action = stripGripAction({ hidden: isHidden(), dy: ev.clientY - startY });
      end();
      setWillToggle(false);
      if (action) setHidden(action === "hide");
      refresh();
    };
    const cancel = () => {
      end();
      setWillToggle(false);
      refresh();
    };
    gripEl.addEventListener("pointermove", move);
    gripEl.addEventListener("pointerup", up);
    gripEl.addEventListener("pointercancel", cancel);
  });

  // Enter or Space on the focused handle toggles (preventDefault: Space
  // would scroll the page).
  gripEl.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" && e.key !== " ") return;
    e.preventDefault();
    setHidden(!isHidden());
    refresh();
  });

  refresh();
  return refresh;
}
