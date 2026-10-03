// Happy paths of the web UI against a scripted fake model (support/scripts).
// Assertions are on page state only; every wait is on the DOM, no sleeps.
import { test, expect } from "./support/fixtures.js";
import { APPROVAL_COMMAND, EDIT_ASK_FILE } from "./support/env.js";

// The stage view (the default; the turn project runs @turn scenarios again
// on ?view=turn): a running turn's rows are in #turnStage until the hand-off
// moves them into #history. H() is where a live row can be; HC() the
// containers a card sits directly in.
const stage = () => test.info().project.use.view !== "turn";
const H = () => (stage() ? ":is(#history, #turnStage)" : "#history");
const HC = () => (stage() ? ":is(#history, #turnStage .ts-extras, #turnStage .ts-tail)" : "#history");

// Types into the composer and sends (Start on the start page, Send in a session).
async function send(page, prompt) {
  await page.locator("#prompt").fill(prompt);
  await page.locator("#actionBtn").click();
  // Contains, not equals: a fast failure adds its "failed" badge to the
  // bubble's text before this check runs.
  await expect(page.locator(`${H()} .bubble.user`).last()).toContainText(prompt);
}

// The turn is over: its timing line is final, Cancel is gone, Send is enabled.
// In the stage view: handed off into the history too (the pointer leaves
// the stage first: a click in it holds the hand-off, as it would a reader).
async function turnEnded(page, turns) {
  if (stage()) await page.mouse.move(0, 0);
  await expect(page.locator("#history .turn-timing:not(.live)")).toHaveCount(turns);
  await expect(page.locator("#cancelBtn")).toBeHidden();
  await expect(page.locator("#actionBtn")).toHaveText("Send");
  await expect(page.locator("#actionBtn")).toBeEnabled();
  await expect(page.locator("#prompt")).toBeEditable();
}

const answer = (page) => page.locator(`${H()} .bubble.output`).last();

test("a prompt from the start page streams an answer and the turn ends", { tag: "@turn" }, async ({ page, script }) => {
  script("plain");
  await expect(page.locator("#actionBtn")).toHaveText("Start");
  // Records each text a live (.streaming) element shows the answer with,
  // however fast the turn runs: streamed means more than one.
  await page.evaluate(() => {
    window.streamed = new Set();
    new MutationObserver(() => {
      for (const el of document.querySelectorAll(":is(#history, #turnStage) .streaming")) {
        if (el.textContent.includes("PONG")) window.streamed.add(el.textContent);
      }
    }).observe(document.querySelector("#center"), { subtree: true, childList: true, characterData: true, attributes: true });
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

test("a multi-step turn shows its steps, tool rows and the markdown answer", { tag: "@turn" }, async ({ page, script }) => {
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

test("a reload after the turn shows the same turn and answer", { tag: "@turn" }, async ({ page, script }) => {
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

// The first generation has thinking only: the loop asks again in the same
// turn, the empty step says so, and a reload shows one turn with the answer
// and the asking-again row (the empty step isn't saved: a row before the
// answer).
test("an empty answer is asked again in the same turn, and a reload shows one turn with its retry row", { tag: "@turn" }, async ({ page, script }) => {
  script("empty_retry");
  await send(page, "Say pong");
  await expect(answer(page)).toHaveText("PONG after the retry.");
  await turnEnded(page, 1);
  await expect(page.locator("#history .turn-work .hook-notice")).toHaveText("↻ empty answer, asking again (1/1)");
  await expect(page.locator("#history .bubble.output")).toHaveCount(1);
  await page.reload();
  await turnEnded(page, 1);
  await expect(page.locator("#history .bubble.user")).toHaveCount(1);
  await expect(answer(page)).toHaveText("PONG after the retry.");
  await expect(page.locator("#history .bubble.output")).toHaveCount(1);
  await expect(page.locator("#history .hook-notice")).toHaveText(["↻ empty answer, asking again (1/1)"]);
});

// The retry is empty too: the turn ends with no answer. One muted notice
// where the answer goes (no answer bubble), live and after a reload, which
// keeps both empty steps and the retry row in them.
test("a turn with no answer shows one notice, live and after a reload, with its steps", { tag: "@turn" }, async ({ page, script }) => {
  script("empty_answer");
  await send(page, "Say pong");
  await turnEnded(page, 1);
  const notice = page.locator("#history .empty-answer");
  await expect(notice).toHaveText("no answer: the model returned nothing (after 1 retry)");
  await expect(page.locator("#history .bubble.output")).toHaveCount(0);
  await page.reload();
  await turnEnded(page, 1);
  await expect(notice).toHaveText("no answer: the model returned nothing (after 1 retry)");
  await expect(page.locator("#history .bubble.output")).toHaveCount(0);
  await expect(page.locator("#history .turn-work > summary")).toHaveText("2 steps");
  await expect(page.locator("#history .turn-work .hook-notice")).toHaveText("↻ empty answer, asking again (1/1)");
  // Where the answer goes: after the steps, before the timing line.
  await expect(page.locator("#history .turn-work + .empty-answer + .turn-timing")).toHaveCount(1);
});

// A turn's own rows come back where they were, on a mid-turn join and after
// the turn: the empty answer's retry row, the answered question card, and
// a line sent while the turn ran (the steered bubble, not a turn of its own).
test("a reload mid-turn and after it keeps the retry row, the answered card and the steered line in the turn", { tag: "@turn" }, async ({ page, script }) => {
  script("reload_rows");
  await send(page, "Read a file of my choice");
  const card = page.locator(`${H()} .bubble.question`);
  await expect(card).toHaveCount(1);
  await card.locator(".question-option input").first().check();
  await card.locator(".question-submit").click();
  await expect(page.locator(`${H()} .bubble.question.answered`)).toHaveCount(1);
  // Sent while the read holds: merged into this turn after it.
  await page.locator("#prompt").fill("mind the typos");
  await page.locator("#actionBtn").click();
  await expect(page.locator(`${H()} .bubble.user.steered`)).toHaveCount(1);
  await expect(page.locator(`${H()} .activity-row`).filter({ hasText: "README.md" }).last().locator(".activity-status.ok")).toHaveCount(1);

  const rows = async (where) => ({
    retry: await page.locator(`${where} .hook-notice`).allTextContents(),
    card: await page.locator(`${where} .bubble.question.answered summary`).allTextContents(),
    steered: await page.locator(`${where} .bubble.user.steered .user-message`).allTextContents(),
    prompts: await page.locator(`${where} .bubble.user:not(.steered)`).count(),
  });
  const expected = {
    retry: ["↻ empty answer, asking again (1/1)"],
    card: ["Which file should I read? → README.md"],
    steered: ["mind the typos"],
    prompts: 1,
  };
  // The last step holds: join the running turn.
  await page.reload();
  await expect(page.locator(`${H()} .bubble.question.answered`)).toHaveCount(1);
  expect(await rows(H())).toEqual(expected);
  await expect(page.locator("#cancelBtn")).toBeVisible();
  await turnEnded(page, 1);
  expect(await rows("#history")).toEqual(expected);
  await page.reload();
  await turnEnded(page, 1);
  expect(await rows("#history")).toEqual(expected);
  // In the turn's order: the steered line and the card after its steps,
  // before its answer and its one timing line.
  const order = await page.locator("#history > *").evaluateAll((els) => els.map((e) =>
    e.matches(".bubble.user.steered") ? "steered" : e.matches(".bubble.user") ? "user" : e.matches(".turn-work") ? "block"
      : e.matches(".bubble.question") ? "card" : e.matches(".bubble.output") ? "answer" : e.matches(".turn-timing") ? "timing" : e.className));
  expect(order).toEqual(["user", "block", "card", "steered", "answer", "timing"]);
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

test("cancel mid-turn shows the canceled turn (its timing line too), and the next send works", { tag: "@turn" }, async ({ page, script }) => {
  script("hold");
  await send(page, "Take your time");
  await expect(page.locator("#cancelBtn")).toBeVisible();
  await page.locator("#cancelBtn").click();
  await expect(page.locator(`${H()} .bubble.cancel`)).toContainText("canceled");
  await expect(page.locator("#cancelBtn")).toBeHidden();
  // The timing line says so live, as a reload has it.
  await expect(page.locator(`${H()} .turn-timing`).first()).toHaveText(/^turn 1 · .+ · canceled$/);

  script("plain");
  await send(page, "Say pong");
  await expect(answer(page)).toHaveText("PONG from the fake model. It streams word by word. Then the turn ends.");
  await turnEnded(page, 2);
});

test("↑/↓ in the composer walk the prompt history and bring the draft back", async ({ page, script }) => {
  script("plain");
  // The workers' state is shared across scenarios: unique prompts, and
  // only their order is asserted.
  const tag = Date.now().toString(36);
  await send(page, `first ${tag}`);
  await turnEnded(page, 1);
  await send(page, `second ${tag}`);
  await turnEnded(page, 2);

  const prompt = page.locator("#prompt");
  await prompt.fill("my draft");
  await prompt.press("ArrowUp");
  await expect(prompt).toHaveValue(`second ${tag}`);
  await prompt.press("ArrowUp");
  await expect(prompt).toHaveValue(`first ${tag}`);
  await prompt.press("ArrowDown");
  await expect(prompt).toHaveValue(`second ${tag}`);
  await prompt.press("ArrowDown");
  await expect(prompt).toHaveValue("my draft");
});

test("a question card: the answer lets the turn go on", { tag: "@turn" }, async ({ page, script }) => {
  script("question");
  await send(page, "Read a file of my choice");
  const card = page.locator(`${H()} .bubble.question`);
  await expect(card.locator(".question-text")).toHaveText("Which file should I read?");
  // Its session card says it waits on the user (the hub's pending_question) until answered.
  await expect(page.locator("#topStrip .card.waiting .attn")).toHaveText("question");
  await card.locator(".question-option", { hasText: "README.md" }).click();
  await card.locator(".question-submit").click();
  await expect(card.locator(".question-result")).toContainText("README.md");
  await expect(page.locator("#topStrip .card.waiting")).toHaveCount(0);
  await expect(answer(page)).toHaveText("Read the file you picked. Done.");
  await turnEnded(page, 1);
  await expect(page.locator("#history .activity-tool")).toHaveText(["ask_user_question", "read"]);
});

test("an approval card: allowing it runs the tool", { tag: "@turn" }, async ({ page, script }) => {
  script("approval");
  await send(page, "Run the command that needs approval");
  const card = page.locator(`${H()} .bubble.question.approval`);
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

// The approval relay: a delegate's approval opens on the parent's page as
// the parent's own card; allowing it there runs the child's command, and the
// parent's model gets the outcome line with the reply.
test("a delegate's approval is answered on the parent's page", async ({ page, script }) => {
  script("delegate_relay");
  await send(page, "Delegate the command that needs approval");
  const card = page.locator(`${H()} .bubble.question.approval`);
  await expect(card.locator(".approval-delegate")).toContainText("E2E_CHILD_TASK");
  await expect(card.locator(".approval-what")).toHaveText(APPROVAL_COMMAND);
  await expect(card.locator("summary")).toContainText("Approve delegate");
  await card.locator(".question-option").first().click();
  await card.locator(".question-submit").click();
  await expect(card.locator(".question-result")).toContainText("Allowed: Allow once");
  await expect(answer(page)).toHaveText("The delegate is done.");
  await turnEnded(page, 1);
  const row = page.locator("#history .activity-row").filter({ hasText: "delegate" });
  await expect(row.locator(".activity-output")).toContainText(`approval relayed to your user: execute: ${APPROVAL_COMMAND} → allowed once`);
  await expect(row.locator(".activity-output")).toContainText("The child ran the approved command.");

  // The child's own page: the command ran there.
  await card.locator("summary").click();
  await card.locator(".approval-delegate a").click();
  await expect(page.locator("#history .bubble.user").first()).toContainText("E2E_CHILD_TASK");
  const childRow = page.locator("#history .activity-row").filter({ hasText: "execute" });
  await expect(childRow.locator(".activity-output")).toContainText("E2E_APPROVED");
});

test("an edit's approval card shows its diff; the row keeps the change after a reload", { tag: "@turn" }, async ({ page, script }) => {
  script("edit");
  await send(page, "Make the font bigger");
  const card = page.locator(`${H()} .bubble.question.approval`);
  await expect(card.locator(".approval-what")).toContainText(EDIT_ASK_FILE);
  await expect(card.locator(".approval-diff .diff-del")).toHaveText("-font_size 12");
  await expect(card.locator(".approval-diff .diff-add")).toHaveText("+font_size 14");
  await card.locator(".question-option").first().click();
  await card.locator(".question-submit").click();
  await expect(answer(page)).toHaveText("The font size is 14 now.");
  await turnEnded(page, 1);
  const editRow = () => page.locator("#history .activity-row").filter({ has: page.locator(".activity-tool", { hasText: /^edit$/ }) });
  const check = async () => {
    const diff = editRow().locator(".activity-diff");
    await expect(diff.locator("summary")).toHaveText("diff +1 \u22121");
    await expect(diff).not.toHaveAttribute("open", "");
    await diff.locator("summary").click({ force: true });
    await expect(diff.locator(".diff-add")).toHaveText("+font_size 14");
  };
  // The steps block is open after a live turn; a reload collapses it (and
  // so does the stage's hand-off).
  if (stage()) {
    await page.locator("#history .turn-work > summary").click();
    await page.locator("#history details.gen").nth(1).locator("> summary").click();
  }
  await check();
  await page.reload();
  await turnEnded(page, 1);
  await page.locator("#history .turn-work > summary").click();
  await page.locator("#history details.gen").nth(1).locator("> summary").click();
  await check();
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

test("the model picker lists the fake model", { tag: "@turn" }, async ({ page }) => {
  const button = page.locator("#modelPick");
  await expect(button).toBeVisible();
  await expect(button).toHaveText("fake-script");
  await button.click();
  await expect(page.locator("#modelList .model-option")).toHaveText(["fake-scriptdefault"]);
});

// ~40 models over two hosts, as an OpenRouter host lists them (its own
// order); fake-script is the real default so a create still succeeds.
const OPENROUTER_IDS = [
  "openai/gpt-5-nano", "deepseek/deepseek-v4.1-flash-lite", "~anthropic/claude-opus-latest",
  "deepseek/deepseek-v4.1", "qwen/qwen3.6-35b", "deepseek/deepseek-v4.1-flash", "mistral/codestral-flash",
  "anthropic/claude-sonnet-5.5", "google/gemini-3-flash", "meta/llama-5-70b",
  ...Array.from({ length: 28 }, (_, i) => `vendor${String.fromCharCode(97 + (i % 26))}/model-${i}`),
];
const MANY_MODELS = {
  default: "fake-script",
  models: [
    { name: "fake-script", host: "main", id: "fake-script" },
    { name: "gemma-4b", host: "main", id: "gemma-4b" },
    ...OPENROUTER_IDS.map((id) => ({ name: `openrouter:${id}`, host: "openrouter", id })),
  ],
};

test("the model picker searches: 'deepseek4.1 fla' picks the flash with ⏎, Recent keeps two picks, Esc changes nothing", { tag: "@turn" }, async ({ page, script }) => {
  await page.route("**/api/models", (route) => route.fulfill({ json: MANY_MODELS }));
  await page.reload();
  const button = page.locator("#modelPick");
  const panel = page.locator("#modelPanel");
  const search = page.locator("#modelSearch");
  const options = page.locator("#modelList .model-option");
  await expect(button).toHaveText("fake-script");

  await button.click();
  await expect(search).toBeFocused();
  await search.fill("deepseek4.1 fla");
  await expect(options.first()).toHaveText("openrouter · deepseek/deepseek-v4.1-flash");
  await expect(options.first()).toHaveClass(/active/);
  await expect(options.first().locator("mark")).toHaveText(["deepseek", "4.1", "fla"]);
  await search.press("Enter");
  await expect(panel).toBeHidden();
  await expect(button).toHaveText("openrouter:deepseek/deepseek-v4.1-flash");
  await expect(page.locator("#prompt")).toBeFocused();

  await button.click();
  await search.fill("fake");
  await search.press("Enter");
  await expect(button).toHaveText("fake-script");

  await page.reload();
  await expect(button).toHaveText("fake-script");
  await button.click();
  await expect(page.locator("#modelList .model-group").first()).toHaveText("Recent");
  await expect(options.nth(0)).toHaveText("fake-scriptdefault");
  await expect(options.nth(1)).toHaveText("openrouter · deepseek/deepseek-v4.1-flash");
  // The hosts follow, the default host first, ids A-Z inside a host.
  await expect(page.locator("#modelList .model-group")).toHaveText(["Recent", "main default host", "openrouter"]);
  await expect(options.nth(2)).toHaveText("fake-scriptdefault");
  await expect(options.nth(4)).toHaveText("~anthropic/claude-opus-latest");
  await expect(page.locator("#modelList .model-option.active")).toHaveText("fake-scriptdefault");

  await search.press("ArrowDown");
  await search.press("ArrowDown");
  await search.press("Escape");
  await expect(panel).toBeHidden();
  await expect(button).toHaveText("fake-script");
  await expect(button).toBeFocused();

  // A create sends the chosen model.
  script("plain");
  await page.locator("#prompt").fill("Say pong");
  const create = page.waitForRequest((r) => r.method() === "POST" && new URL(r.url()).pathname === "/api/sessions");
  await page.locator("#actionBtn").click();
  expect((await create).postDataJSON().model).toBe("fake-script");
  await expect(button).toBeHidden();
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
  const card = page.locator(`${H()} .bubble.question`);
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
  const card = page.locator(`${H()} .bubble.question`);
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
  const card = page.locator(`${H()} .bubble.question`);
  await expect(page).toHaveTitle(/^\(1\) Chi/);
  await page.evaluate(() => window.__showTab());
  await expect(page).not.toHaveTitle(/^\(/);
  await page.evaluate(() => window.__setFront(true));
  await card.locator(".question-option", { hasText: "README.md" }).click();
  await card.locator(".question-submit").click();
  await turnEnded(page, 1);
});

// Two chi tabs: the one in front tells the other (BroadcastChannel), which
// then neither notifies nor badges; alone behind, it would.
test("two tabs: one in front, the one behind shows no notification and no badge", async ({ page, script }) => {
  await withNotificationStub(page);
  const behind = await page.context().newPage();
  await behind.goto(page.url());
  await behind.addInitScript(() => {
    window.__heard = [];
    new BroadcastChannel("chi-notify").onmessage = (e) => window.__heard.push(...(e.data?.keys || []));
  });
  await withNotificationStub(behind);
  await behind.locator("#notifyBtn").click();
  await expect(behind.locator("#notifyBtn")).toHaveAttribute("data-state", "on");
  await page.evaluate(() => window.__setFront(true));

  script("question");
  await send(page, "Read a file of my choice");
  const card = page.locator(`${H()} .bubble.question`);
  await expect(card.locator(".question-text")).toHaveText("Which file should I read?");
  // The front tab's word reaches the tab behind (a listener of the test's
  // own on the channel); past its hold, it has neither notified nor badged.
  const qid = await card.getAttribute("data-qid");
  await expect.poll(() => behind.evaluate(() => window.__heard)).toContainEqual(expect.stringContaining(qid));
  await behind.waitForTimeout(600);
  expect(await notes(behind)).toEqual([]);
  await expect(behind).not.toHaveTitle(/^\(/);
  await card.locator(".question-option", { hasText: "README.md" }).click();
  await card.locator(".question-submit").click();
  await turnEnded(page, 1);
  await behind.close();
});

test("the title badge drops a question answered from another client", async ({ page, script }) => {
  await withNotificationStub(page);
  script("question");
  await send(page, "Read a file of my choice");
  const card = page.locator(`${H()} .bubble.question`);
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
  // Back in the composer, as for a later turn that fails.
  await expect(page.locator("#prompt")).toHaveValue("Say pong");
  await page.reload();
  await shown();
  await expect(page.locator("#history .hint")).toHaveCount(0);
});

// The /turn ack held back until the failed turn's prompt_restored has come
// over the stream. `landed` waits until the page handled the ack: its send
// handler focuses the composer last, so the composer is blurred first.
async function delayTurnAck(page) {
  let acked = false;
  await page.route(/\/api\/sessions\/[^/]+\/turn$/, async (route) => {
    const response = await route.fetch();
    await new Promise((resolve) => setTimeout(resolve, 1500));
    acked = true;
    await route.fulfill({ response });
  });
  return {
    landed: async () => {
      expect(acked, "the ack came after prompt_restored").toBe(false);
      await page.locator("#prompt").blur();
      await expect(page.locator("#prompt")).toBeFocused();
    },
  };
}

test("a failed first turn whose prompt_restored comes before the /turn ack puts its prompt back", async ({ page, fakeMode }) => {
  fakeMode("500");
  const ack = await delayTurnAck(page);
  await send(page, "Say pong");
  await expect(page.locator("#history .bubble.user.failed .user-message")).toHaveText("Say pong");
  await ack.landed();
  await expect(page.locator("#prompt")).toHaveValue("Say pong");
});

test("a failed later turn whose prompt_restored comes before the /turn ack puts its prompt back", async ({ page, script, fakeMode }) => {
  script("plain");
  await send(page, "Say pong");
  await turnEnded(page, 1);
  fakeMode("500");
  const ack = await delayTurnAck(page);
  await send(page, "Say ping");
  await expect(page.locator("#history .bubble.user.failed .user-message")).toHaveText("Say ping");
  await ack.landed();
  await expect(page.locator("#prompt")).toHaveValue("Say ping");
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
test("check-in: the card mid-turn, Nudge makes a nudge row before the answer, live and after a reload", { tag: "@turn" }, async ({ page, script }) => {
  script("check_in");
  await send(page, "Look through the README");
  const card = page.locator(`${HC()} > .plugin-card`).filter({ hasText: "3 tool calls, no answer yet" });
  await expect(card).toBeVisible();
  await card.locator(".card-action", { hasText: "Nudge" }).click();
  // The step that answers it shows it (open, live), before the answer (in
  // the stage: in its cloud, which the chip opens; the nudge flashes in the
  // trail meanwhile, so it is seen with the cloud closed).
  const row = page.locator(`${H()} .steer-row`);
  await expect(row.locator("summary")).toHaveText("check-in nudged the model");
  if (stage()) {
    const flashed = page.locator("#turnStage .ts-trail-item.steer");
    await expect(flashed).toHaveText("↪ check-in nudged the model");
    await expect(flashed).toBeVisible();
    await page.locator("#turnStage .ts-chip-label").click();
  }
  await expect(row).toBeVisible();
  await turnEnded(page, 1);
  await expect(answer(page)).toHaveText("Found so far: the README is an e2e project file. Nothing is left.");
  await expect(page.locator("#history .bubble.user")).toHaveCount(1);
  await expect(page.locator("#history .plugin-card .card-action")).toHaveCount(0);
  // The card is the echo: no "/checkin nudge" bubble.
  await expect(page.locator("#history .bubble.command")).toHaveCount(0);

  await page.reload();
  await turnEnded(page, 1);
  await expect(page.locator("#history .bubble.user")).toHaveCount(1);
  const reloaded = page.locator("#history .steer-row");
  await expect(reloaded).toHaveCount(1);
  await expect(reloaded.locator("summary")).toHaveText("check-in nudged the model");
  await expect(reloaded.locator(".steer-text")).toContainText("You've made 3 tool calls in this turn");
});

// loop-guard's thinking watch: the first generation's thinking goes round in
// a 3-sentence cycle (it would stream for ~11 s); loop-guard cuts it with a
// warn notice, the loop asks again (held 3 s), and the retry answers. The
// stage flashes the warn notice while the turn runs, both rows are in the
// DOM (inside the closed cloud); the turn view has them in the cut
// generation's step, closed once the retry's step opens.
test("thinking loop: loop-guard cuts it, asks again, answers", { tag: "@turn" }, async ({ page, script }) => {
  script("thinking_loop");
  const started = Date.now();
  await send(page, "How many r letters are in strawberry?");
  const rows = page.locator(`${H()} .hook-notice`);
  const cut = rows.filter({ hasText: "thinking repeats itself" });
  const again = rows.filter({ hasText: "↻ cut by loop-guard, asking again (1/1)" });
  if (stage()) {
    await expect(page.locator("#turnStage .ts-trail")).toContainText("thinking repeats itself");
  } else {
    // Both rows are the cut generation's: its step closes as the retry's opens.
    const steps = page.locator(`${H()} .turn-work .gen`);
    await expect(steps).toHaveCount(2);
    await expect(steps.first().locator(".hook-notice")).toHaveCount(2);
  }
  await expect(cut).toHaveCount(1);
  await expect(again).toHaveCount(1);
  await expect(cut).toContainText("(3 sentences ×3");
  await expect(page.locator("#cancelBtn")).toBeVisible();
  await expect(answer(page)).toHaveText("PONG after the cut.");
  await turnEnded(page, 1);
  // Well before the loop's own end (~11 s of streaming, then the 3 s hold).
  expect(Date.now() - started).toBeLessThan(9000);
});

// A warn card in a step (here the e2e-warn-card test bundle's, at the first
// step's read) stays in sight when that step closes mid-turn: it leaves the
// collapsing step for the block, and after the turn ends it is under the
// block, where a reload puts it, also once the session is stopped.
test("a warn card stays in sight when its step closes mid-turn", { tag: "@turn" }, async ({ page, script }) => {
  script("warn_card");
  await send(page, "Read the flagged file");
  const card = page.locator(`${H()} .plugin-card.warn`).filter({ hasText: "e2e warn card" });
  await expect(card).toHaveCount(1);
  // The next step started: the card's step is closed, the turn still runs
  // (the last step holds 4 s before it answers). In the stage the card sits
  // in the extras, not in its step inside the closed cloud.
  if (stage()) {
    await expect(page.locator("#turnStage .ts-trail")).toContainText("read README.md");
    await expect(page.locator("#turnStage .ts-extras > .plugin-card.warn")).toHaveCount(1);
  } else {
    const steps = page.locator(`${H()} .turn-work .gen`);
    await expect(steps.nth(1).locator(".activity-row")).toHaveCount(1);
    await expect(steps.first()).not.toHaveAttribute("open", "");
  }
  await expect(card).toBeVisible({ timeout: 1000 });
  // Still running: Cancel is up, no final timing line yet.
  await expect(page.locator("#cancelBtn")).toBeVisible({ timeout: 1000 });
  await expect(page.locator("#history .turn-timing:not(.live)")).toHaveCount(0);
  await turnEnded(page, 1);
  await expect(card).toBeVisible();
  await expect(page.locator("#history > .plugin-card.warn")).toHaveCount(1);
  // The worker saved it with the session: stopped, a reload still shows it.
  page.once("dialog", (dialog) => dialog.accept());
  const stopped = page.waitForResponse((res) => /\/stop$/.test(res.url()) && res.request().method() === "POST");
  await page.locator("#infoStopBtn").click();
  expect((await stopped).ok()).toBe(true);
  await page.reload();
  await expect(page.locator("#history .bubble.user")).toHaveCount(1);
  await expect(page.locator("#history > .plugin-card.warn").filter({ hasText: "e2e warn card" })).toHaveCount(1);
});

// A check-in card asks the user as a question does: a tab behind shows one
// "needs you" notification and a badge; resolving the card (here from
// another client, the tab untouched) drops the badge while the turn runs.
test("check-in in a background tab: one 'needs you' notification; the card resolved drops the badge", async ({ page, script }) => {
  await withNotificationStub(page);
  await page.locator("#notifyBtn").click();
  await expect(page.locator("#notifyBtn")).toHaveAttribute("data-state", "on");

  script("check_in");
  await send(page, "Look through the README");
  const card = page.locator(`${HC()} > .plugin-card`).filter({ hasText: "3 tool calls, no answer yet" });
  await expect(card).toBeVisible();
  await expect.poll(() => notes(page)).toEqual([
    expect.objectContaining({ title: "Look through the README", body: "needs you", tag: expect.stringMatching(/:card:check-in-/) }),
  ]);
  await expect(page).toHaveTitle(/^\(1\) Chi/);

  const id = page.url().match(/#\/s\/([0-9a-f-]+)$/)[1];
  const res = await page.request.post(new URL(`/api/sessions/${id}/command`, page.url()).href, { data: { line: "/checkin later" } });
  expect(res.ok()).toBe(true);
  await expect(page.locator(`${H()} .plugin-card .card-action`)).toHaveCount(0);
  await expect(page).not.toHaveTitle(/^\(/);
  await expect(page.locator("#cancelBtn")).toBeVisible();
  await turnEnded(page, 1);
  expect(await notes(page)).toHaveLength(1);
});

// A 1×1 PNG: an image prompt runs as its own next turn (steering merges
// text only), so B queues behind A.
const PNG_1PX = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

// A's turn-end re-read (?tail=1) lands after B started: B keeps its own
// live line ("turn 2", ticking), A's line and answer are A's, and a reload
// draws the same two lines.
test("a queued turn keeps its own live timing line when the turn before it re-reads late", { tag: "@turn" }, async ({ page, script }) => {
  script("queued");
  let release;
  const released = new Promise((resolve) => { release = resolve; });
  let held = 0;
  await page.route(/\/api\/sessions\/[^/?]+\?tail=1/, async (route) => {
    if (held++ > 0) return route.continue();
    const response = await route.fetch();
    await released;
    await route.fulfill({ response });
  });
  await send(page, "Say first");
  await expect(page.locator(`${H()} .turn-timing.live`)).toHaveText(/^turn 1 running · /);
  // B: an image dropped into the composer, sent while A runs.
  await page.evaluate((b64) => {
    const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    const dt = new DataTransfer();
    dt.items.add(new File([bytes], "dot.png", { type: "image/png" }));
    document.querySelector("#composer").dispatchEvent(new DragEvent("drop", { dataTransfer: dt, bubbles: true, cancelable: true }));
  }, PNG_1PX);
  await expect(page.locator("#chips .chip")).toHaveCount(1);
  await send(page, "QUEUED-B what is in this image?");
  // B started (its live line is there, A's finished) while A's re-read is held.
  const lines = page.locator(`${H()} .turn-timing`);
  const live = page.locator(`${H()} .turn-timing.live`);
  await expect(lines).toHaveCount(2);
  await expect(live).toHaveCount(1);
  release();
  // A's re-read landed: its answer is the rendered markdown.
  await expect(page.locator(`${H()} .bubble.output strong`)).toHaveText("bold");
  await expect(live).toHaveCount(1);
  await expect(live).toHaveText(/^turn 2 running · /);
  await expect(lines.first()).toHaveText(/^turn 1 · /);
  const before = await live.textContent();
  await expect.poll(() => live.textContent(), { timeout: 3000 }).not.toBe(before);
  await expect(live).toHaveText(/^turn 2 running · /);
  // B ends: its own line, final.
  await expect(page.locator(`${H()} .bubble.output`).last()).toHaveText("Second answer, from the queued turn.", { timeout: 15_000 });
  await turnEnded(page, 2);
  const final = await page.locator("#history .turn-timing").allTextContents();
  expect(final).toHaveLength(2);
  expect(final[0]).toMatch(/^turn 1 · /);
  expect(final[1]).toMatch(/^turn 2 · /);
  await page.reload();
  await turnEnded(page, 2);
  const reloaded = await page.locator("#history .turn-timing").allTextContents();
  expect(reloaded).toHaveLength(2);
  expect(reloaded[0]).toMatch(/^turn 1 · /);
  expect(reloaded[1]).toMatch(/^turn 2 · /);
});
