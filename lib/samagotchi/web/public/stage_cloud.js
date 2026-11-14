// The stage's cloud (stage_view.js): the turn block's steps opened above
// the chip, newest first while the turn runs. The chip's toggle and its
// ticks, the headline's peek at the live step's reasoning, and a ref's "show
// in turn" (refs.js ref:reveal) open it. Its own module: new exports go in
// new modules (web-frontend.md).

// +stage+, +cloud+, +cloudBody+, +chip+, +headline+: stage_dom.js's nodes;
// +view+: the turn block (turn_block.js); +opener+: the turn opened in the
// history (stage_opened.js); +frame+(): the stage's frame (stage_frame.js);
// +isOpened+(): the turn is opened in the history; +isCollapsed+(),
// +setCollapsed+(on), +reveal+(): the stage's fold (stage_asking.js);
// +isHolding+(): the stage holds a turn; +isFolding+(), +finishFold+(): a
// turn sliding away (stage_view.js handOff).
export function createStageCloud({
  stage, cloud, cloudBody, chip, headline, view, opener, frame, isOpened, isCollapsed, setCollapsed, reveal,
  isHolding, isFolding, finishFold,
}) {
  let open = false;

  function setCloud(value) {
    open = value;
    cloudBody.hidden = !value || cloud.hidden;
    // Closed by hand: its room isn't held (the stage shrinks back to what
    // shows).
    if (!value) frame().forgetContent();
    cloud.classList.toggle("open", value);
    stage.classList.toggle("cloud-open", value);
    chip.setAttribute("aria-expanded", String(value));
    frame().fitCap();
    // The steps open right above the chip: in sight (the answer and the
    // cards above them scroll up), once the stage has grown for them.
    if (value) frame().afterGrowth(() => frame().reveal(cloudBody));
  }

  // Open the cloud at step +i+ (a hand toggle, as a click on its row), its
  // reasoning too with +thinking+.
  function openStep(i, { thinking = false } = {}) {
    const step = view.step(i);
    if (!step) return;
    // An opened turn's step is in the history: shown there.
    if (isOpened()) {
      if (!step.el.open) step.summary.click();
      opener.reveal(step.el);
      return;
    }
    if (isCollapsed()) setCollapsed(false);
    setCloud(true);
    if (!step.el.open) step.summary.click();
    const wrap = step.thinkingWrap;
    if (thinking && wrap && !wrap.open) wrap.querySelector(":scope > summary")?.click();
    requestAnimationFrame(() => step.el.scrollIntoView({ block: "nearest" }));
  }

  function peek() {
    const { turn } = view.current();
    if (turn?.gens.length) openStep(turn.gens.length - 1, { thinking: true });
  }

  chip.addEventListener("click", (e) => {
    const tick = e.target.closest(".ts-tick");
    if (tick) openStep(Number(tick.dataset.step));
    else setCloud(!open);
  });
  headline.addEventListener("click", peek);
  // A ref's "show in turn" (refs.js) names a row in the cloud: open the
  // stage and the cloud to it, as a hand toggle would.
  // A collapsed stage opens for this turn only: the kept choice
  // (chi_stage_collapsed) is left alone and comes back at the release.
  // The row's scroll into view (refs.js) waits for the stage's growth.
  // A row of a turn sliding away is no longer the stage's: it goes into the
  // history first (finishFold), and refs.js finds it there.
  stage.addEventListener("ref:reveal", (e) => {
    if (!cloudBody.contains(e.target)) return;
    if (isFolding()) return finishFold();
    if (!isHolding()) return;
    if (isCollapsed()) reveal();
    setCloud(true);
    if (e.detail) e.detail.until = new Promise((resolve) => frame().afterGrowth(resolve));
  });
  headline.addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.key === " ") {
      e.preventDefault();
      peek();
    }
  });

  // The turn left the stage: the cloud closes.
  function reset() {
    setCloud(false);
  }

  return { setCloud, isOpen: () => open, reset };
}
