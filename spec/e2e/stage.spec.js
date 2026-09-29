// The stage view (web.view: stage) on its own: the running turn pinned above
// the composer with fixed live slots, cards in it, and the hand-off into the
// history. Runs in the "stage" project only (@stage-only, ?view=stage).
import { test, expect } from "./support/fixtures.js";

const TAG = { tag: "@stage-only" };
const stageEl = (page) => page.locator("#turnStage");
const handedOff = (page, turns) => expect(page.locator("#history .turn-timing:not(.live)")).toHaveCount(turns);

async function send(page, prompt) {
  await page.locator("#prompt").fill(prompt);
  await page.locator("#actionBtn").click();
}

// Samples the stage's height and the history's scrollTop every 100 ms until
// stopSampling(): window.samples.
async function startSampling(page) {
  await page.evaluate(() => {
    window.samples = [];
    window.sampler = setInterval(() => {
      const s = document.querySelector("#turnStage");
      window.samples.push({
        h: s.offsetHeight, hidden: s.hidden, ended: s.classList.contains("ended") || s.classList.contains("leaving"),
        // The live slots (status, prompt, headline/tool/trail, chip); the
        // extras (a card: here check-in's, after 3 calls) may add below them.
        slots: [".ts-status", ".ts-prompt", ".ts-live", ".ts-cloud"].reduce((sum, sel) => sum + s.querySelector(sel).offsetHeight, 0),
        extras: s.querySelector(".ts-extras").offsetHeight,
        top: document.querySelector("#history").scrollTop,
      });
    }, 100);
  });
}
const stopSampling = (page) => page.evaluate(() => { clearInterval(window.sampler); return window.samples; });

test("the stage keeps one height while a multi-step turn runs; nothing moves the history; a scrolled-up reader stays at the hand-off", TAG, async ({ page, script }) => {
  script("stage");
  await send(page, "First round");
  await page.mouse.move(0, 0);
  await handedOff(page, 1);
  // A reader scrolled up into the first turn's long answer.
  await send(page, "Second round");
  await expect(stageEl(page)).toBeVisible();
  await page.mouse.move(0, 0);
  await page.evaluate(() => { document.querySelector("#history").scrollTop = 120; });
  await startSampling(page);
  await handedOff(page, 2);
  await page.waitForTimeout(600); // the fold and the arrival are over
  const samples = await stopSampling(page);
  const running = samples.filter((s) => !s.hidden && !s.ended);
  expect(running.length).toBeGreaterThan(10);
  expect([...new Set(running.map((s) => s.slots))]).toHaveLength(1);
  const noCard = running.filter((s) => s.extras === 0);
  expect(noCard.length).toBeGreaterThan(5);
  expect([...new Set(noCard.map((s) => s.h))]).toHaveLength(1);
  expect([...new Set(samples.map((s) => s.top))]).toEqual([120]);
});

test("the hand-off waits while the pointer is over the stage, runs about 1.5 s after it leaves; an own send hands off at once", TAG, async ({ page, script }) => {
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

test("a question card sits in the stage (also after a reload mid-turn), and the answer comes after it", TAG, async ({ page, script }) => {
  script("question");
  await send(page, "Read a file of my choice");
  const card = stageEl(page).locator(".ts-extras .bubble.question");
  await expect(card.locator(".question-text")).toHaveText("Which file should I read?");
  await expect(stageEl(page)).toHaveAttribute("data-phase", "waiting for you");
  await expect(page.locator("#history .bubble.question")).toHaveCount(0);
  // A reload mid-turn draws the stage again with its card.
  await page.reload();
  await expect(card).toBeVisible();
  await expect(stageEl(page)).toHaveAttribute("data-phase", "waiting for you");
  await expect(stageEl(page).locator(".ts-prompt .user-message")).toHaveText("Read a file of my choice");
  await card.locator(".question-option", { hasText: "README.md" }).click();
  await card.locator(".question-submit").click();
  await expect(stageEl(page).locator(".ts-answer .bubble.output")).toHaveText("Read the file you picked. Done.");
  await page.mouse.move(0, 0);
  await handedOff(page, 1);
  // Their classes without the arrival animation's (gone when it ends).
  const kinds = await page.locator("#history > *").evaluateAll((els) => els.map((el) =>
    [...el.classList].filter((c) => c !== "ts-arrive").slice(0, 2).join(" ")));
  expect(kinds).toEqual(["bubble user", "turn-work done", "bubble question", "bubble output", "turn-timing"]);
});

test("the stage folds to its status row, and stays folded across a reload", TAG, async ({ page, script }) => {
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
