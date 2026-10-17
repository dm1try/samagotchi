import { GRIP_OPEN_PX, gripFloor, gripFolds } from "./composer_size.js";
import { COMPOSER_FOLD_KEY, composerFolded, foldHandle, opensOnKey } from "./composer_fold.js";

// The composer's grip and fold (used by app.js): the grip's drag, tap and keys, the
// fold's state per visit and its page-wide listeners. app.js keeps the box's
// height (fitPrompt) and the grip's floor (+floor+ / +setFloor+), which
// fitPrompt reads; the floor is saved under GRIP_KEY.
export const GRIP_KEY = "chi_composer_floor";

// +session+: the open session's id, or null (the start page). +draft+,
// +waiting+, +turnRunning+, +allViewOpen+, +lightboxOpen+: what the page
// shows now. +imageFiles+ / +addImageFiles+: a drop's images and the chips.
export function createComposerGrip({
  composeGrip, promptEl, infoCancelBtn, infoBarEl,
  session, fitPrompt, promptMinPx, floor, setFloor,
  draft, waiting, turnRunning, allViewOpen, lightboxOpen,
  imageFiles, addImageFiles,
  doc = globalThis.document, win = globalThis.window,
}) {
  // The composer's fold (composer_fold.js): the grip, which is the handle
  // while folded, and the info bar's Stop turn while folded (the composer's
  // #cancelBtn is folded away then). +gripWillFold+: the drag in progress is
  // past the fold threshold.
  const gripStartTitle = composeGrip.title;
  let gripWillFold = false;
  // This visit's state (a visit is one select() call): opened by the page
  // (a focus, a restored line), archived (decided once, from the visit's
  // first getSession answer).
  const newFoldVisit = () => ({ open: false, archived: false, decided: false });
  let foldVisit = newFoldVisit();

  // A drag down past the box folds the composer on release (a session only: the
  // start page's grip only resizes); from folded, a pull up opens it and the box
  // follows the pointer in the same gesture, a tap opens it and focuses the box.
  // No click listener: a click still fires after pointerdown's preventDefault
  // and would toggle twice.
  composeGrip.addEventListener("pointerdown", (e) => {
    e.preventDefault();
    composeGrip.setPointerCapture(e.pointerId);
    composeGrip.classList.add("dragging");
    const tapY = e.clientY;
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
      if (folds) {
        // The next opening starts at the minimum (or the text's height).
        setFloor(null);
        try { localStorage.removeItem(GRIP_KEY); } catch (_) {}
        setComposerFolded(true);
      } else if (session() && isComposerFolded()) {
        if (Math.abs(ev.clientY - tapY) < GRIP_OPEN_PX) {
          setComposerFolded(false);
          promptEl.focus();
        }
      } else {
        try { localStorage.setItem(GRIP_KEY, String(floor() || "")); } catch (_) {}
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
    setFloor(null);
    try { localStorage.removeItem(GRIP_KEY); } catch (_) {}
    fitPrompt();
  });
  // Enter or Space on the focused handle folds, or opens and focuses the box
  // (a session only; preventDefault: Space would scroll the page).
  composeGrip.addEventListener("keydown", (e) => {
    if (!session() || (e.key !== "Enter" && e.key !== " ")) return;
    e.preventDefault();
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
    try {
      return localStorage.getItem(COMPOSER_FOLD_KEY) === "1";
    } catch (_) {
      return false;
    }
  }
  function isComposerFolded() {
    return !!session() && composerFolded({ saved: composerFoldSaved(), archivedVisit: foldVisit.archived, visitOpen: foldVisit.open });
  }
  function applyComposerFolded() {
    const folded = isComposerFolded();
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
      try { localStorage.setItem(COMPOSER_FOLD_KEY, folded ? "1" : "0"); } catch (_) {}
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
  // The grip as the fold's handle (its title, marks, aria-expanded) and Stop turn
  // while folded. The start page's grip only resizes: no role, no fold state.
  function drawFoldControls() {
    const folded = isComposerFolded();
    infoCancelBtn.style.display = folded && turnRunning() ? "" : "none";
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
  doc.addEventListener("keydown", (e) => {
    if (!isComposerFolded()) return;
    if (!opensOnKey(e, { active: doc.activeElement, allView: allViewOpen(), lightbox: lightboxOpen() })) return;
    setComposerFolded(false);
    promptEl.focus();
  });
  // A file dropped on the folded info bar: open (for the visit), then add it.
  infoBarEl.addEventListener("dragover", (e) => {
    if (!isComposerFolded() || ![...(e.dataTransfer?.types || [])].includes("Files")) return;
    e.preventDefault();
  });
  infoBarEl.addEventListener("drop", (e) => {
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
