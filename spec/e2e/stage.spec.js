// The stage on its own: the running turn pinned above the composer with
// fixed live slots, cards in it, and the hand-off into the history.
import fs from "node:fs";
import path from "node:path";
import { test, expect } from "./support/fixtures.js";
import { barItemOnRow, clickBarItem, expectNoHorizontalOverflow } from "./support/layout.js";
import { expectSameAfterReload } from "./support/history_shape.js";
import { frames, momentAt, pageNow, shiftSources, shiftSum, snaps, stageMarks, startSampling, startSnaps, stopSampling, watchFrames, watchShifts, watchStage } from "./support/shifts.js";

// The stage's drift check on: a "stage: waiting …" warning fails the test.
test.use({ stageCheck: true });

const stageEl = (page) => page.locator("#turnStage");
// A shift's source in the top bar, or the session panel it pushes down.
const TOP_BAR = /#topBar|#sessionTitle|#stripStatus|#stripGrip|#notifyBtn|section#center$/;
const handedOff = (page, turns) => expect(page.locator("#history .turn-timing:not(.live)")).toHaveCount(turns);
// The history at rest: its bottom reserve's ease (#center's padding
// transition), its eased follow (#history[data-following]) and the handed-off
// pieces' arrival (.ts-arrive, gone at animationend) are over. With
// +stage+, the stage's own rise too.
const settled = (page, { stage = false } = {}) => page.waitForFunction((stage) =>
  document.querySelector("#center").getAnimations().length === 0 &&
  !document.querySelector("#history[data-following], #history .ts-arrive") &&
  (!stage || document.querySelector("#turnStage").getAnimations().length === 0), stage);

// The stage's height once the frame is settled. fitFrame (stage_frame.js)
// frees the held height in the frame after a change: a fold marks the stage
// collapsed at once, but the box still carries the frame it was holding for a
// frame or two — more on a busy machine — so read only once the height has
// held across two frames.
async function settledHeight(page) {
  await page.waitForFunction(() => {
    const stage = document.querySelector("#turnStage");
    const first = stage.offsetHeight;
    return new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() => done(stage.offsetHeight === first))));
  });
  return stageEl(page).evaluate((el) => el.offsetHeight);
}

async function send(page, prompt) {
  await page.locator("#prompt").fill(prompt);
  await page.locator("#actionBtn").click();
}

test("the stage keeps one height while a multi-step turn runs; nothing moves the history; a scrolled-up reader stays at the hand-off", async ({ page, script }) => {
  test.setTimeout(60_000);
  script("stage");
  await send(page, "First round");
  // The stage rises under the click's pointer; under load that can come after
  // an earlier move away, and a pointer left over it defers the hand-off.
  await expect(stageEl(page)).toBeVisible();
  await page.mouse.move(0, 0);
  await handedOff(page, 1);
  await expect(stageEl(page)).toBeHidden(); // the first turn's fold is over
  // A reader scrolled up into the first turn's long answer.
  await watchShifts(page);
  await watchStage(page);
  await startSnaps(page);
  const sendAt = await pageNow(page);
  await startSampling(page); // from the send: the running window is the turn's, not a delay's
  await send(page, "Second round");
  await expect(stageEl(page)).toBeVisible();
  await page.mouse.move(0, 0);
  await settled(page, { stage: true }); // the rise and the history's follow are over
  const scrolledAt = await pageNow(page);
  const scrollTopSet = await page.evaluate(() => { document.querySelector("#history").scrollTop = 120; return performance.now(); });
  await handedOff(page, 2);
  await settled(page); // the fold and the arrival are over
  const samples = await stopSampling(page);
  const running = samples.filter((s) => !s.hidden && !s.ended);
  expect(running.length).toBeGreaterThan(10);
  // One height before check-in's card. The card docks: the turn goes into
  // the history and the stage shows the status row and the card alone (the
  // asking form's one allowed shrink), then holds its height (grow-only).
  const cardIndex = running.findIndex((s) => s.extras > 0);
  const noCard = running.slice(0, cardIndex);
  expect(noCard.length).toBeGreaterThan(5);
  expect([...new Set(noCard.map((s) => s.slots))]).toHaveLength(1);
  expect([...new Set(noCard.map((s) => s.h))]).toHaveLength(1);
  const docked = running.slice(cardIndex);
  expect(docked.length).toBeGreaterThan(3);
  expect([...new Set(docked.map((s) => s.slots))]).toHaveLength(1);
  // (The card's own growth can take a few samples under load.)
  expect(docked.slice(1).every((s, i) => s.h >= docked[i].h)).toBe(true);
  // The long answer streams with the card still open: in the box under the
  // card, the row saying "writing" (the dot blinks on: the turn isn't blocked).
  expect(docked.some((s) => s.asksText > 0 && s.label === "writing" && s.phase === "waiting for you")).toBe(true);
  expect([...new Set(samples.filter((s) => s.t >= scrollTopSet).map((s) => s.top))]).toEqual([120]);
  // The moments, by the stage's own marks (page clock).
  const marks = await stageMarks(page);
  const shownAt = momentAt(marks, (m) => !m.hidden, sendAt);
  // The turn start: the stage rises over the composer, nothing moves (the
  // click's own shifts too).
  expect(await shiftSum(page, { from: sendAt, to: shownAt + 450, withInput: true })).toBeLessThan(0.01);
  // The history behind it follows a reader at its end with a short ease
  // (the stage's room at its foot), never a jump.
  expect(await snaps(page, { from: sendAt, to: scrolledAt })).toEqual([]);
  // The turn end: the long answer comes in above the chip, which stays put
  // (the stage's footer).
  const endAt = momentAt(marks, (m) => /\bended\b/.test(m.cls), shownAt);
  const leaveAt = momentAt(marks, (m) => /\bleaving\b/.test(m.cls), endAt);
  expect((await shiftSources(page, { from: endAt - 50, to: leaveAt })).filter((n) => /ts-(cloud|foot|chip)/.test(n))).toEqual([]);
  // Change is deliberate: check-in's card docks once (bounded, no snap) and
  // the long answer grows the stage once, with a short ease.
  const checkInAt = momentAt(marks, (m) => m.extras > 0, shownAt);
  expect(await shiftSum(page, { from: checkInAt, to: checkInAt + 600, withInput: true })).toBeLessThan(0.15);
  // (The docking shrink lowers the stage's top edge once, its status row
  // with it: the turn's pieces went into the history.)
  expect(await snaps(page, { from: checkInAt, to: checkInAt + 600, keys: ["card", "chip", "composer", "last"] })).toEqual([]);
  expect(await shiftSum(page, { from: endAt, to: leaveAt, withInput: true })).toBeLessThan(0.15);
  expect(await snaps(page, { from: endAt, to: leaveAt })).toEqual([]);
  // The hand-off: the stage slides away under the composer, then the turn
  // arrives in the history; nothing shifts or snaps, and it is hidden after.
  const hiddenAt = momentAt(marks, (m) => m.hidden, leaveAt);
  expect(hiddenAt - leaveAt).toBeGreaterThan(300);
  expect(await shiftSum(page, { from: leaveAt, to: hiddenAt + 600 })).toBeLessThan(0.01);
  expect(await snaps(page, { from: leaveAt, to: hiddenAt + 600 })).toEqual([]);
  // A handed-off turn is its outline, closed: opened, its narrated steps
  // show, each tool-only (or thinking-only) step behind a fold that shows it;
  // a reload draws the same.
  const outline = async () => {
    const blocks = page.locator("#history .turn-work");
    await expect(blocks).toHaveCount(2);
    for (const block of await blocks.all()) {
      await expect(block).toHaveClass(/outline/);
      await expect(block).toHaveJSProperty("open", false);
      await block.evaluate((el) => { el.open = true; });
      await expect(block.locator(":scope > .outline-fold")).toHaveText(["1 step", "1 step"]);
      await expect(block.locator(":scope > .gen:visible")).toHaveCount(4);
    }
  };
  await outline();
  // The outline coming into the history moves nothing there.
  expect(await shiftSum(page, { where: "history" })).toBeLessThan(0.01);
  await page.locator("#history .turn-work").last().locator(".outline-fold").first().click();
  await expect(page.locator("#history .turn-work").last().locator(":scope > .gen:visible")).toHaveCount(5);
  // The long answers have a fold row each (answer_fold.js); the first one
  // folded by hand stays folded across the reload, its row in its place.
  const answers = page.locator("#history .bubble.output");
  const rows = page.locator("#history .answer-fold");
  await expect(rows).toHaveCount(2);
  await expect(rows.first()).toHaveAttribute("aria-expanded", "true");
  await rows.first().click();
  await expect(answers.first()).toBeHidden();
  await expect(rows.first()).toHaveAttribute("aria-expanded", "false");
  await expect(rows.first()).toContainText(/\u00a0· \d+ lines$/);
  const folded = await rows.first().textContent();
  await page.reload();
  await outline();
  // Nor does a reload drawing the old turns' outlines open.
  expect(await shiftSum(page, { where: "history" })).toBeLessThan(0.01);
  await expect(rows).toHaveCount(2);
  await expect(answers.first()).toBeHidden();
  await expect(rows.first()).toHaveText(folded);
  await expect(answers.last()).toBeVisible();
  // Unfolded from its row: the answer is back.
  await rows.first().click();
  await expect(answers.first()).toBeVisible();
});

// The page's clock is Playwright's: it runs as a real one until the stage
// holds the ended turn, then stands still and moves only by runFor, so
// the dwell and the 1.5 s after leaving are the page's time, not the
// runner's (the rule's edges: stage_model.test.js handOffDue).
test("the hand-off waits while the pointer is over the stage, runs about 1.5 s after it leaves; an own send hands off at once", async ({ page, script }) => {
  await page.clock.install();
  await page.reload();
  script("turn");
  await send(page, "Check the shell and the README");
  await stageEl(page).hover();
  await expect(stageEl(page)).toHaveAttribute("data-phase", "answered");
  // The in-use watch ticks over the ended turn: then the clock stops.
  await expect(stageEl(page)).toHaveClass(/\bended\b.*\bin-use\b|\bin-use\b.*\bended\b/);
  // A margin, not +1: the clock still runs until pauseAt lands, and on a
  // loaded runner +1 ms is already past ("Cannot fast-forward to the
  // past"). The pointer holds the turn meanwhile, so the margin is free.
  await page.clock.pauseAt(await page.evaluate(() => Date.now() + 500));
  await page.clock.runFor(5000);
  await expect(stageEl(page)).toBeVisible();
  await expect(stageEl(page).locator(".ts-defer")).toBeVisible();
  await handedOff(page, 0);
  // Left: still held 1.3 s on, the hand-off (its slide, then the history)
  // has begun by 1.8 s.
  await page.mouse.move(0, 0);
  await page.clock.runFor(1300);
  await expect(stageEl(page)).not.toHaveClass(/\bleaving\b/);
  await handedOff(page, 0);
  await page.clock.runFor(500);
  await expect(stageEl(page)).toHaveClass(/\bleaving\b/);
  await page.clock.resume();
  await handedOff(page, 1);
  await expect(stageEl(page)).toBeHidden();

  // Answered and hovered again: sending moves it at once.
  script("plain");
  await send(page, "Say pong");
  await stageEl(page).hover();
  await expect(stageEl(page)).toHaveAttribute("data-phase", "answered");
  await page.locator("#prompt").fill("Say pong again");
  // In the send itself, before any event: the finished turn has left.
  const atSend = await page.evaluate(() => {
    document.querySelector("#actionBtn").click();
    return { hidden: document.querySelector("#turnStage").hidden, turns: document.querySelectorAll("#history .turn-timing:not(.live)").length };
  });
  expect(atSend).toEqual({ hidden: true, turns: 2 });
  await page.mouse.move(0, 0);
  await handedOff(page, 3);
});

// A blocking card waits: no infinite animation in the stage (finite fades may
// run). Not vacuously: taken off for one synchronous look (nothing paints),
// the waiting state is all that keeps the running tick and the dot still.
const stillWhileWaiting = (page) => stageEl(page).evaluate((el) => {
  const infinite = () => el.getAnimations({ subtree: true }).filter((a) => a.effect.getComputedTiming().iterations === Infinity);
  const still = infinite().length;
  // The asking form hides the chip (its ticks; an opened turn has none):
  // shown for the probe too.
  const form = el.classList.contains("asking-form");
  const foot = el.querySelector(".ts-foot");
  const footHidden = foot.hidden;
  el.classList.remove("waiting", "asking-form");
  foot.hidden = false;
  const moving = infinite().map((a) => a.effect.target).map((t) => (t.matches(".ts-tick.running") ? "tick" : t.className));
  el.classList.add("waiting");
  if (form) el.classList.add("asking-form");
  foot.hidden = footHidden;
  return { still, tick: moving.includes("tick"), dot: moving.includes("ts-mark") };
});

// A phone (390×700): the stage's cap is low and the top bar wraps its title.
test("a question card sits in the stage, its reason in the history (also after a reload mid-turn), and the answer comes after it", async ({ page, script }) => {
  await page.setViewportSize({ width: 390, height: 700 });
  script("question");
  // Every frame: whether a card waits and whether its reason shows in the
  // history. They land in one frame (no frame with one and not the other).
  await watchFrames(page);
  await watchShifts(page);
  await watchStage(page);
  await send(page, "Read a file of my choice");
  // The click's pointer stays where the start page's Send was: the reply that asks
  // slides under it, and a hover adds the ref's hint to the title read below.
  await page.mouse.move(0, 0);
  const card = stageEl(page).locator(".ts-extras .bubble.question");
  await expect(card.locator(".question-text")).toHaveText("Which file should I read?");
  await expect(stageEl(page)).toHaveAttribute("data-phase", "waiting for you");
  await expect(page.locator("#history .bubble.question")).toHaveCount(0);
  // The whole reply that asked is a bubble in the conversation (the turn
  // opened in the history: its prompt and steps went there too); the stage
  // shows its asking form, the card alone.
  const asking = page.locator("#history .bubble.said");
  await expect(asking).toContainText("I can start from either file: README.md describes the project");
  await expect(asking).toHaveClass(/pending/);
  await expect(asking.locator(".said-label")).toHaveText("chi · step 1asking you");
  await expect(page.locator("#history > .bubble.user")).toHaveText(/Read a file of my choice/);
  await expect(page.locator("#history > .turn-work")).toHaveCount(1);
  await expect(stageEl(page)).toHaveClass(/asking-form/);
  await expect(stageEl(page).locator(".ts-live")).toBeHidden();
  await expect(stageEl(page).locator(".ts-foot")).toBeHidden();
  expect((await frames(page)).filter((f) => f.waits !== f.said)).toEqual([]);
  // Movement means chi is working: the dot blinks until the card waits, and
  // from then on the stage is still (every frame). The ask's own tick lands in
  // the card's frame, so it is seen moving only through stillWhileWaiting.
  const seen = await frames(page);
  expect(seen.some((f) => !f.blocked && f.infinite > 0)).toBe(true);
  expect(seen.filter((f) => f.blocked && f.infinite > 0)).toEqual([]);
  expect(await stillWhileWaiting(page)).toEqual({ still: 0, tick: true, dot: true });
  // With web.markdown on, it reads as markdown: its heading, and its link opens a new tab.
  await expect(asking.locator("h2")).toHaveText("Two files");
  await expect(asking.locator('a[target="_blank"]')).toHaveAttribute("href", "https://example.com/files");
  // A plugin's ref on the reply that asks (e2e-answer-refs, :question_asked): paired in the bubble.
  const askRef = asking.locator('[data-ref-kind="issue"]');
  await expect(askRef).toHaveText("JIRA-7");
  await expect(askRef).toHaveAttribute("title", "JIRA-7 Login fails");
  await expectNoHorizontalOverflow(page);
  // Every visible text field is 16px or more on a phone: under 16px iOS Safari
  // zooms the page on focus (and a Home Screen app never zooms back).
  const small = await page.evaluate(() => {
    const skip = new Set(["hidden", "file", "checkbox", "radio", "range", "button", "submit"]);
    return [...document.querySelectorAll("input, textarea, select")]
      .filter((el) => !skip.has(el.type) && el.checkVisibility())
      .filter((el) => parseFloat(getComputedStyle(el).fontSize) < 16)
      .map((el) => `${el.id || el.className || el.tagName} ${getComputedStyle(el).fontSize}`);
  });
  expect(small).toEqual([]);
  // The card's arrival grows the stage, briefly; the top bar stays (the
  // hidden strip's pill gains "· 1 waiting" and must not wrap to a row).
  const marks = await stageMarks(page);
  const shownAt = momentAt(marks, (m) => !m.hidden);
  const waitingAt = momentAt(marks, (m) => /\bwaiting\b/.test(m.cls), shownAt);
  expect(await shiftSum(page, { from: waitingAt, to: waitingAt + 600, withInput: true })).toBeLessThan(0.25);
  expect((await shiftSources(page, { from: shownAt + 400 })).filter((n) => TOP_BAR.test(n))).toEqual([]);
  // A phone's delivery line has no row of its own: running, it lies over the
  // session bar's first row, in the status chip's place, left of ⚙, only
  // while it matters (the text field focused or holding text, a choice
  // armed); else the bar's status and ctx show. The composer's height never
  // changes (and stays at the turn's end, below).
  const line = page.locator("#deliveryLine");
  const prompt = page.locator("#prompt");
  const status = page.locator("#infoBar .meta .status");
  const ctx = page.locator("#infoBar .meta .ctx");
  const dockHeight = () => page.locator("#dock").evaluate((el) => el.offsetHeight);
  const dockAt = await dockHeight();
  const lineShown = async (shown) => {
    if (shown) await expect(line).toBeVisible();
    else await expect(line).toBeHidden();
    await expect(status).toHaveCSS("visibility", shown ? "hidden" : "visible");
    if (await ctx.count()) await expect(ctx).toHaveCSS("visibility", shown ? "hidden" : "visible");
    expect(await dockHeight()).toBe(dockAt);
  };
  // The card waits, the text field blurred and empty: the bar's own.
  await prompt.evaluate((el) => el.blur());
  await lineShown(false);
  // Focused (the keyboard up): the line, in its place.
  await prompt.focus();
  await lineShown(true);
  await expect(line.locator(".delivery-where .short")).toHaveText("↳ after the card's answer");
  const [lineBox, barBox, gearBox] = await Promise.all([line.boundingBox(), page.locator("#infoBar").boundingBox(),
    page.locator("#infoBar .meta .settings-chip").boundingBox()]);
  expect(Math.round(lineBox.y)).toBe(Math.round(barBox.y));
  expect(lineBox.x + lineBox.width).toBeLessThanOrEqual(gearBox.x);
  // A draft keeps it after the keyboard goes; emptied, it goes.
  await prompt.pressSequentially("x");
  await prompt.evaluate((el) => el.blur());
  await lineShown(true);
  await prompt.fill("");
  await prompt.evaluate((el) => el.blur());
  await lineShown(false);
  // A choice armed (a tap on queue with nothing typed) keeps it too; a
  // second tap disarms it, and the line goes.
  await prompt.focus();
  const queue = line.locator(".delivery-link.queue");
  await queue.click();
  await expect(queue).toHaveAttribute("aria-pressed", "true");
  await prompt.evaluate((el) => el.blur());
  await lineShown(true);
  await queue.click();
  await expect(queue).toHaveAttribute("aria-pressed", "false");
  await lineShown(false);
  // A reload mid-turn draws the stage again with its card.
  await page.reload();
  await expect(card).toBeVisible();
  await expect(stageEl(page)).toHaveAttribute("data-phase", "waiting for you");
  await expect(asking).toContainText("I can start from either file: README.md describes the project");
  await expect(askRef).toHaveText("JIRA-7");
  await page.waitForFunction(() => document.querySelector("#turnStage").getAnimations().length === 0); // its rise is over
  expect(await stillWhileWaiting(page)).toEqual({ still: 0, tick: true, dot: true });
  // A phone's keyboard (the window 420 px tall): the cap drops, the held
  // stage clamps to it at once and the waiting card stays in sight; when
  // the keyboard goes the stage grows back only to what its content needs:
  // its cap (which follows the dock: its info bar fills and may wrap after
  // the reload), or less only when its whole content fits. The card and the asking text are about the cap's height at 390
  // (one px under it since the phone's panel runs edge to edge); the held
  // height before the keyboard can be the cap (grow-only), so it isn't the
  // measure.
  const inSight = async () => {
    const [c, v] = [await card.boundingBox(), await stageEl(page).locator(".ts-scroll").boundingBox()];
    return c.y + Math.min(c.height, 40) <= v.y + v.height && c.y + c.height > v.y;
  };
  const before = await stageEl(page).evaluate((el) => el.offsetHeight);
  await page.setViewportSize({ width: 390, height: 420 });
  // setViewportSize returns with the new innerHeight but before the page's
  // next frame, whose resize steps run fitCap: read the height in that
  // frame's animation callbacks (after the resize, before its paint), not
  // at once. (The card can already be in sight at the old height.)
  const clamped = await stageEl(page).evaluate((el) => new Promise((done) => requestAnimationFrame(() => done(el.offsetHeight))));
  expect(clamped).toBeLessThan(before);
  await expect.poll(inSight).toBe(true);
  await page.setViewportSize({ width: 390, height: 700 });
  // Read in a frame's animation callbacks (that frame's resize steps ran
  // fitCap: before them the clamped height still equals the old cap), once
  // the growth's ease is over.
  const filled = () => stageEl(page).evaluate((el) => new Promise((done) => requestAnimationFrame(() => {
    // What the content needs, as stage_frame.js contentHeight counts it: its last shown slot's end and the view's
    // bottom padding (not the hold, the spacer a held height keeps).
    const view = el.querySelector(".ts-scroll");
    const shown = [...view.children].filter((c) => !c.matches(".ts-hold") && !c.hidden && c.getClientRects().length);
    const end = shown.length ? Math.max(...shown.map((c) => c.offsetTop + c.offsetHeight)) : 0;
    const needs = el.offsetHeight - view.clientHeight + end + parseFloat(getComputedStyle(view).paddingBottom);
    done(el.getAnimations().length === 0 && el.offsetHeight === Math.min(needs, parseFloat(el.style.getPropertyValue("--stage-max"))));
  })));
  await expect.poll(filled).toBe(true);
  await expect.poll(inSight).toBe(true);
  // One fold for the waiting question: the status row's ▾ folds the box to
  // its row, which says the question; the history gets the room (its bottom
  // reserve follows the stage) and nothing is saved. A tap on the row brings
  // the card back, still answerable.
  const reserve = () => page.locator("#history").evaluate((el) => parseFloat(getComputedStyle(el).paddingBottom));
  const openReserve = await reserve();
  await stageEl(page).locator(".ts-fold").click();
  await expect(stageEl(page)).toHaveClass(/collapsed/);
  await expect(stageEl(page).locator(".ts-mini.ts-mini-question")).toHaveText("Which file should I read?");
  await expect(card).toBeHidden();
  await expect.poll(reserve).toBeLessThan(openReserve);
  expect(await page.evaluate(() => localStorage.getItem("chi_stage_collapsed"))).toBeNull();
  await stageEl(page).locator(".ts-mini").click();
  await expect(stageEl(page)).not.toHaveClass(/collapsed/);
  await expect(card.locator(".question-submit")).toBeVisible();
  await expect.poll(filled).toBe(true);
  await expect.poll(inSight).toBe(true);
  // From the answer until the next step nothing moves on its own: the
  // card's collapse and the slots' swap come with the click. The next step
  // lets the held height go, once. (The shifts' recorder came back with the
  // reload.)
  await watchFrames(page);
  await watchStage(page);
  await startSnaps(page);
  const submitAt = await pageNow(page);
  const heldHeight = await stageEl(page).evaluate((el) => el.offsetHeight);
  const runningDock = await page.locator("#dock").evaluate((el) => el.offsetHeight);
  await card.locator(".question-option", { hasText: "README.md" }).click();
  await card.locator(".question-submit").click();
  await expect(stageEl(page).locator(".ts-answer .bubble.output")).toHaveText("Read the file you picked. Done.");
  // The answered card went under its reason in the history, which no longer
  // asks; the stage is back to its working form.
  await expect(page.locator("#history .bubble.said:not(.pending) + .bubble.question.answered")).toHaveCount(1);
  await expect(stageEl(page)).not.toHaveClass(/asking-form/);
  const nextStepAt = momentAt(await stageMarks(page), (m) => !/\bheld-wait\b/.test(m.cls), submitAt);
  expect(await shiftSum(page, { from: submitAt, to: nextStepAt - 1, withInput: true })).toBeLessThan(0.01);
  // The next step let the held height go: the stage is no taller than it held.
  await expect.poll(() => stageEl(page).evaluate((el) => el.offsetHeight)).toBeLessThanOrEqual(heldHeight);
  // The frames are sampled at the next frame after the answer: wait for the answered one.
  await expect.poll(async () => (await frames(page)).some((f) => f.phase === "answered")).toBe(true);
  const answeredAt = (await frames(page)).find((f) => f.phase === "answered").t;
  await page.mouse.move(0, 0);
  await handedOff(page, 1);
  await expectNoHorizontalOverflow(page);
  // The turn end with a short answer: once the answer's growth has eased (the
  // frame let go at the next step, so a short answer grows it again), the
  // stage keeps its height and nothing in it moves.
  const leaveAt = momentAt(await stageMarks(page), (m) => /\bleaving\b/.test(m.cls), answeredAt);
  expect(await shiftSum(page, { from: answeredAt + 400, to: leaveAt, withInput: true })).toBeLessThan(0.01);
  expect(await snaps(page, { from: answeredAt + 400, to: leaveAt })).toEqual([]);
  // The hand-off to a reader at the history's end: the reserve eases down
  // under the sliding stage and the history follows the turn's arrival.
  await expect(stageEl(page)).toBeHidden();
  await settled(page);
  // Idle, the phone's line is gone and the bar's status is back; the composer
  // kept its height.
  await expect(line).toBeHidden();
  await expect(page.locator("#infoBar .meta .status")).toHaveCSS("visibility", "visible");
  expect(await page.locator("#dock").evaluate((el) => el.offsetHeight)).toBe(runningDock);
  // The end fold (stage_opened.js end): the reason goes and the answered
  // card shows its two lines. This history is too short to scroll once the
  // stage has gone, so the card takes the reason's place (with room, the
  // card the reader sees stays put); nothing else moves.
  expect(await shiftSources(page, { from: leaveAt })).toEqual(["div#stage > div#history > details.bubble.question.answered"]);
  expect(await snaps(page, { from: leaveAt })).toEqual([]);
  expect((await shiftSources(page, { from: submitAt })).filter((n) => TOP_BAR.test(n))).toEqual([]);
  // Their classes without the arrival animation's (gone when it ends), and
  // without the answer's Revise row (revise_stack.js).
  const kinds = await page.locator("#history > :not(.revise-row)").evaluateAll((els) => els.map((el) =>
    [...el.classList].filter((c) => c !== "ts-arrive").slice(0, 2).join(" ")));
  expect(kinds).toEqual(["bubble user", "turn-work done", "bubble question", "bubble output", "turn-timing"]);
  // The asking step's text in the history keeps the ref (live, at the turn's end).
  await expect(page.locator('#history .gen > .gen-text [data-ref-kind="issue"]')).toHaveText("JIRA-7");
  await test.step("the turn, joined mid-way, reads the same after a reload", async () => {
    await expectSameAfterReload(page, async (p) => {
      await handedOff(p, 1);
      await expect(p.locator("#history .bubble.output > .copy-btn")).toHaveCount(1);
    });
  });
});

// A long "plan, then ask" reply: the turn opens in the history (stage_opened.js). The reply is a bubble there, on the
// conversation's column, read from its first line; the card is docked in the stage and stays put while the history
// scrolls; its link leads back to the reply. Answered, the card sits under its reason; at the hand-off the reason folds
// into the card's two lines, and the reload check (web.reload_check, switched on in the page) finds the turn as a reload
// draws it.
test("a long reply that asks: its reason in the history, the card docked while the history scrolls, the reload check agrees", async ({ page, script }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  script("question_long");
  const checks = [];
  await page.route("**/reload_check", async (route) => {
    checks.push(route.request().postDataJSON());
    await route.fulfill({ status: 204, body: "" });
  });
  await page.evaluate(() => { document.body.dataset.reloadCheck = "1"; });
  await send(page, "Plan it, then ask me");
  await page.mouse.move(0, 0);
  const card = stageEl(page).locator(".ts-extras .bubble.question");
  await expect(card.locator(".question-text")).toHaveText("Which file should I read?");
  const reason = page.locator("#history .bubble.said");
  await expect(reason.locator("h2")).toHaveText("A plan before I start");
  await expect(stageEl(page)).toHaveClass(/asking-form/);
  // On the conversation's column, as wide as the stage.
  const [r, s] = [await reason.boundingBox(), await stageEl(page).boundingBox()];
  expect(Math.round(r.x)).toBe(Math.round(s.x));
  expect(Math.round(r.width)).toBe(Math.round(s.width));
  // Read from its first line: its top at the history's top.
  const history = page.locator("#history");
  const atTop = async () => {
    const [b, h] = [await reason.boundingBox(), await history.boundingBox()];
    return b.y >= h.y - 1 && b.y < h.y + 40;
  };
  await expect.poll(atTop).toBe(true);
  await page.waitForFunction(() => !document.querySelector("#history[data-following], #history[data-reading]"));
  // The history scrolls; the card stays where it is.
  const cardAt = (await card.boundingBox()).y;
  await history.evaluate((el) => { el.scrollTop = 0; });
  await expect.poll(atTop).toBe(false);
  expect((await card.boundingBox()).y).toBe(cardAt);
  // Its link leads back to the reply.
  await card.locator(".question-reason-link").click();
  await expect.poll(atTop).toBe(true);
  // The steps open in place; the asking step doesn't repeat the reply.
  const steps = page.locator("#history > .turn-work");
  await steps.locator(":scope > summary").click();
  await expect(steps.locator(".gen").first().locator(".activity-row")).toBeVisible();
  await expect(steps.locator(".gen").first().locator(":scope > .gen-text")).toBeHidden();
  await steps.locator(":scope > summary").click();
  await card.locator(".question-reason-link").click();
  await expect.poll(atTop).toBe(true);
  await expectNoHorizontalOverflow(page);
  await card.locator(".question-option", { hasText: "README.md" }).click();
  await card.locator(".question-submit").click();
  await expect(page.locator("#history .bubble.said:not(.pending) + .bubble.question.answered")).toHaveCount(1);
  await expect(stageEl(page)).not.toHaveClass(/asking-form/);
  await expect(stageEl(page).locator(".ts-answer .bubble.output")).toHaveText("Read the file you picked. Done.");
  await page.mouse.move(0, 0);
  await handedOff(page, 1);
  // The reason folded into the answered card's two lines.
  await expect(page.locator("#history .bubble.said")).toHaveCount(0);
  await expect(page.locator("#history .bubble.question .question-said")).toContainText("A plan before I start");
  const kinds = await page.locator("#history > :not(.revise-row)").evaluateAll((els) => els.map((el) =>
    [...el.classList].filter((c) => c !== "ts-arrive").slice(0, 2).join(" ")));
  expect(kinds).toEqual(["bubble user", "turn-work done", "bubble question", "bubble output", "turn-timing"]);
  // The reload check ran on the whole turn and found no difference.
  await expect.poll(() => checks.length).toBe(1);
  expect(checks[0], JSON.stringify(checks[0])).toMatchObject({ same: true, undrawn: 0 });
  await expectSameAfterReload(page, async (p) => {
    await handedOff(p, 1);
  });
});

// The fold of the asking card is this tab's (audit r20 D5): a reload mid-turn
// draws it folded as the user left it, and the box's height comes with the
// fold (a collapsed stage is free of its frame).
test("a question folded in the stage stays folded across a reload mid-turn, at its row's height", async ({ page, script }) => {
  script("question_hold");
  await send(page, "Pick a file for me");
  const card = stageEl(page).locator(".ts-extras .bubble.question");
  await expect(card).toBeVisible();
  const openHeight = await settledHeight(page);
  await stageEl(page).locator(".ts-fold").click();
  await expect(stageEl(page)).toHaveClass(/collapsed/);
  const foldedHeight = await settledHeight(page);
  expect(foldedHeight, "the fold frees the held frame: the box is its status row only")
    .toBeLessThan(openHeight);
  await page.reload();
  await expect(stageEl(page)).toBeVisible();
  await expect(stageEl(page)).toHaveClass(/collapsed/);
  await expect(stageEl(page).locator(".ts-mini.ts-mini-question")).toHaveText("Which file should I read?");
  await expect(stageEl(page).locator(".ts-scroll")).toBeHidden();
  expect(await settledHeight(page)).toBe(foldedHeight);
  // Unfolded by hand: the reload comes back open, and nothing was written to
  // the stage's own choice.
  await stageEl(page).locator(".ts-mini").click();
  await expect(stageEl(page)).not.toHaveClass(/collapsed/);
  expect(await page.evaluate(() => localStorage.getItem("chi_stage_collapsed"))).toBeNull();
  await page.reload();
  await expect(stageEl(page)).not.toHaveClass(/collapsed/);
  await expect(card).toBeVisible();
  await stageEl(page).locator(".ts-cancel").click();
  await page.mouse.move(0, 0);
  await handedOff(page, 1);
  await expect(page.locator("#history .bubble.cancel")).toContainText("canceled");
});

// A reload after the turn's question was answered, while the turn still
// runs (the next step holds 6 s): the replay brings the question after its
// call completed (TurnAccumulator.join_events), and the page draws what
// live drew: the reason with the answered card under it in the history;
// at the end the reason folds into the card's two lines.
test("a reload after a question answered mid-turn draws the reason and its card as live did", async ({ page, script }) => {
  script("question_hold");
  await send(page, "Read a file of my choice");
  await page.mouse.move(0, 0);
  const card = stageEl(page).locator(".ts-extras .bubble.question");
  await card.locator(".question-option", { hasText: "README.md" }).click();
  await card.locator(".question-submit").click();
  await expect(stageEl(page).locator(".ts-tick")).toHaveCount(2);
  const drawn = () => page.evaluate(() => ({
    history: [...document.querySelector("#history").children].map((el) => [...el.classList].filter((c) => c !== "ts-arrive").slice(0, 3).join(" ")),
    said: document.querySelector("#history .bubble.said .said-text")?.textContent || "",
    extras: document.querySelector("#turnStage .ts-extras").children.length,
  }));
  const live = await drawn();
  expect(live.history).toEqual(["bubble user", "turn-work", "bubble said", "bubble question answered"]);
  expect(live.said).toContain("I can start from either file");
  await page.reload();
  await expect(page.locator("#history .bubble.said + .bubble.question.answered")).toHaveCount(1);
  expect(await drawn()).toEqual(live);
  await expect(stageEl(page)).not.toHaveClass(/held-wait/);
  await page.mouse.move(0, 0);
  await expect(page.locator("#history .turn-timing:not(.live)")).toHaveCount(1, { timeout: 15_000 });
  await expect(page.locator("#history .bubble.said")).toHaveCount(0);
  await expect(page.locator("#history .bubble.question .question-said")).toContainText("Two files");
});

// The fake holds 60 s before its first token: on the page's clock
// (Playwright's, moved by runFor) the stage says the turn is quiet, in the
// now row and, folded, in the status row (stage_stall.js; its edges are
// stage_stall.test.js's).
test("the stage folds to its status row, and stays folded across a reload; a turn with no token for 45 s says so", async ({ page, script }) => {
  await page.clock.install();
  await page.reload();
  script("hold");
  await send(page, "Take your time");
  await expect(stageEl(page)).toBeVisible();
  await page.clock.runFor(40000);
  await expect(stageEl(page).locator(".ts-stall")).toHaveCount(0);
  // A second at a time: the count starts at the step's generation_started,
  // which lands a moment after the stage shows.
  const stallText = () => page.evaluate(() => document.querySelector("#turnStage .ts-now .ts-stall .long")?.textContent || "");
  await expect.poll(async () => { await page.clock.runFor(1000); return stallText(); }).toMatch(/^thinking quietly 0:4[5-9] · no tokens yet$/);
  await expect(stageEl(page)).toHaveAttribute("data-stall", "1");
  await stageEl(page).locator(".ts-fold").click();
  await expect(stageEl(page)).toHaveClass(/collapsed/);
  await expect(stageEl(page).locator(".ts-scroll")).toBeHidden();
  await expect(stageEl(page).locator(".ts-stall-head")).toBeVisible();
  await expect(stageEl(page).locator(".ts-stall-head")).toHaveText(/^thinking quietly 0:\d\d$/);
  await page.reload();
  await expect(stageEl(page)).toBeVisible();
  await expect(stageEl(page)).toHaveClass(/collapsed/);
  // Folded, the row keeps Stop turn in reach.
  await expect(stageEl(page).locator(".ts-cancel")).toBeVisible();
  await stageEl(page).locator(".ts-phase").click();
  await expect(stageEl(page)).not.toHaveClass(/collapsed/);
  expect(await page.evaluate(() => localStorage.getItem("chi_stage_collapsed"))).toBe("0");
  await stageEl(page).locator(".ts-cancel").click();
  await page.mouse.move(0, 0);
  await handedOff(page, 1);
  await expect(page.locator("#history .bubble.cancel")).toContainText("canceled");
});

// A reload that learns the session runs a turn but gets none to draw (a
// payload without current_turn): the stage shows its status row alone, and
// its Stop turn cancels the turn.
test("a running turn the reload gets no current_turn for keeps Stop turn in the stage's status row", async ({ page, script }) => {
  script("hold");
  await send(page, "Take your time");
  await expect(stageEl(page).locator(".ts-cancel")).toBeVisible();
  const id = page.url().match(/#\/s\/([^/?]+)$/)[1];
  await page.route((url) => url.pathname === `/api/sessions/${id}` && url.search === "", async (route) => {
    const res = await route.fetch();
    const body = await res.json();
    delete body.current_turn;
    // chi web's unfold of it too (the queue is empty here).
    body.replay = [];
    await route.fulfill({ response: res, json: body });
  });
  await page.reload();
  await expect(stageEl(page)).toHaveClass(/\bbare\b/);
  await expect(stageEl(page).locator(".ts-phase")).toHaveText("running");
  await stageEl(page).locator(".ts-cancel").click();
  await expect(stageEl(page)).toBeHidden();
  await expect(page.locator("#actionBtn")).toHaveText("Send");
});

test("check-in's card docks alone above the composer, its turn in the history from the card's arrival; after Nudge the turn runs on, then hands off", async ({ page, script }) => {
  script("check_in");
  await send(page, "Look through the README");
  const card = stageEl(page).locator(".ts-extras .plugin-card");
  await expect(card.locator(".card-title")).toHaveText("3 tool calls, no answer yet");
  await expect(stageEl(page)).toHaveAttribute("data-phase", "waiting for you");
  await expect(stageEl(page)).toHaveClass(/asking-form/);
  // An asking card's turn goes on: its dot keeps blinking, the waiting colour.
  await expect(stageEl(page)).not.toHaveClass(/\bwaiting\b/);
  await expect.poll(() => stageEl(page).locator(".ts-mark").evaluate((el) => el.getAnimations().filter((a) => a.effect.getComputedTiming().iterations === Infinity).length)).toBe(1);
  // The turn so far is the conversation's: the prompt and the steps block;
  // the box has no prompt line and no steps chip.
  await expect(page.locator("#history > .bubble.user")).toHaveCount(1);
  await expect(page.locator("#history > .turn-work")).toHaveCount(1);
  await expect(stageEl(page).locator(".ts-prompt .bubble.user")).toHaveCount(0);
  await expect(stageEl(page).locator(".ts-foot")).toBeHidden();
  await page.evaluate(() => {
    window.held = [];
    window.holdSampler = setInterval(() => {
      const s = document.querySelector("#turnStage");
      window.held.push({ phase: s.dataset.phase, inStage: !s.hidden && !!s.querySelector(".ts-prompt .bubble.user"),
        inHistory: document.querySelectorAll("#history .bubble.user").length });
    }, 50);
  });
  await card.locator(".card-action", { hasText: "Nudge" }).click();
  await page.mouse.move(0, 0);
  // Answered, the card is a row at the conversation's end; the box goes back to the live step.
  await expect(page.locator("#history > .plugin-card")).toContainText("Nudged the model at 3 tool calls.");
  await expect(stageEl(page)).not.toHaveAttribute("data-phase", "waiting for you");
  await expect(stageEl(page)).not.toHaveClass(/asking-form/);
  await handedOff(page, 1);
  const samples = await page.evaluate(() => { clearInterval(window.holdSampler); return window.held; });
  const running = samples.filter((s) => s.phase !== "answered");
  expect(running.length).toBeGreaterThan(20);
  expect(running.every((s) => !s.inStage && s.inHistory === 1)).toBe(true);
  // The nudge is a row of the step that answered it, in the block.
  await expect(page.locator("#history .steer-row summary")).toHaveText("check-in nudged the model");
  await expect(stageEl(page)).toBeHidden();
});

// The composer's delivery line (steer delivery P4w) over one long thinking
// step: it says where a message goes in, cut can land, and Alt+Enter queues
// the message below the running turn (also after a reload), to run as a
// turn of its own after it; a queued one's × takes it back before it runs.
// The line's variants are delivery_line.test.js's.
test("the delivery line reads the thinking step; Alt+Enter queues messages below the turn, × takes one back, the other runs as its own turn", async ({ page, script }) => {
  test.setTimeout(60_000);
  script("long_thinking");
  const line = page.locator("#deliveryLine");
  await send(page, "Plan it");
  await expect(line.locator(".delivery-where .long")).toContainText("goes in after this thinking step", { timeout: 10_000 });
  await expect(line.locator(".delivery-where .long")).toHaveText(/ · 0:\d\d · \d+ chars/);
  await expect(line.locator(".delivery-link.cut")).toBeEnabled();
  await expect(line.locator(".delivery-link.queue")).toBeEnabled();

  await page.locator("#prompt").fill("QUEUED-LATER please");
  await page.locator("#prompt").press("Alt+Enter");
  const queued = page.locator('.bubble.user[data-delivery="queue"]').filter({ hasText: "QUEUED-LATER please" });
  await expect(stageEl(page).locator(".ts-queued .bubble.user")).toHaveText(/QUEUED-LATER please/);
  await expect(queued.locator(".state-badge")).toHaveText("after this turn");
  await expect(page.locator("#prompt")).toHaveValue("");
  // A second one waits behind it.
  await page.locator("#prompt").fill("QUEUED-LATER second");
  await page.locator("#prompt").press("Alt+Enter");
  await expect(stageEl(page).locator(".ts-queued .bubble.user")).toHaveText([/QUEUED-LATER please/, /QUEUED-LATER second/]);
  // Both acked (a reload mid-POST would abort the send).
  await expect(stageEl(page).locator(".ts-queued .bubble.user[data-enqueued-id]")).toHaveCount(2);
  // A reload mid-turn: the line again (clocked from the snapshot's
  // generation), the queued line in the same place.
  await page.reload();
  await expect(line.locator(".delivery-where .long")).toHaveText(/goes in after this thinking step · 0:\d\d/);
  await expect(stageEl(page).locator(".ts-queued .bubble.user")).toHaveText([/QUEUED-LATER please/, /QUEUED-LATER second/]);

  // The second one's × takes it back before it runs: its bubble goes, the first still waits.
  const second = stageEl(page).locator(".ts-queued .bubble.user").filter({ hasText: "QUEUED-LATER second" });
  await second.locator("button.unqueue").click();
  await page.mouse.move(0, 0); // a pointer left over the stage defers its hand-off
  await expect(stageEl(page).locator(".ts-queued .bubble.user")).toHaveText([/QUEUED-LATER please/]);
  // Its text is back in the empty composer, to change and send again (edit).
  await expect(page.locator("#prompt")).toHaveValue("QUEUED-LATER second");
  await page.locator("#prompt").fill("");

  // Taking back the last queued bubble removes its empty slot; a later queue
  // gets a fresh slot so it still appears below the running turn.
  const first = stageEl(page).locator(".ts-queued .bubble.user").filter({ hasText: "QUEUED-LATER please" });
  await first.locator("button.unqueue").click();
  await expect(stageEl(page).locator(".ts-queued")).toHaveCount(0);
  await expect(page.locator("#prompt")).toHaveValue("QUEUED-LATER please");
  await page.locator("#prompt").press("Alt+Enter");
  await expect(stageEl(page).locator(".ts-queued .bubble.user")).toHaveText(/QUEUED-LATER please/);
  await page.mouse.move(0, 0);

  // The first one's turn runs; nothing waits below it.
  await expect(stageEl(page).locator(".ts-prompt")).toHaveText(/QUEUED-LATER please/, { timeout: 30_000 });
  await expect(stageEl(page).locator(".ts-queued .bubble.user")).toHaveCount(0);
  await expect(page.locator("#history .bubble.user")).toHaveText(["Plan it"]);

  // Its own turn, after turn 1's answer; the removed one never runs.
  await handedOff(page, 2);
  const order = await page.locator("#history > .bubble.user, #history > .bubble.output, #history > .turn-timing").evaluateAll(
    (els) => els.map((e) => (e.classList.contains("turn-timing") ? "timing" : e.innerText.split("\n")[0])),
  );
  expect(order).toEqual(["Plan it", "First answer, after the long thinking.", "timing", "QUEUED-LATER please", "Answer to the queued message.", "timing"]);
  await expect(line.locator(".delivery-where.idle")).toBeVisible();
});

// The working set (web.working_set, on by default): the rail in the
// stage holds what the turn read (a file, a memory) without changing the
// stage's height, the session bar's set chip stands in the mem chip's
// place, a step tag jumps to its call live and after a reload, and the
// footprint lands in the handed-off block's summary line.
test.describe("the working set", () => {
  test("the rail fills without a height change; set chip for the mem chip; step tags jump live and after a reload; the footprint", async ({ page, browser, script, chi }) => {
    test.setTimeout(60_000);
    const memories = path.join(chi.dirs.config, "samagotchi", "memories");
    fs.mkdirSync(memories, { recursive: true });
    const note = path.join(memories, "e2e-style.md");
    fs.writeFileSync(note, "Keep it short.\n");
    try {
      script("working_set");
      await startSampling(page);
      await send(page, "Read the README and the style note.");
      await expect(stageEl(page)).toBeVisible();
      await page.mouse.move(0, 0);
      const rail = page.locator("#turnStage .ts-ws");
      // The step that holds: both items in the rail, the chip counts them.
      await expect(rail.locator(".ws-item .t")).toHaveText(["README.md", "e2e-style"]);
      await expect(page.locator("#infoText .ws-chip")).toHaveText("set 2");
      await expect(page.locator("#infoText .mem-chip")).toHaveCount(0);
      // The held step: samples after the items came too (the sampler's 100 ms passes).
      const sampled = await page.evaluate(() => window.samples.length);
      await expect.poll(() => page.evaluate(() => window.samples.length)).toBeGreaterThanOrEqual(sampled + 8);
      const samples = (await stopSampling(page)).filter((s) => !s.hidden && !s.ended);
      expect(samples.length).toBeGreaterThan(5);
      expect([...new Set(samples.map((s) => s.h))]).toHaveLength(1);
      // Live: the rail opens this turn's list; the memory's step tag goes to its call in the stage's cloud.
      await rail.click();
      const pop = page.locator("#workingSetPopover");
      await expect(pop).toBeVisible();
      await pop.locator(".ws-row.memory .ws-step").click();
      await expect(pop).toBeHidden();
      const liveRow = page.locator('#turnStage .turn-work[data-turn="0"] .activity-row[data-at="1.0"]');
      await expect(liveRow).toHaveClass(/ref-flash/);
      await expect(liveRow).toContainText("e2e-style");
      // The used memory is real (the mem chip would show it): the session says so.
      await page.mouse.move(0, 0); // the stage is out of use: it hands off
      await handedOff(page, 1);
      const id = new URL(page.url()).hash.split("/").pop();
      const session = await (await page.request.get(new URL(`/api/sessions/${id}`, page.url()).href)).json();
      expect(session.session.used_memory_names).toContain("e2e-style");
      await expect(page.locator("#infoText .mem-chip")).toHaveCount(0);
      // The footprint is the block's summary line, live and after a reload,
      // the steps' count beside it.
      const block = page.locator("#history .turn-work");
      const foot = block.locator("> summary .ws-foot");
      await expect(foot).toContainText("README.md");
      await expect(foot).toContainText("e2e-style");
      await page.reload();
      await expect(foot).toHaveText(/touched README\.md · ◆ e2e-style s2/);
      await expect(block.locator("> summary .turn-steps")).toContainText("step");
      // The words open the turn's list and leave the block alone, by click and
      // by Enter; the count toggles the block.
      await expect(block).toHaveJSProperty("open", false);
      const list = page.locator("#workingSetPopover");
      await foot.locator(".w").click();
      await expect(list).toBeVisible();
      await expect(block).toHaveJSProperty("open", false);
      await list.locator(".ctx-pop-close").click();
      await expect(list).toBeHidden();
      await foot.focus();
      await page.keyboard.press("Enter");
      await expect(list).toBeVisible();
      await expect(block).toHaveJSProperty("open", false);
      await list.locator(".ctx-pop-close").click();
      await expect(list).toBeHidden();
      await block.locator("> summary .turn-steps").click();
      await expect(block).toHaveJSProperty("open", true);
      // Its motion's end: a click during it is dropped (details_motion.js).
      await block.evaluate((el) => Promise.all(el.getAnimations().map((anim) => anim.finished)));
      await block.locator("> summary .turn-steps").click();
      await expect(block).toHaveJSProperty("open", false);
      // A step tag jumps, into the closed block.
      await foot.locator(".ws-step").click();
      const row = page.locator('#history .turn-work[data-turn="0"] .activity-row[data-at="1.0"]');
      await expect(row).toHaveClass(/ref-flash/);
      await expect(row).toBeInViewport();
      // A phone: no count, so the chevron is the way to the steps: a tap beside
      // its glyph, over the block's padding, opens them; a tap on the words
      // opens the sheet and leaves the block.
      await test.step("at 390 px", async () => {
        const phone = await browser.newContext({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });
        try {
          const small = await phone.newPage();
          await small.goto(page.url());
          const smallBlock = small.locator("#history .turn-work");
          const summary = smallBlock.locator("> summary");
          await expect(summary.locator(".ws-foot")).toBeVisible();
          await expect(summary.locator(".turn-steps")).toBeHidden();
          await expect(smallBlock).toHaveJSProperty("open", false);
          await summary.locator(".ws-foot .w").tap();
          await expect(small.locator("#workingSetPopover")).toBeVisible();
          await expect(smallBlock).toHaveJSProperty("open", false);
          await small.locator("#workingSetPopover .ctx-pop-close").tap();
          await expect(small.locator("#workingSetPopover")).toBeHidden();
          const box = await summary.boundingBox();
          const beside = { x: box.x - 6, y: box.y + box.height / 2 };
          // The hit area itself: Chromium's touch adjustment would snap this tap to the summary anyway.
          expect(await small.evaluate(({ x, y }) => document.elementFromPoint(x, y).tagName, beside)).toBe("SUMMARY");
          await small.touchscreen.tap(beside.x, beside.y);
          await expect(smallBlock).toHaveJSProperty("open", true);
          await expect(small.locator("#workingSetPopover")).toBeHidden();
        } finally {
          await phone.close();
        }
      });
    } finally {
      fs.rmSync(note, { force: true });
    }
  });

  // What chi has (the peek and the reader), then steering (P3a): a drop from the list between turns runs at once (the
  // session's /working-set command): the row is struck `dropped`, and the next
  // turn's first request sends the stub and the turn-start note instead of the
  // README's text (the fake host's recorded request).
  test("peek, the timeline and back; a drop from the list between turns: struck dropped, and the next request sends the stub", async ({ page, script, chi }) => {
    test.setTimeout(60_000);
    script("working_set");
    await send(page, "Read the README and the style note.");
    await expect(stageEl(page)).toBeVisible();
    await page.mouse.move(0, 0);
    await handedOff(page, 1);
    await clickBarItem(page, "workingSet");
    const pop = page.locator("#workingSetPopover");
    const row = pop.locator(".ws-row.file", { hasText: "README.md" });
    // What chi has of it: the row's ▸ peeks (the read's first lines), the
    // peek's link opens the reader over the stage, ← Stage brings it back.
    await row.locator(".ws-peek-toggle").click();
    const peek = pop.locator(".ws-peek");
    await expect(peek.locator(".ws-peek-t")).toHaveText(/latest · read/);
    await expect(peek.locator(".read-line").first()).toBeVisible();
    await peek.locator(".ws-peek-open").click();
    const reader = page.locator("#wsReader");
    await expect(reader).toBeVisible();
    await expect(pop).toBeHidden();
    await expect(reader.locator(".wsr-name")).toHaveText("README.md");
    await expect(reader.locator(".wsr-card.slice .wsr-card-h")).toContainText("1 read");
    await expect(reader.locator(".wsr-item.on")).toContainText("README.md");
    await reader.locator(".wsr-back").click();
    await expect(reader).toBeHidden();
    await expect(page.locator("#history .turn-work")).toBeVisible();
    await clickBarItem(page, "workingSet");
    await row.hover();
    await row.locator('[data-ws="steer"][data-op="drop"]').click();
    await expect(pop.locator(".ws-row.file.dropped", { hasText: "README.md" })).toBeVisible();
    await expect(pop.locator(".ws-row.file", { hasText: "README.md" }).locator(".st")).toContainText("dropped");
    await expect(page.locator("#history .bubble.command").last()).toContainText("dropped README.md");
    await pop.locator(".ctx-pop-close").click();

    const log = path.join(chi.dirs.fake, "requests.log");
    const before = fs.readFileSync(log, "utf8").split("\n").length;
    await send(page, "Again, after the drop.");
    await expect(stageEl(page)).toBeVisible();
    await page.mouse.move(0, 0);
    await handedOff(page, 2);
    const first = fs.readFileSync(log, "utf8").split("\n").slice(before - 1).filter(Boolean).map((l) => JSON.parse(l))
      .find((r) => r.p.endsWith("/chat/completions") && r.body.includes("Again, after the drop."));
    expect(first.body).toContain("(dropped by the user)");
    expect(first.body).toContain("[WORKING SET: since your last turn the user dropped README.md");
    expect(first.body).not.toContain("A file the scripted turns read.");
  });

  // The server's projection (WorkingSet): a file a shell command changed after
  // the read is stale at the next request; its rail line fades in place (no
  // refold, no line moved), its list row says so, and after a reload (the
  // seed's GET working_set) its footprint label is faded too.
  test("a file changed after its read: stale in the rail, the list and the footprint", async ({ page, script, chi }) => {
    const readme = path.join(chi.dirs.project, "README.md");
    const readmeText = fs.readFileSync(readme, "utf8");
    try {
      script("working_set_stale");
      await send(page, "Read the README and note it there.");
      await expect(stageEl(page)).toBeVisible();
      const rail = page.locator("#turnStage .ts-ws");
      const line = rail.locator(".ws-item.file");
      await expect(line.locator(".t")).toHaveText("README.md");
      const slots = () => rail.locator(".ws-item").evaluateAll((els) => els.map((e) => `${e.querySelector(".t").textContent} ${e.style.transform}`));
      const before = await slots();
      await expect(line).toHaveClass(/\bstale\b/);
      await expect(line).toBeVisible();
      await expect(line).toHaveCSS("opacity", "0.55");
      expect(await slots()).toEqual(before);
      await rail.click();
      const pop = page.locator("#workingSetPopover");
      const row = pop.locator(".ws-row.file", { hasText: "README.md" });
      await expect(row.locator(".st")).toContainText("stale");
      await expect(row.locator(".t")).toHaveCSS("opacity", "0.55");
      await pop.locator(".ctx-pop-close").click();
      await expect(pop).toBeHidden();
      await page.mouse.move(0, 0);
      await handedOff(page, 1);
      await page.reload();
      await expect(page.locator("#history .turn-work > summary .ws-foot .l.file.stale")).toHaveText("README.md");
      await expect(page.locator("#history .turn-work > summary .ws-foot .s")).toHaveText("1 stale");
    } finally {
      fs.writeFileSync(readme, readmeText);
    }
  });

  // Off (web.working_set: false, here ?working_set=0): no rail, no
  // footprint, and the session bar's mem chip is back.
  test.describe("turned off", () => {
    test.use({ workingSet: false });

    test("no rail and no footprint; the mem chip names the memory the turn read", async ({ page, script, chi }) => {
      test.setTimeout(60_000);
      const memories = path.join(chi.dirs.config, "samagotchi", "memories");
      fs.mkdirSync(memories, { recursive: true });
      const note = path.join(memories, "e2e-style.md");
      fs.writeFileSync(note, "Keep it short.\n");
      try {
        script("working_set");
        await send(page, "Read the README and the style note.");
        await expect(stageEl(page)).toBeVisible();
        await page.mouse.move(0, 0);
        await handedOff(page, 1);
        // On the row or folded into ⋯ (the fold's choice at this width), it is drawn.
        await expect(page.locator("#infoText .mem-chip")).toHaveCount(1);
        if (!(await barItemOnRow(page, "memories"))) {
          await page.locator("#infoMoreBtn").click();
          await expect(page.locator('#moreSheet [data-row="memories"]')).toBeVisible();
          await page.keyboard.press("Escape");
        }
        await expect(page.locator("#infoText .mem-chip")).toHaveAttribute("title", /e2e-style/);
        await expect(page.locator("#infoText .ws-chip")).toHaveCount(0);
        await expect(page.locator(".ts-ws, .ws-foot")).toHaveCount(0);
      } finally {
        fs.rmSync(note, { force: true });
      }
    });
  });
});
