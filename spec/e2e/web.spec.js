// Happy paths of the web UI against a scripted fake model (support/scripts).
// Assertions are on page state only; every wait is on the DOM, no sleeps.
import { test, expect } from "./support/fixtures.js";
import { APPROVAL_COMMAND } from "./support/env.js";

// Types into the composer and sends (Start on the start page, Send in a session).
async function send(page, prompt) {
  await page.locator("#prompt").fill(prompt);
  await page.locator("#actionBtn").click();
  // Contains, not equals: a fast failure adds its "failed" badge to the
  // bubble's text before this check runs.
  await expect(page.locator("#history .bubble.user").last()).toContainText(prompt);
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

// Nothing streams after the turn: the meter and the card read the saved context.
test("a reload after the turn shows the context meter and the card's ctx", async ({ page, script }) => {
  script("plain");
  await send(page, "Say pong");
  await turnEnded(page, 1);
  await page.reload();
  await turnEnded(page, 1);
  await expect(page.locator("#infoBar .meta")).toContainText(/ctx \d+%/);
  await expect(page.locator("#topStrip .card .ctx").first()).toHaveText(/^\d+%$/);
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

// Annotate presets: a pill quotes the selection with its text as the note
// into the composer and sends nothing. The selection is set with a Range
// (a mouse drag is the same selectionchange, less exact).
test("an annotate preset fills the composer with the quote and never sends", async ({ page, script }) => {
  script("plain");
  await send(page, "Say pong");
  await turnEnded(page, 1);
  const turnPosts = [];
  page.on("request", (req) => { if (req.method() === "POST" && /\/turn$/.test(req.url())) turnPosts.push(req.url()); });
  await page.evaluate(() => {
    const text = [...document.querySelectorAll("#history .bubble.output")].pop().querySelector("p").firstChild;
    const range = document.createRange();
    range.setStart(text, 0);
    range.setEnd(text, "PONG from the fake model.".length);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  });
  const bar = page.locator("#annotateBar");
  await expect(bar.locator("button")).toHaveText(["Annotate", "Agreed", "Could you please elaborate?"]);
  await bar.getByRole("button", { name: "Agreed" }).click();
  await expect(page.locator("#prompt")).toHaveValue("> PONG from the fake model.\n\nAgreed");
  await expect(bar).toBeHidden();
  await expect(page.locator("#prompt")).toBeFocused();
  await expect(page.locator("#history .bubble.user")).toHaveCount(1);
  expect(turnPosts).toEqual([]);
});

test("the model picker lists the fake model", async ({ page }) => {
  const select = page.locator("#modelSelect");
  await expect(page.locator("#modelPick")).toBeVisible();
  await expect(select.locator("option")).toHaveText(["fake-script"]);
  await expect(select).toHaveValue("fake-script");
});

test("archive hides a session from the strip, include archived finds it, unarchive brings it back", async ({ page, script }) => {
  script("plain");
  await send(page, "Say pong");
  await turnEnded(page, 1);
  const id = page.url().match(/#\/s\/([0-9a-f-]+)$/)[1];
  const stripCard = page.locator(`#topStrip .card[data-id="${id}"]`);
  await expect(stripCard).toBeVisible();

  await expect(page.locator("#infoBar > button:visible")).toHaveText(["archive", "stop", "delete"]);
  await page.locator("#infoArchiveBtn").click();
  await expect(page.locator("#infoArchiveBtn")).toHaveText("unarchive");
  await expect(page.locator("#toast")).toContainText(`Archived ${id.slice(0, 8)}`);
  await expect(stripCard).toHaveCount(0);
  await expect(page.locator("#infoStopBtn")).toBeHidden();
  // Still on the session.
  await expect(page).toHaveURL(new RegExp(`#/s/${id}$`));

  await page.locator("#allTile").click();
  const listed = page.locator(`#allList .card[data-id="${id}"]`);
  await expect(listed).toHaveCount(0);
  await page.locator("#includeArchived").check();
  await expect(listed).toHaveClass(/archived/);
  await expect(listed.locator(".archived-badge")).toHaveText("archived");
  await listed.click();

  await expect(page.locator("#infoArchiveBtn")).toHaveText("unarchive");
  await page.locator("#infoArchiveBtn").click();
  await expect(page.locator("#infoArchiveBtn")).toHaveText("archive");
  await expect(stripCard).toBeVisible();
});

// Notifications: the tab says whether it is in front through a stubbed
// visibilityState/hasFocus (window.__setFront), and a stub Notification
// records what would be shown (window.__notes). The page starts behind.
async function withNotificationStub(page) {
  await page.addInitScript(() => {
    window.__visible = false;
    window.__focused = false;
    window.__notes = [];
    Object.defineProperty(document, "visibilityState", { configurable: true, get: () => (window.__visible ? "visible" : "hidden") });
    document.hasFocus = () => window.__focused;
    // The permission outlives a reload, as a browser's does.
    window.Notification = class {
      static get permission() { return sessionStorage.getItem("stub_permission") || "default"; }
      static async requestPermission() { sessionStorage.setItem("stub_permission", "granted"); return "granted"; }
      constructor(title, options = {}) { window.__notes.push({ title, body: options.body, tag: options.tag }); }
      close() {}
    };
    window.__setFront = (front) => {
      window.__visible = front;
      window.__focused = front;
      document.dispatchEvent(new Event("visibilitychange"));
    };
    // Safari's order on a tab switch: visible first, focus later (or no
    // focus event at all inside an already focused window).
    window.__showTab = () => {
      window.__visible = true;
      document.dispatchEvent(new Event("visibilitychange"));
    };
  });
  await page.reload();
}

const notes = (page) => page.evaluate(() => window.__notes);

test("the bell asks for permission once and stays on across a reload", async ({ page }) => {
  await withNotificationStub(page);
  const bell = page.locator("#notifyBtn");
  await expect(bell).toHaveAttribute("data-state", "off");
  await bell.click();
  await expect(bell).toHaveAttribute("data-state", "on");
  await expect(bell).toHaveAttribute("aria-pressed", "true");
  await page.reload();
  await expect(bell).toHaveAttribute("data-state", "on");
  await bell.click();
  await expect(bell).toHaveAttribute("data-state", "off");
  await page.reload();
  await expect(bell).toHaveAttribute("data-state", "off");
});

test("a question in a background tab: one notification and a title badge; in front it clears; a reload shows none", async ({ page, script }) => {
  await withNotificationStub(page);
  await page.locator("#notifyBtn").click();
  await expect(page.locator("#notifyBtn")).toHaveAttribute("data-state", "on");

  script("question");
  await send(page, "Read a file of my choice");
  const card = page.locator("#history .bubble.question");
  await expect(card.locator(".question-text")).toHaveText("Which file should I read?");
  await expect.poll(() => notes(page)).toEqual([
    expect.objectContaining({ title: "Read a file of my choice", body: "needs an answer", tag: expect.stringMatching(/:/) }),
  ]);
  await expect(page).toHaveTitle(/^\(1\) Chi/);

  // A reload with the question still open: old state, no notification.
  await page.reload();
  await expect(card.locator(".question-text")).toHaveText("Which file should I read?");
  await expect(page.locator("#topStrip .card").first()).toBeVisible();
  await expect(page).not.toHaveTitle(/^\(/);
  expect(await notes(page)).toEqual([]);

  // Back in front: nothing counts, and the badge is gone.
  await page.evaluate(() => window.__setFront(true));
  await card.locator(".question-option", { hasText: "README.md" }).click();
  await card.locator(".question-submit").click();
  await turnEnded(page, 1);
  expect(await notes(page)).toEqual([]);
  await expect(page).not.toHaveTitle(/^\(/);
});

test("the title badge counts while behind and clears when the tab comes to the front", async ({ page, script }) => {
  await withNotificationStub(page);
  script("question");
  await send(page, "Read a file of my choice");
  const card = page.locator("#history .bubble.question");
  await expect(page).toHaveTitle(/^\(1\) Chi/);
  // No bell: the badge still counts, and no notification is shown.
  expect(await notes(page)).toEqual([]);
  await page.evaluate(() => window.__setFront(true));
  await expect(page).not.toHaveTitle(/^\(/);
  await card.locator(".question-option", { hasText: "README.md" }).click();
  await card.locator(".question-submit").click();
  await turnEnded(page, 1);
});

test("the title badge clears when the tab turns visible before it has focus (Safari's order)", async ({ page, script }) => {
  await withNotificationStub(page);
  script("question");
  await send(page, "Read a file of my choice");
  const card = page.locator("#history .bubble.question");
  await expect(page).toHaveTitle(/^\(1\) Chi/);
  await page.evaluate(() => window.__showTab());
  await expect(page).not.toHaveTitle(/^\(/);
  await page.evaluate(() => window.__setFront(true));
  await card.locator(".question-option", { hasText: "README.md" }).click();
  await card.locator(".question-submit").click();
  await turnEnded(page, 1);
});

test("the title badge drops a question answered from another client", async ({ page, script }) => {
  await withNotificationStub(page);
  script("question");
  await send(page, "Read a file of my choice");
  const card = page.locator("#history .bubble.question");
  await expect(page).toHaveTitle(/^\(1\) Chi/);
  // Another client answers; this tab stays behind.
  const id = page.url().match(/#\/s\/([0-9a-f-]+)$/)[1];
  const qid = await card.getAttribute("data-qid");
  const res = await page.request.post(new URL(`/api/sessions/${id}/answer`, page.url()).href, { data: { id: qid, selected: ["README.md"] } });
  expect(res.ok()).toBe(true);
  await turnEnded(page, 1);
  await expect(page).not.toHaveTitle(/^\(/);
});

test("a first turn that fails shows its prompt and why, once live and again after a reload", async ({ page, fakeMode }) => {
  fakeMode("500");
  await send(page, "Say pong");
  const shown = async () => {
    await expect(page.locator("#history > *")).toHaveCount(2);
    await expect(page.locator("#history .bubble.user.failed .user-message")).toHaveText("Say pong");
    await expect(page.locator("#history .bubble.cancel")).toHaveText("✕ turn failed: server error from host main: HTTP 500: boom");
  };
  await shown();
  await page.reload();
  await shown();
  await expect(page.locator("#history .hint")).toHaveCount(0);
});

test("/archive and /exit typed in the composer get a local reply, not a worker error", async ({ page, script }) => {
  script("plain");
  await send(page, "Say pong");
  await turnEnded(page, 1);
  for (const [line, reply] of [["/archive", /^\/archive: use the archive button/], ["/exit", /^\/exit: /]]) {
    await page.locator("#prompt").fill(line);
    await page.locator("#actionBtn").click();
    const bubble = page.locator("#history .bubble.command").last();
    await expect(bubble.locator(".command-line")).toHaveText(line);
    await expect(bubble.locator(".command-output")).toHaveText(reply);
    await expect(bubble).not.toHaveClass(/failed/);
    await expect(page.locator("#prompt")).toHaveValue("");
  }
  await expect(page.locator("#infoArchiveBtn")).toHaveText("archive");
});

// check-in (after: 3 in the e2e config): the card comes up in the running
// step after the 3rd call; Nudge puts its message into the turn as a nudge
// row of that step, and the model's next step answers it.
test("check-in: the card mid-turn, Nudge makes a nudge row before the answer, live and after a reload", async ({ page, script }) => {
  script("check_in");
  await send(page, "Look through the README");
  const card = page.locator("#history > .plugin-card").filter({ hasText: "3 tool calls, no answer yet" });
  await expect(card).toBeVisible();
  await card.locator(".card-action", { hasText: "Nudge" }).click();
  // The step that answers it shows it (open, live), before the answer.
  const row = page.locator("#history .steer-row");
  await expect(row.locator("summary")).toHaveText("check-in nudged the model");
  await expect(row).toBeVisible();
  await turnEnded(page, 1);
  await expect(answer(page)).toHaveText("Found so far: the README is an e2e project file. Nothing is left.");
  await expect(page.locator("#history .bubble.user")).toHaveCount(1);
  await expect(page.locator("#history .plugin-card .card-action")).toHaveCount(0);

  await page.reload();
  await turnEnded(page, 1);
  await expect(page.locator("#history .bubble.user")).toHaveCount(1);
  const reloaded = page.locator("#history .steer-row");
  await expect(reloaded).toHaveCount(1);
  await expect(reloaded.locator("summary")).toHaveText("check-in nudged the model");
  await expect(reloaded.locator(".steer-text")).toContainText("You've made 3 tool calls in this turn");
});
