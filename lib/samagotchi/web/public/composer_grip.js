import { GRIP_CLICK_FOLD_MS, GRIP_OPEN_PX, gripFloor, gripFolds, gripGesture } from "./composer_size.js";
import { COMPOSER_FOLD_KEY, composerFolded, foldHandle, opensOnKey } from "./composer_fold.js";
import { readStored, removeStored, writeStored } from "./storage.js";

// The composer's grip and fold (made by composer_mount.js): the grip's drag, click
// and keys, the fold's state per visit and its page-wide listeners. The mount keeps
// the box's height (fitPrompt) and the grip's floor (+floor+ / +setFloor+), which
// fitPrompt reads; the floor is saved under GRIP_KEY.
export const GRIP_KEY = "chi_composer_floor";

// +session+: the open session's id, or null (the start page). +draft+,
// +waiting+, +allViewOpen+, +lightboxOpen+: what the page shows now.
// +imageFiles+ / +addImageFiles+: a drop's images and the chips.
// The owner page's own parts (composer_mount.js passes them through):
// +infoBarEl+ (a file dropped on it while folded; may be null);
// +typeAnywhere+: typing on the page opens a folded composer. Stop turn
// isn't the composer's: it sits in the stage's status row (stage_view.js).
export function createComposerGrip({
  composeGrip, promptEl, infoBarEl = null,
  session, fitPrompt, promptMinPx, floor, setFloor,
  draft, waiting = () => false, allViewOpen = () => false, lightboxOpen = () => false,
  imageFiles, addImageFiles, typeAnywhere = true,
  doc = globalThis.document, win = globalThis.window,
}) {
  // The composer's fold (composer_fold.js): the grip, which is the handle
  // while folded. +gripWillFold+: the drag in progress is past the fold
  // threshold.
  const gripStartTitle = composeGrip.title;
  let gripWillFold = false;
  // A click on the expanded grip folds GRIP_CLICK_FOLD_MS after it, so a
  // second click in that window can still mean "reset the height" (a
  // double-click). A drag or a key acts at once and takes the wait back.
  let pendingFold = null;
  // This visit's state (a visit is one select() call): opened by the page
  // (a focus, a restored line), archived (decided once, from the visit's
  // first getSession answer).
  const newFoldVisit = () => ({ open: false, archived: false, decided: false });
  let foldVisit = newFoldVisit();

  function cancelPendingFold() {
    if (!pendingFold) return;
    clearTimeout(pendingFold);
    pendingFold = null;
  }

  // The grip's custom height, forgotten only by a double-click.
  function resetFloor() {
    setFloor(null);
    removeStored(GRIP_KEY);
    fitPrompt();
  }

  // One release of the grip is one gesture, decided by composer_size.js's
  // gripGesture: a drag down past the box folds the composer on release (a
  // session only: the start page's grip only resizes); from folded, a pull up
  // opens it and the box follows the pointer in the same gesture, a tap opens it
  // and focuses the box; a click on the expanded grip folds it too, GRIP_CLICK_FOLD_MS
  // after the release so a second click in that window can still reset the height.
  // No click listener: a click still fires after pointerdown's preventDefault,
  // so the release is the one that acts.
  composeGrip.addEventListener("pointerdown", (e) => {
    e.preventDefault();
    composeGrip.setPointerCapture(e.pointerId);
    composeGrip.classList.add("dragging");
    const tapY = e.clientY;
    // The height the box had before this press: a drag that folds brings it back.
    const floorBefore = floor();
    let startY = tapY;
    let startH = promptEl.offsetHeight;
    let opened = false;
    const move = (ev) => {
      if (session() && isComposerFolded()) {
        if (startY - ev.clientY < GRIP_OPEN_PX) return;
        setComposerFolded(false);
        opened = true;
        // Re-based after the unfold (its fitPrompt sized the box: the minimum
        // when empty, the text's height with a draft).
        startH = promptEl.offsetHeight;
        startY = ev.clientY;
        return;
      }
      const requested = startH + (startY - ev.clientY);
      setFloor(gripFloor(requested, win.innerHeight, promptMinPx()));
      fitPrompt();
      const willFold = !!session() && gripFolds({ requestedPx: requested, shownPx: promptEl.offsetHeight });
      if (willFold !== gripWillFold) {
        gripWillFold = willFold;
        composeGrip.classList.toggle("will-fold", willFold);
        drawFoldControls();
      }
    };
    const end = () => {
      composeGrip.classList.remove("dragging");
      composeGrip.removeEventListener("pointermove", move);
      composeGrip.removeEventListener("pointerup", up);
      composeGrip.removeEventListener("pointercancel", cancel);
      const folds = gripWillFold;
      gripWillFold = false;
      composeGrip.classList.remove("will-fold");
      return folds;
    };
    const up = (ev) => {
      const folds = end();
      const gesture = gripGesture({
        session: !!session(),
        folded: isComposerFolded(),
        dy: ev.clientY - tapY,
        willFold: folds,
        pending: !!pendingFold,
      });
      if (gesture === "fold") {
        cancelPendingFold();
        // The drag asked for a smaller box, but opening it brings back the
        // height it had before the press: only a double-click forgets it.
        setFloor(floorBefore);
        writeStored(GRIP_KEY, String(floorBefore || ""));
        setComposerFolded(true);
      } else if (gesture === "open") {
        cancelPendingFold();
        setComposerFolded(false);
        promptEl.focus();
      } else if (gesture === "reset") {
        resetFloor();
      } else if (gesture === "hide") {
        writeStored(GRIP_KEY, String(floor() || ""));
        pendingFold = setTimeout(() => {
          pendingFold = null;
          setComposerFolded(true);
        }, GRIP_CLICK_FOLD_MS);
      } else if (gesture === "resize") {
        // A drag that stops short of folding: keep the box at the height it asks for.
        cancelPendingFold();
        writeStored(GRIP_KEY, String(floor() || ""));
        // A pull that opened the box leaves the focus in it, as a tap does.
        if (opened) promptEl.focus();
      }
      drawFoldControls();
    };
    const cancel = () => {
      end();
      drawFoldControls();
    };
    composeGrip.addEventListener("pointermove", move);
    composeGrip.addEventListener("pointerup", up);
    composeGrip.addEventListener("pointercancel", cancel);
  });
  composeGrip.addEventListener("dblclick", () => {
    if (session() && isComposerFolded()) return;
    cancelPendingFold();
    resetFloor();
  });
  // Enter or Space on the focused handle folds, or opens and focuses the box
  // (a session only; preventDefault: Space would scroll the page). At once:
  // the keyboard has no double-click to wait for.
  composeGrip.addEventListener("keydown", (e) => {
    if (!session() || (e.key !== "Enter" && e.key !== " ")) return;
    e.preventDefault();
    cancelPendingFold();
    if (isComposerFolded()) {
      setComposerFolded(false);
      promptEl.focus();
    } else {
      setComposerFolded(true);
    }
  });

  // ── Composer fold (composer_fold.js) ───────────────────────────────────────
  // Dragging the composer's grip down folds the session's composer away; the
  // grip, now the handle on the info bar's top edge, pulled up or clicked, or
  // typing on the page, brings it back. The user's own choice is saved per
  // browser; an archived session opens folded for its visit, and expanding
  // there saves nothing. The page's own focus or a restored line opens it
  // for the visit only. The start page never folds.
  function composerFoldSaved() {
    return readStored(COMPOSER_FOLD_KEY) === "1";
  }
  function isComposerFolded() {
    return !!session() && composerFolded({ saved: composerFoldSaved(), archivedVisit: foldVisit.archived, visitOpen: foldVisit.open });
  }
  function applyComposerFolded() {
    const folded = isComposerFolded();
    // Anything else opened the composer: the click's wait for its fold is over.
    if (!folded) cancelPendingFold();
    const was = doc.body.classList.contains("composer-folded");
    doc.body.classList.toggle("composer-folded", folded);
    // Its height was measured while hidden.
    if (was && !folded) fitPrompt();
    drawFoldControls();
  }
  // The user's own fold or unfold (the grip, typing): saved, unless this
  // is an archived visit (both are for the visit then).
  function setComposerFolded(folded) {
    if (foldVisit.archived) {
      foldVisit.open = !folded;
    } else {
      writeStored(COMPOSER_FOLD_KEY, folded ? "1" : "0");
      foldVisit.open = false;
    }
    applyComposerFolded();
  }
  // The page opens it for this visit: nothing saved.
  function openForVisit() {
    if (!isComposerFolded()) return;
    foldVisit.open = true;
    applyComposerFolded();
  }
  // Every focus of the message box: in a session it opens a folded composer
  // for the visit first (+open+ false: only when it shows already).
  function focusPrompt({ open = true } = {}) {
    if (session() && isComposerFolded()) {
      if (!open) return;
      openForVisit();
    }
    promptEl.focus();
  }
  // The grip as the fold's handle (its title, marks, aria-expanded). The
  // start page's grip only resizes: no role, no fold state.
  function drawFoldControls() {
    const folded = isComposerFolded();
    if (!session()) {
      composeGrip.removeAttribute("role");
      composeGrip.removeAttribute("aria-expanded");
      composeGrip.title = gripStartTitle;
      for (const c of ["folded", "draft", "waiting"]) composeGrip.classList.remove(c);
      return;
    }
    const h = foldHandle({ folded, draft: draft(), waiting: folded && waiting() });
    composeGrip.title = gripWillFold ? "Release to hide the message box" : h.title;
    composeGrip.setAttribute("role", "button");
    composeGrip.setAttribute("aria-expanded", folded ? "false" : "true");
    composeGrip.classList.toggle("folded", h.folded);
    composeGrip.classList.toggle("draft", h.draft);
    composeGrip.classList.toggle("waiting", h.waiting);
  }
  promptEl.addEventListener("input", () => drawFoldControls());
  // Typing on the page opens a folded composer: the key lands in the box
  // (the class goes before the focus, so the browser types it there).
  if (typeAnywhere) {
    doc.addEventListener("keydown", (e) => {
      if (!isComposerFolded()) return;
      if (!opensOnKey(e, { active: doc.activeElement, allView: allViewOpen(), lightbox: lightboxOpen() })) return;
      setComposerFolded(false);
      promptEl.focus();
    });
  }
  // A file dropped on the folded info bar: open (for the visit), then add it.
  infoBarEl?.addEventListener("dragover", (e) => {
    if (!isComposerFolded() || ![...(e.dataTransfer?.types || [])].includes("Files")) return;
    e.preventDefault();
  });
  infoBarEl?.addEventListener("drop", (e) => {
    if (!isComposerFolded()) return;
    const files = imageFiles(e.dataTransfer);
    if (!files.length) return;
    e.preventDefault();
    openForVisit();
    addImageFiles(files);
  });

  return {
    isComposerFolded,
    openForVisit,
    focusPrompt,
    drawFoldControls,
    // A new visit (select(), the start page): nothing opened, not decided.
    newVisit() {
      foldVisit = newFoldVisit();
      applyComposerFolded();
    },
    // The visit's first getSession answer: an archived session opens folded.
    decideVisit(archived) {
      if (foldVisit.decided) return;
      foldVisit.decided = true;
      foldVisit.archived = !!archived;
      applyComposerFolded();
    },
  };
}
