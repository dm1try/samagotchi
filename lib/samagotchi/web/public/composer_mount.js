import { render } from "./vendor/lit-html.js";
import { admitImages, chipName, chipsTemplate, imageFiles } from "./images.js";
import { promptHeight } from "./composer_size.js";
import { GRIP_KEY, createComposerGrip } from "./composer_grip.js";
import { createPromptHistory } from "./prompt_history.js";
import { readStored } from "./storage.js";

// The composer, mounted on a page's markup (composer.css): the message box,
// its height (it grows with the text; the grip sets a floor), its image
// chips (paste, drop and the image button), the grip and fold
// (composer_grip.js), ↑/↓ over the prompt history (prompt_history.js) and
// its keys. What a page sends, and how, stays the page's: the owner's page
// (app.js) hands the result to send_turn.js as its composer.
//
// +els+: {composer (the card's box, where files drop), prompt (the text box),
// button (Send/Start), chips (the chips' row), attachBtn, attachInput (the
// hidden file picker), grip}.
// Hooks: +minPx()+ the empty box's height; +toast(text)+ why images stayed
// out; +onWrite()+ the composer wrote the text itself (a recalled entry);
// +loadHistory()+ a promise of the ↑/↓ entries (oldest first; none: no
// history); +send({queue})+ Enter (+queue+: with Alt/Option) or the button;
// +keyFirst(e)+ a key the page takes before the history's (true: taken);
// +escape()+ Esc, true when it let go of something. +imagesOff+: why this
// page takes no images (the participant page, until its upload path): a
// paste, drop or pick of one toasts it and adds no chip; null takes them.
// +fold+: createComposerGrip's page hooks (session, waiting, allViewOpen,
// lightboxOpen, infoBarEl, typeAnywhere).
// @return {el, button, chips(), setChips(list), addImageFiles(files), fit(),
// hasDraft(), refreshHistory(), and the grip's isComposerFolded,
// openForVisit, focusPrompt, drawFoldControls, newVisit, decideVisit}
export function mountComposer({
  els, minPx, toast, onWrite = () => {}, loadHistory = null, send, keyFirst = () => false, escape = () => false,
  imagesOff = null, fold, win = globalThis.window, createObjectURL = (f) => URL.createObjectURL(f),
  revokeObjectURL = (src) => URL.revokeObjectURL(src),
}) {
  const { composer: composerEl, prompt: promptEl, button, chips: chipsEl, attachBtn, attachInput, grip } = els;

  // ── Images: paste or drop into the composer, chips until sent ─────────────
  let chips = [];
  // Bound once the grip is made (below); a chip drawn before that has no fold to redraw.
  let drawFoldControls = () => {};

  function renderChips() {
    render(chipsTemplate(chips), chipsEl);
    chipsEl.hidden = !chips.length;
    drawFoldControls();
  }

  // A chip that goes frees its preview; one kept in +list+ keeps it.
  function setChips(list) {
    for (const c of chips) if (c.file && c.src && !list.includes(c)) revokeObjectURL(c.src);
    chips = list;
    renderChips();
  }

  // A paste's, a drop's or the image button's files: the images the message
  // may still take become chips (images.js admitImages); a toast says why the
  // rest stayed out. Whether any went in.
  function addImageFiles(files) {
    if (imagesOff) {
      if (files.length) toast(imagesOff);
      return false;
    }
    const { take, refused } = admitImages(files, chips.length);
    if (refused) toast(refused);
    if (!take.length) return false;
    for (const file of take) chips.push({ file, name: chipName(file, chips.length), src: createObjectURL(file) });
    renderChips();
    focusPrompt();
    return true;
  }

  chipsEl.addEventListener("click", (e) => {
    const btn = e.target.closest(".chip-remove");
    if (!btn) return;
    const [chip] = chips.splice(Number(btn.dataset.index), 1);
    if (chip?.file && chip.src) revokeObjectURL(chip.src);
    renderChips();
  });
  // The image button: the file picker's images join the chips. Its value is
  // cleared after each pick, so the same file can be picked again.
  attachBtn.addEventListener("click", () => attachInput.click());
  attachInput.addEventListener("change", () => {
    addImageFiles([...attachInput.files]);
    attachInput.value = "";
  });

  // ── Height: grows with the text; the top-edge grip sets a floor ───────────
  // The floor is saved as it was set; fit holds it to half the window it is
  // drawn in (composer_size.js), so a floor saved in a bigger window fits this one
  // and comes back when the window is big again.
  let floor = Number(readStored(GRIP_KEY)) || null;

  function fit() {
    const borders = promptEl.offsetHeight - promptEl.clientHeight;
    promptEl.style.height = "0px";
    const { height, scrolls } = promptHeight({ contentPx: promptEl.scrollHeight + borders, floorPx: floor, viewportPx: win.innerHeight, minPx: minPx() });
    promptEl.style.height = `${height}px`;
    promptEl.style.overflowY = scrolls ? "auto" : "hidden";
  }

  promptEl.addEventListener("input", fit);
  win.addEventListener("resize", fit);
  fit();

  promptEl.addEventListener("paste", (e) => {
    const files = imageFiles(e.clipboardData);
    // Text pasted along with an image still lands in the textarea.
    if (addImageFiles(files) && !e.clipboardData.getData("text/plain")) e.preventDefault();
  });
  composerEl.addEventListener("dragover", (e) => {
    if (![...(e.dataTransfer?.types || [])].includes("Files")) return;
    e.preventDefault();
    composerEl.classList.add("dropping");
  });
  composerEl.addEventListener("dragleave", () => composerEl.classList.remove("dropping"));
  composerEl.addEventListener("drop", (e) => {
    composerEl.classList.remove("dropping");
    const files = imageFiles(e.dataTransfer);
    if (!files.length) return;
    e.preventDefault();
    addImageFiles(files);
  });

  const hasDraft = () => !!(promptEl.value.trim() || chips.length);

  // ── The grip and fold (composer_grip.js) ──────────────────────────────────
  const composerGrip = createComposerGrip({
    ...fold,
    composeGrip: grip,
    promptEl,
    fitPrompt: fit,
    promptMinPx: minPx,
    floor: () => floor,
    setFloor: (px) => { floor = px; },
    draft: hasDraft,
    imageFiles,
    addImageFiles,
    win,
  });
  const { focusPrompt } = composerGrip;
  ({ drawFoldControls } = composerGrip);

  // ── ↑/↓: the prompt history (prompt_history.js) ───────────────────────────
  // From a copy fetched on focus and after each send (keydown can't wait for one).
  const promptHistory = createPromptHistory();
  function refreshHistory() {
    if (!loadHistory) return;
    loadHistory().then((entries) => promptHistory.setEntries(entries), () => {});
  }
  promptEl.addEventListener("focus", refreshHistory);
  function historyKey(e) {
    if (e.isComposing || e.shiftKey || e.altKey || e.ctrlKey || e.metaKey) return false;
    const step = e.key === "ArrowUp" ? promptHistory.up : e.key === "ArrowDown" ? promptHistory.down : null;
    const recalled = step?.({ value: promptEl.value, start: promptEl.selectionStart, end: promptEl.selectionEnd });
    if (!recalled) return false;
    e.preventDefault();
    promptEl.value = recalled.value;
    onWrite();
    promptEl.setSelectionRange(recalled.caret, recalled.caret);
    fit();
    return true;
  }

  promptEl.addEventListener("keydown", (e) => {
    if (keyFirst(e)) return;
    if (historyKey(e)) return;
    if (e.key === "Escape" && escape()) {
      e.preventDefault();
      return;
    }
    // An IME's Enter picks the composition, it doesn't send.
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      send({ queue: e.altKey });
    }
  });
  button.addEventListener("click", () => send({ queue: false }));

  return {
    el: promptEl,
    button,
    chips: () => chips,
    setChips,
    addImageFiles,
    fit,
    hasDraft,
    refreshHistory,
    isComposerFolded: composerGrip.isComposerFolded,
    openForVisit: composerGrip.openForVisit,
    focusPrompt,
    drawFoldControls: composerGrip.drawFoldControls,
    newVisit: composerGrip.newVisit,
    decideVisit: composerGrip.decideVisit,
  };
}
