// The stage view (web.view: stage) on its own: the running turn pinned above
// the composer with fixed live slots, cards in it, and the hand-off into the
// history. The default view: the chromium project runs it, the turn project
// doesn't.
import { test, expect } from "./support/fixtures.js";
import { expectNoHorizontalOverflow } from "./support/layout.js";
import { frames, momentAt, pageNow, shiftSources, shiftSum, snaps, stageMarks, startSampling, startSnaps, stopSampling, watchFrames, watchShifts, watchStage } from "./support/shifts.js";

const stageEl = (page) => page.locator("#turnStage");
// A shift's source in the top bar, or the session panel it pushes down.
const TOP_BAR = /#topBar|#sessionTitle|#stripStatus|#stripGrip|#notifyBtn|section#center$/;
const handedOff = (page, turns) => expect(page.locator("#history .turn-timing:not(.live)")).toHaveCount(turns);

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
  await page.waitForTimeout(500); // the rise and the history's follow are over
  const scrolledAt = await pageNow(page);
  const scrollTopSet = await page.evaluate(() => { document.querySelector("#history").scrollTop = 120; return performance.now(); });
  await handedOff(page, 2);
  await page.waitForTimeout(600); // the fold and the arrival are over
  const samples = await stopSampling(page);
  const running = samples.filter((s) => !s.hidden && !s.ended);
  expect(running.length).toBeGreaterThan(10);
  expect([...new Set(running.map((s) => s.slots))]).toHaveLength(1);
  // One height before check-in's card, one after its growth (the stage
  // never shrinks while the turn runs).
  const cardIndex = running.findIndex((s) => s.extras > 0);
  const noCard = running.slice(0, cardIndex);
  expect(noCard.length).toBeGreaterThan(5);
  expect([...new Set(noCard.map((s) => s.h))]).toHaveLength(1);
  // (The ease can take a few samples under load: from its end on.)
  const grown = running.at(-1).h;
  const withCard = running.slice(running.findIndex((s, i) => i >= cardIndex && s.h === grown));
  expect(withCard.length).toBeGreaterThan(3);
  expect([...new Set(withCard.map((s) => s.h))]).toHaveLength(1);
  expect(running.slice(cardIndex).every((s, i, all) => i === 0 || s.h >= all[i - 1].h)).toBe(true);
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
  // Growth is deliberate: check-in's card and the long answer each grow the
  // stage once, with a short ease (bounded, and no snap).
  const checkInAt = momentAt(marks, (m) => m.extras > 0, shownAt);
  expect(await shiftSum(page, { from: checkInAt, to: checkInAt + 600, withInput: true })).toBeLessThan(0.15);
  expect(await snaps(page, { from: checkInAt, to: checkInAt + 600 })).toEqual([]);
  expect(await shiftSum(page, { from: endAt, to: leaveAt, withInput: true })).toBeLessThan(0.15);
  expect(await snaps(page, { from: endAt, to: leaveAt })).toEqual([]);
  // The hand-off: the stage slides away under the composer, then the turn
  // arrives in the history; nothing shifts or snaps, and it is hidden after.
  const hiddenAt = momentAt(marks, (m) => m.hidden, leaveAt);
  expect(hiddenAt - leaveAt).toBeGreaterThan(300);
  expect(await shiftSum(page, { from: leaveAt, to: hiddenAt + 600 })).toBeLessThan(0.01);
  expect(await snaps(page, { from: leaveAt, to: hiddenAt + 600 })).toEqual([]);
  // A handed-off turn is its outline: open on its narrated steps, each
  // tool-only (or thinking-only) step behind a fold that shows it; a reload
  // draws the same.
  const outline = async () => {
    const blocks = page.locator("#history .turn-work");
    await expect(blocks).toHaveCount(2);
    for (const block of await blocks.all()) {
      await expect(block).toHaveClass(/outline/);
      await expect(block).toHaveJSProperty("open", true);
      await expect(block.locator(":scope > .outline-fold")).toHaveText(["1 step", "1 step"]);
      await expect(block.locator(":scope > .gen:visible")).toHaveCount(4);
    }
  };
  await outline();
  // The outline coming into the history moves nothing there.
  expect(await shiftSum(page, { where: "history" })).toBeLessThan(0.01);
  await page.locator("#history .turn-work").last().locator(".outline-fold").first().click();
  await expect(page.locator("#history .turn-work").last().locator(":scope > .gen:visible")).toHaveCount(5);
  await page.reload();
  await outline();
  // Nor does a reload drawing the old turns' outlines open.
  expect(await shiftSum(page, { where: "history" })).toBeLessThan(0.01);
});

test("the hand-off waits while the pointer is over the stage, runs about 1.5 s after it leaves; an own send hands off at once", async ({ page, script }) => {
  script("turn");
  await send(page, "Check the shell and the README");
  await stageEl(page).hover();
  await expect(stageEl(page)).toHaveAttribute("data-phase", "answered");
  await page.waitForTimeout(5000);
  await expect(stageEl(page)).toBeVisible();
  await expect(stageEl(page).locator(".ts-defer")).toBeVisible();
  await handedOff(page, 0);
  await page.mouse.move(0, 0);
  const left = Date.now();
  await handedOff(page, 1);
  const waited = Date.now() - left;
  expect(waited).toBeGreaterThan(1200);
  expect(waited).toBeLessThan(3500);
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

// The retry is empty too (empty_answer): the stage's status row reads "no
// answer", not "answered", and the notice hands off with the turn.
test("a turn with no answer ends in the stage as no answer", async ({ page, script }) => {
  script("empty_answer");
  await send(page, "Say pong");
  await stageEl(page).hover();
  await expect(stageEl(page)).toHaveAttribute("data-phase", "no answer");
  await expect(stageEl(page).locator(".ts-phase")).toHaveText("no answer");
  await page.mouse.move(0, 0);
  await handedOff(page, 1);
  await expect(page.locator("#history .empty-answer")).toHaveText("no answer: the model returned nothing (after 1 retry)");
});

// A phone (390×700): the stage's cap is low and the top bar wraps its title.
test("a question card sits in the stage (also after a reload mid-turn), and the answer comes after it", async ({ page, script }) => {
  await page.setViewportSize({ width: 390, height: 700 });
  script("question");
  // Every frame: whether a card waits and whether the asking text shows. They
  // land in one frame (no frame with one and not the other).
  await watchFrames(page);
  await watchShifts(page);
  await watchStage(page);
  await send(page, "Read a file of my choice");
  const card = stageEl(page).locator(".ts-extras .bubble.question");
  await expect(card.locator(".question-text")).toHaveText("Which file should I read?");
  await expect(stageEl(page)).toHaveAttribute("data-phase", "waiting for you");
  await expect(page.locator("#history .bubble.question")).toHaveCount(0);
  // The whole reply that asked, in the headline's place (not only its last sentence).
  const asking = stageEl(page).locator(".ts-asking");
  await expect(asking).toContainText("I can start from either file: README.md describes the project");
  await expect(stageEl(page).locator(".ts-headline")).toBeHidden();
  expect((await frames(page)).filter((f) => f.waits !== f.asking)).toEqual([]);
  // With web.markdown on, it reads as markdown: its heading, and its link opens a new tab.
  await expect(asking.locator("h2")).toHaveText("Two files");
  await expect(asking.locator('a[target="_blank"]')).toHaveAttribute("href", "https://example.com/files");
  // A plugin's ref on the reply that asks (e2e-answer-refs, :question_asked): paired in the slot.
  const askRef = asking.locator('[data-ref-kind="issue"]');
  await expect(askRef).toHaveText("JIRA-7");
  await expect(askRef).toHaveAttribute("title", "JIRA-7 Login fails");
  await expectNoHorizontalOverflow(page);
  // The card's arrival grows the stage, briefly; the top bar stays (the
  // hidden strip's pill gains "· 1 waiting" and must not wrap to a row).
  const marks = await stageMarks(page);
  const shownAt = momentAt(marks, (m) => !m.hidden);
  const waitingAt = momentAt(marks, (m) => /\bwaiting\b/.test(m.cls), shownAt);
  expect(await shiftSum(page, { from: waitingAt, to: waitingAt + 600, withInput: true })).toBeLessThan(0.25);
  expect((await shiftSources(page, { from: shownAt + 400 })).filter((n) => TOP_BAR.test(n))).toEqual([]);
  // A reload mid-turn draws the stage again with its card.
  await page.reload();
  await expect(card).toBeVisible();
  await expect(stageEl(page)).toHaveAttribute("data-phase", "waiting for you");
  await expect(asking).toContainText("I can start from either file: README.md describes the project");
  await expect(askRef).toHaveText("JIRA-7");
  await page.waitForFunction(() => document.querySelector("#turnStage").getAnimations().length === 0); // its rise is over
  // A phone's keyboard (the window 420 px tall): the cap drops, the held
  // stage clamps to it at once and the waiting card stays in sight; when
  // the keyboard goes the stage grows back only to what its content needs.
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
  await expect.poll(() => stageEl(page).evaluate((el) => el.offsetHeight)).toBe(before);
  await expect.poll(inSight).toBe(true);
  // From the answer until the turn is answered nothing moves on its own:
  // the card's collapse and the slots' swap come with the click. (The
  // shifts' recorder came back with the reload.)
  await watchFrames(page);
  await watchStage(page);
  await startSnaps(page);
  const submitAt = await pageNow(page);
  await expect(stageEl(page).locator(".ts-prompt .user-message")).toHaveText("Read a file of my choice");
  const cardTop = (await card.boundingBox()).y;
  await card.locator(".question-option", { hasText: "README.md" }).click();
  await card.locator(".question-submit").click();
  await expect(stageEl(page).locator(".ts-answer .bubble.output")).toHaveText("Read the file you picked. Done.");
  await expect(asking).toBeHidden();
  const answeredAt = (await frames(page)).find((f) => f.phase === "answered").t;
  expect(await shiftSum(page, { from: submitAt, to: answeredAt, withInput: true })).toBeLessThan(0.01);
  // The card stays where it was (its collapse and the swap above it happen
  // inside the held stage).
  expect(await snaps(page, { from: submitAt, to: answeredAt, keys: ["card"] })).toEqual([]);
  expect(Math.abs((await card.boundingBox()).y - cardTop)).toBeLessThanOrEqual(2);
  await page.mouse.move(0, 0);
  await handedOff(page, 1);
  await expectNoHorizontalOverflow(page);
  // The turn end with a short answer: the stage keeps its height, nothing
  // in it moves.
  const leaveAt = momentAt(await stageMarks(page), (m) => /\bleaving\b/.test(m.cls), answeredAt);
  expect(await shiftSum(page, { from: answeredAt, to: leaveAt, withInput: true })).toBeLessThan(0.01);
  expect(await snaps(page, { from: answeredAt, to: leaveAt })).toEqual([]);
  // The hand-off to a reader at the history's end: the reserve eases down
  // under the sliding stage and the history follows the turn's arrival.
  await expect(stageEl(page)).toBeHidden();
  await page.waitForTimeout(600);
  expect(await shiftSum(page, { from: leaveAt })).toBeLessThan(0.01);
  expect(await snaps(page, { from: leaveAt })).toEqual([]);
  expect((await shiftSources(page, { from: submitAt })).filter((n) => TOP_BAR.test(n))).toEqual([]);
  // Their classes without the arrival animation's (gone when it ends).
  const kinds = await page.locator("#history > *").evaluateAll((els) => els.map((el) =>
    [...el.classList].filter((c) => c !== "ts-arrive").slice(0, 2).join(" ")));
  expect(kinds).toEqual(["bubble user", "turn-work done", "bubble question", "bubble output", "turn-timing"]);
  // The asking step's text in the history keeps the ref (live, at the turn's end).
  await expect(page.locator('#history .gen > .gen-text [data-ref-kind="issue"]')).toHaveText("JIRA-7");
});

// A long "plan, then ask" reply: the question room. The stage's cap rises
// (0.85 of the page, never above the session panel), the reply reads from
// its start in the stage's one scroll, and a pill leads to the card.
test("a long reply that asks gets the question room: read from its start, a pill to the card, the answer moves nothing", async ({ page, script }) => {
  script("question_long");
  await watchShifts(page);
  await watchStage(page);
  await send(page, "Plan it, then ask me");
  const card = stageEl(page).locator(".ts-extras .bubble.question");
  await expect(card.locator(".question-text")).toHaveText("Which file should I read?");
  await expect(stageEl(page)).toHaveClass(/question-room/);
  const asking = stageEl(page).locator(".ts-asking");
  await expect(asking.locator("h2")).toHaveText("A plan before I start");
  // The raised cap, read as fitCap reads the room; the stage grows to it.
  const want = await page.evaluate(() => {
    const room = document.querySelector("#center").clientHeight - (document.querySelector("#dock").offsetHeight + 10) - 32;
    return Math.min(0.85 * window.innerHeight, room) - 2;
  });
  await expect.poll(() => stageEl(page).evaluate((el) => el.offsetHeight)).toBeGreaterThanOrEqual(want);
  // The asking slot has no scroll of its own.
  expect(await asking.evaluate((el) => el.scrollHeight - el.clientHeight)).toBeLessThanOrEqual(1);
  const scroller = stageEl(page).locator(".ts-scroll");
  const inSight = async () => {
    const [c, v] = [await card.boundingBox(), await scroller.boundingBox()];
    return c.y + Math.min(c.height, 40) <= v.y + v.height && c.y + c.height > v.y;
  };
  // Read from the reply's start: its top in the stage's view, the card below it.
  await expect.poll(async () => {
    const [a, v] = [await asking.boundingBox(), await scroller.boundingBox()];
    return a.y >= v.y - 1 && a.y < v.y + v.height;
  }).toBe(true);
  expect(await inSight()).toBe(false);
  const pill = stageEl(page).locator(".ts-room-pill");
  await expect(pill).toBeVisible();
  await expect(pill).toHaveAccessibleName("Go to the question");
  await expectNoHorizontalOverflow(page);
  await pill.click();
  await expect.poll(inSight).toBe(true);
  await expect(pill).toBeHidden();
  // From the answer until the turn is answered nothing moves on its own.
  await page.waitForFunction(() => document.querySelector("#turnStage").getAnimations().length === 0);
  await page.waitForFunction(() => !document.querySelector("#turnStage [data-following]")); // the pill's ease is over
  await watchFrames(page);
  await startSnaps(page);
  const submitAt = await pageNow(page);
  const cardTop = (await card.boundingBox()).y;
  await card.locator(".question-option", { hasText: "README.md" }).click();
  await card.locator(".question-submit").click();
  await expect(stageEl(page).locator(".ts-answer .bubble.output")).toHaveText("Read the file you picked. Done.");
  await expect(stageEl(page)).not.toHaveClass(/question-room/);
  await expect(pill).toBeHidden();
  const answeredAt = (await frames(page)).find((f) => f.phase === "answered").t;
  expect(await shiftSum(page, { from: submitAt, to: answeredAt, withInput: true })).toBeLessThan(0.01);
  expect(await snaps(page, { from: submitAt, to: answeredAt, keys: ["card"] })).toEqual([]);
  expect(Math.abs((await card.boundingBox()).y - cardTop)).toBeLessThanOrEqual(2);
  await page.mouse.move(0, 0);
  await handedOff(page, 1);
  const kinds = await page.locator("#history > *").evaluateAll((els) => els.map((el) =>
    [...el.classList].filter((c) => c !== "ts-arrive").slice(0, 2).join(" ")));
  expect(kinds).toEqual(["bubble user", "turn-work done", "bubble question", "bubble output", "turn-timing"]);
});

test("the stage folds to its status row, and stays folded across a reload", async ({ page, script }) => {
  script("hold");
  await send(page, "Take your time");
  await expect(stageEl(page)).toBeVisible();
  await stageEl(page).locator(".ts-fold").click();
  await expect(stageEl(page)).toHaveClass(/collapsed/);
  await expect(stageEl(page).locator(".ts-scroll")).toBeHidden();
  await page.reload();
  await expect(stageEl(page)).toBeVisible();
  await expect(stageEl(page)).toHaveClass(/collapsed/);
  await stageEl(page).locator(".ts-status").click();
  await expect(stageEl(page)).not.toHaveClass(/collapsed/);
  expect(await page.evaluate(() => localStorage.getItem("chi_stage_collapsed"))).toBe("0");
  await page.locator("#cancelBtn").click();
  await page.mouse.move(0, 0);
  await handedOff(page, 1);
  await expect(page.locator("#history .bubble.cancel")).toContainText("canceled");
});

test("check-in's card waits for the user in the stage; after Nudge the turn stays in the stage until it ends, then hands off", async ({ page, script }) => {
  script("check_in");
  await send(page, "Look through the README");
  const card = stageEl(page).locator(".ts-extras .plugin-card");
  await expect(card.locator(".card-title")).toHaveText("3 tool calls, no answer yet");
  await expect(stageEl(page)).toHaveAttribute("data-phase", "waiting for you");
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
  await expect(card).toContainText("Nudged the model at 3 tool calls.");
  await expect(stageEl(page)).not.toHaveAttribute("data-phase", "waiting for you");
  await handedOff(page, 1);
  const samples = await page.evaluate(() => { clearInterval(window.holdSampler); return window.held; });
  const running = samples.filter((s) => s.phase !== "answered");
  expect(running.length).toBeGreaterThan(20);
  expect(running.every((s) => s.inStage && s.inHistory === 0)).toBe(true);
  expect(samples.some((s) => s.phase === "answered" && s.inStage)).toBe(true);
  // The nudge is a row of the step that answered it, handed off with the block.
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
