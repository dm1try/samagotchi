// Happy paths of the web UI against a scripted fake model (support/scripts).
// Assertions are on page state only; every wait is on the DOM, no sleeps.
import { test, expect } from "./support/fixtures.js";
import { APPROVAL_COMMAND } from "./support/env.js";

// Types into the composer and sends (Start on the start page, Send in a session).
async function send(page, prompt) {
  await page.locator("#prompt").fill(prompt);
  await page.locator("#actionBtn").click();
  await expect(page.locator("#history .bubble.user").last()).toHaveText(prompt);
}

// The turn is over: its timing line is final, Cancel is gone, Send is enabled.
async function turnEnded(page, turns) {
  await expect(page.locator("#history .turn-timing:not(.live)")).toHaveCount(turns);
  await expect(page.locator("#cancelBtn")).toBeHidden();
  await expect(page.locator("#actionBtn")).toHaveText("Send");
  await expect(page.locator("#actionBtn")).toBeEnabled();
  await expect(page.locator("#prompt")).toBeEditable();
}

const answer = (page) => page.locator("#history .bubble.output").last();

test("a prompt from the start page streams an answer and the turn ends", async ({ page, script }) => {
  script("plain");
  await expect(page.locator("#actionBtn")).toHaveText("Start");
  // Records each text a live (.streaming) element shows the answer with,
  // however fast the turn runs: streamed means more than one.
  await page.evaluate(() => {
    window.streamed = new Set();
    new MutationObserver(() => {
      for (const el of document.querySelectorAll("#history .streaming")) {
        if (el.textContent.includes("PONG")) window.streamed.add(el.textContent);
      }
    }).observe(document.querySelector("#history"), { subtree: true, childList: true, characterData: true, attributes: true });
  });
  await send(page, "Say pong");
  await expect(page).toHaveURL(/#\/s\/[0-9a-f-]+$/);
  await expect(answer(page)).toHaveText("PONG from the fake model. It streams word by word. Then the turn ends.");
  await turnEnded(page, 1);
  await expect(answer(page)).toBeVisible();
  // It streamed, then ended as rendered markdown.
  expect(await page.evaluate(() => window.streamed.size)).toBeGreaterThan(1);
  await expect(answer(page)).toHaveClass(/markdown/);
  await expect(answer(page)).not.toHaveClass(/streaming/);
});

test("a multi-step turn shows its steps, tool rows and the markdown answer", async ({ page, script }) => {
  script("turn");
  await send(page, "Check the shell and the README");
  await turnEnded(page, 1);
  const work = page.locator("#history .turn-work.done");
  await expect(work.locator("> summary")).toHaveText("3 steps · 2 tool calls");
  const rows = work.locator(".activity-row");
  await expect(rows).toHaveCount(2);
  await expect(rows.nth(0).locator(".activity-tool")).toHaveText("execute");
  await expect(rows.nth(0).locator(".activity-status")).toHaveText("done");
  await expect(rows.nth(1).locator(".activity-tool")).toHaveText("read");
  await expect(rows.nth(1).locator(".activity-output")).toContainText("# e2e project");
  await expect(answer(page).locator("li")).toHaveText(["the shell answers (true exited 0)", "README.md is readable"]);
  await expect(answer(page).locator("strong")).toHaveText("good");
  await expect(answer(page)).toBeVisible();
});

test("a reload after the turn shows the same turn and answer", async ({ page, script }) => {
  script("turn");
  await send(page, "Check the shell and the README");
  await turnEnded(page, 1);
  const before = {
    user: await page.locator("#history .bubble.user").allTextContents(),
    summary: await page.locator("#history .turn-work > summary").allTextContents(),
    tools: await page.locator("#history .activity-tool").allTextContents(),
    answer: await answer(page).innerHTML(),
  };
  await page.reload();
  await turnEnded(page, 1);
  await expect(page.locator("#history .bubble.user")).toHaveText(before.user);
  await expect(page.locator("#history .turn-work > summary")).toHaveText(before.summary);
  await expect(page.locator("#history .activity-tool")).toHaveText(before.tools);
  expect(await answer(page).innerHTML()).toBe(before.answer);
});

test("cancel mid-turn shows the canceled turn, and the next send works", async ({ page, script }) => {
  script("hold");
  await send(page, "Take your time");
  await expect(page.locator("#cancelBtn")).toBeVisible();
  await page.locator("#cancelBtn").click();
  await expect(page.locator("#history .bubble.cancel")).toContainText("canceled");
  await expect(page.locator("#cancelBtn")).toBeHidden();

  script("plain");
  await send(page, "Say pong");
  await expect(answer(page)).toHaveText("PONG from the fake model. It streams word by word. Then the turn ends.");
  await turnEnded(page, 2);
});

test("a question card: the answer lets the turn go on", async ({ page, script }) => {
  script("question");
  await send(page, "Read a file of my choice");
  const card = page.locator("#history .bubble.question");
  await expect(card.locator(".question-text")).toHaveText("Which file should I read?");
  await card.locator(".question-option", { hasText: "README.md" }).click();
  await card.locator(".question-submit").click();
  await expect(card.locator(".question-result")).toContainText("README.md");
  await expect(answer(page)).toHaveText("Read the file you picked. Done.");
  await turnEnded(page, 1);
  await expect(page.locator("#history .activity-tool")).toHaveText(["ask_user_question", "read"]);
});

test("an approval card: allowing it runs the tool", async ({ page, script }) => {
  script("approval");
  await send(page, "Run the command that needs approval");
  const card = page.locator("#history .bubble.question.approval");
  await expect(card.locator(".approval-what")).toHaveText(APPROVAL_COMMAND);
  await expect(card.locator(".approval-why")).toContainText("e2e-ask");
  await card.locator(".question-option").first().click();
  await card.locator(".question-submit").click();
  await expect(card.locator(".question-result")).toContainText("Allow");
  await expect(answer(page)).toHaveText("The approved command ran.");
  await turnEnded(page, 1);
  const row = page.locator("#history .activity-row").filter({ hasText: "execute" });
  await expect(row.locator(".activity-status")).toHaveText("done");
  await expect(row.locator(".activity-output")).toContainText("E2E_APPROVED");
});

test("the model picker lists the fake model", async ({ page }) => {
  const select = page.locator("#modelSelect");
  await expect(page.locator("#modelPick")).toBeVisible();
  await expect(select.locator("option")).toHaveText(["fake-script"]);
  await expect(select).toHaveValue("fake-script");
});
