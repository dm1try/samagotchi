// Happy paths of the web UI against a scripted fake model (support/scripts).
// Assertions are on page state only; every wait is on the DOM, no sleeps.
import { test, expect } from "./support/fixtures.js";
import { PROMPT_LINE_PX } from "../../lib/samagotchi/web/public/composer_size.js";
import { expectNoHorizontalOverflow } from "./support/layout.js";
import { APPROVAL_COMMAND, EDIT_ASK_FILE, seedDelegate, seedFamily, useModelNote } from "./support/env.js";
import { momentAt, pageNow, shiftSum, snaps, stageMarks, startSnaps, watchShifts, watchStage } from "./support/shifts.js";

// The stage: a running turn's rows are in #turnStage until the hand-off
// moves them into #history. H is where a live row can be; HC the
// containers a card sits directly in.
const H = ":is(#history, #turnStage)";
// The live timing line: "turn N · …" in the stage's status row (which
// already says the turn runs).
const LIVE_LINE = (n) => new RegExp(`^turn ${n} · `);
const HC = ":is(#history, #turnStage .ts-extras, #turnStage .ts-tail, #turnStage .ts-queued)";

// Types into the composer and sends (Start on the start page, Send in a session).
async function send(page, prompt) {
  await page.locator("#prompt").fill(prompt);
  await page.locator("#actionBtn").click();
  // Contains, not equals: a fast failure adds its "failed" badge to the
  // bubble's text before this check runs.
  await expect(page.locator(`${H} .bubble.user`).last()).toContainText(prompt);
}

// The turn is over: its timing line is final, Cancel is gone, Send is enabled.
// Handed off into the history too (the pointer leaves the stage first: a
// click in it holds the hand-off, as it would a reader).
async function turnEnded(page, turns) {
  await page.mouse.move(0, 0);
  await expect(page.locator("#history .turn-timing:not(.live)")).toHaveCount(turns);
  await expect(page.locator("#turnStage .ts-cancel")).toBeHidden();
  await expect(page.locator("#actionBtn")).toHaveText("Send");
  await expect(page.locator("#actionBtn")).toBeEnabled();
  await expect(page.locator("#prompt")).toBeEditable();
}

const answer = (page) => page.locator(`${H} .bubble.output`).last();

test("a prompt from the start page streams an answer and the turn ends", async ({ page, script }) => {
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
  // Revise (revise_stack.js): the answer's Revise arms the composer's chip;
  // the next message rewrites it, and once that turn completed (the server's
  // stamp) the first version folds to a stub and the new answer has the
  // version chip, live and after a reload.
  await answer(page).hover();
  await page.locator("#history .revise-btn").click();
  await expect(page.locator("#reviseChip .revise-chip")).toContainText("Revising: PONG from the fake model.");
  await send(page, "Shorter");
  await expect(page.locator("#reviseChip")).toBeHidden();
  await turnEnded(page, 2);
  const stacked = async () => {
    const stub = page.locator("#history .stack-stub");
    await expect(stub).toHaveCount(1);
    await expect(stub).toContainText(/^v1 · “PONG from the fake model\. .*” · 1 line — superseded by v2/);
    await expect(page.locator("#history .bubble.output:visible")).toHaveCount(1);
    await expect(page.locator("#history .bubble.user:visible")).toHaveText(["Shorter"]);
    await expect(page.locator("#history .stack-versions > summary")).toHaveText("v2 · 1 earlier");
  };
  await stacked();
  await page.reload();
  await turnEnded(page, 2);
  await stacked();
  // The ‹ › switcher (revise_switch.js): v1's answer read in the top's
  // place (the keyboard's Enter), its copy dashed; › back to the latest.
  const switcher = page.locator("#history .stack-switch");
  await expect(switcher.locator(".stack-switch-sr")).toHaveText("version 2 of 2");
  await switcher.getByRole("button", { name: "Previous version" }).focus();
  await page.keyboard.press("Enter");
  await expect(switcher.locator(".stack-switch-sr")).toHaveText("version 1 of 2");
  await expect(page.locator("#history .bubble.output:visible")).toHaveCount(1);
  await expect(page.locator("#history .bubble.output.stack-view")).toBeVisible();
  await expect(page.locator("#history .bubble.output.stack-view")).toHaveAttribute("data-copy-source", /^PONG from the fake model\./);
  await switcher.getByRole("button", { name: "Next version" }).click();
  await expect(page.locator("#history .stack-view")).toHaveCount(0);
  await expect(switcher.locator(".stack-switch-sr")).toHaveText("version 2 of 2");
  // Unfolded from its stub: the first version is back in place.
  await page.locator("#history .stack-stub").click();
  await expect(page.locator("#history .bubble.output:visible")).toHaveCount(2);
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
  // The model's description is the row's title; the command is its hover.
  await expect(rows.nth(0).locator(".activity-params")).toHaveText("See that the shell answers");
  await expect(rows.nth(0).locator(".activity-params")).toHaveAttribute("title", "true");
  await expect(rows.nth(0).locator(".activity-status")).toHaveAttribute("aria-label", "done");
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
  // The copy button is added by an observer after the answer renders:
  // compare the answers once each has it.
  const copied = () => expect(answer(page).locator(":scope > .copy-btn")).toHaveCount(1);
  await copied();
  const before = {
    user: await page.locator("#history .bubble.user").allTextContents(),
    summary: await page.locator("#history .turn-work > summary").allTextContents(),
    tools: await page.locator("#history .activity-tool").allTextContents(),
    titles: await page.locator("#history .activity-params").allTextContents(),
    answer: await answer(page).innerHTML(),
  };
  await page.reload();
  await turnEnded(page, 1);
  await expect(page.locator("#history .bubble.user")).toHaveText(before.user);
  await expect(page.locator("#history .turn-work > summary")).toHaveText(before.summary);
  await expect(page.locator("#history .activity-tool")).toHaveText(before.tools);
  await expect(page.locator("#history .activity-params")).toHaveText(before.titles);
  expect(before.titles[0]).toBe("See that the shell answers");
  await copied();
  expect(await answer(page).innerHTML()).toBe(before.answer);
  // Nothing streams after the turn: the meter and the card read the saved
  // context (its rules: ctx.test.js).
  await expect(page.locator("#infoBar .meta")).toContainText(/ctx ~?\d+%/);
  await expect(page.locator("#topStrip .card .ctx").first()).toHaveText(/^\d+%$/);
});

// The first generation has thinking only: the loop asks again in the same
// turn, the empty step says so, and a reload shows one turn with the answer
// and the asking-again row (the empty step isn't saved: a row before the
// answer).
test("an empty answer is asked again in the same turn, and a reload shows one turn with its retry row", async ({ page, script }) => {
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

// The retry is empty too: the turn ends with no answer. The stage's status
// row reads "no answer", not "answered" (held there by the pointer), then
// one muted notice where the answer goes (no answer bubble), live and after
// a reload, which keeps both empty steps and the retry row in them.
test("a turn with no answer ends in the stage as no answer, then one notice, live and after a reload, with its steps", async ({ page, script }) => {
  script("empty_answer");
  await send(page, "Say pong");
  await page.locator("#turnStage").hover();
  await expect(page.locator("#turnStage")).toHaveAttribute("data-phase", "no answer");
  await expect(page.locator("#turnStage .ts-phase")).toHaveText("no answer");
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
test("a reload mid-turn and after it keeps the retry row, the answered card and the steered line in the turn", async ({ page, script }) => {
  script("reload_rows");
  await send(page, "Read a file of my choice");
  const card = page.locator(`${H} .bubble.question`);
  await expect(card).toHaveCount(1);
  await card.locator(".question-option input").first().check();
  await card.locator(".question-submit").click();
  await expect(page.locator(`${H} .bubble.question.answered`)).toHaveCount(1);
  // Sent while the read holds: merged into this turn after it.
  await page.locator("#prompt").fill("mind the typos");
  await page.locator("#actionBtn").click();
  await expect(page.locator(`${H} .bubble.user.steered`)).toHaveCount(1);
  await expect(page.locator(`${H} .activity-row`).filter({ hasText: "README.md" }).last().locator(".activity-status.ok")).toHaveCount(1);

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
  await expect(page.locator(`${H} .bubble.question.answered`)).toHaveCount(1);
  expect(await rows(H)).toEqual(expected);
  await expect(page.locator("#turnStage .ts-cancel")).toBeVisible();
  await turnEnded(page, 1);
  expect(await rows("#history")).toEqual(expected);
  await page.reload();
  await turnEnded(page, 1);
  expect(await rows("#history")).toEqual(expected);
  // In the turn's order: the steered line and the card after its steps
  // (the working set's footprint right under them), before its
  // answer and its one timing line (the answer's Revise row aside).
  const order = await page.locator("#history > :not(.revise-row)").evaluateAll((els) => els.map((e) =>
    e.matches(".bubble.user.steered") ? "steered" : e.matches(".bubble.user") ? "user" : e.matches(".turn-work") ? "block"
      : e.matches(".bubble.question") ? "card" : e.matches(".bubble.output") ? "answer" : e.matches(".turn-timing") ? "timing" : e.className));
  expect(order).toEqual(["user", "block", "ws-foot", "card", "steered", "answer", "timing"]);
});

// LLM context edits (llm_context.strategy stale, apply next_request): the
// second read of a file stubs the first from the next request, a ✂ row of
// the step that read it again, live and after a reload; the reload also
// marks the first read's row with what the model is sent instead.
test("a stale read's stub shows as a ✂ row live and after a reload, and a reload marks the stubbed read", async ({ page, script, configExtra, projectFile }) => {
  projectFile("e2e-notes.txt",
    Array.from({ length: 40 }, (_, i) => `${i + 1}: a note line long enough to be worth a stub`).join("\n") + "\n");
  configExtra("llm_context:\n  strategy: [stale]\n  apply: next_request\n");
  script("llm_context");
  await send(page, "Read the notes twice");
  const LINE = /^✂ stubbed 1 stale read · frees ~\d+ tokens$/;
  // The answer holds: the row is in, before it.
  const live = page.locator(`${H} .hook-notice.llm-context`);
  await expect(live).toHaveCount(1);
  await expect(live).toHaveText(LINE);
  await expect(live).toHaveAttribute("title", /^Stubbed as stale:\n {2}t1 read e2e-notes\.txt — e2e-notes\.txt: superseded by a later read\n/);
  await turnEnded(page, 1);

  await page.reload();
  await turnEnded(page, 1);
  const work = page.locator("#history .turn-work.done");
  await expect(work.locator(".gen").nth(1).locator(".activity-body > .hook-notice.llm-context")).toHaveText(LINE);
  await expect(page.locator("#history .hook-notice.llm-context")).toHaveCount(1);
  const rows = work.locator(".activity-row");
  await expect(rows).toHaveCount(2);
  await expect(rows.nth(0).locator(".activity-edit")).toHaveText(/^✂ stubbed: superseded by a later read · ~\d+ tokens$/);
  await expect(rows.nth(0).locator(".activity-edit")).toHaveAttribute("title", /^t1: ✂ stubbed/);
  await expect(rows.nth(1).locator(".activity-edit")).toHaveCount(0);
});

// A price under hosts.<name>.models: the fake reports usage without
// usage.cost, so the info bar's ctx tooltip shows the estimate with "~".
test("a configured price estimates the cost the provider doesn't report: ~$ in the info bar's ctx tooltip", async ({ page, script, hostModels }) => {
  hostModels("fake-script:\n  price: {input: 1000, output: 2000}\n");
  script("plain");
  await send(page, "Say pong");
  await turnEnded(page, 1);
  await expect(page.locator("#infoBar .meta .ctx")).toHaveAttribute("title", /\ncost: ~\$\d+\.\d{2} \(estimated\)\n/);
});

test("a session whose prompt carried a model note names it in the info bar", async ({ page, script, chi }) => {
  script("plain");
  useModelNote(chi, "e2e", "Keep answers short.");
  try {
    await send(page, "Say pong");
    await turnEnded(page, 1);
    // The turn-end re-read brings them (the first turn's build recorded them).
    const chip = page.locator("#infoBar .meta .notes-chip");
    await expect(chip).toHaveText("notes: e2e");
    await expect(chip).toHaveAttribute("title", "model notes in this session's prompt: model_notes_e2e (system, 19 chars)");
    // And a reload: the live worker's snapshot.
    await page.reload();
    await turnEnded(page, 1);
    await expect(chip).toHaveText("notes: e2e");
  } finally {
    useModelNote(chi, "e2e", null);
  }
});

test("cancel mid-turn shows the canceled turn (its timing line too), and the next send works", async ({ page, script }) => {
  script("hold");
  await send(page, "Take your time");
  await expect(page.locator("#turnStage .ts-cancel")).toBeVisible();
  await page.locator("#turnStage .ts-cancel").click();
  await expect(page.locator(`${H} .bubble.cancel`)).toContainText("canceled");
  await expect(page.locator("#turnStage .ts-cancel")).toBeHidden();
  // The timing line says so live, as a reload has it.
  await expect(page.locator(`${H} .turn-timing`).first()).toHaveText(/^turn 1 · .+ · canceled$/);

  script("plain");
  await send(page, "Say pong");
  await expect(answer(page)).toHaveText("PONG from the fake model. It streams word by word. Then the turn ends.");
  await turnEnded(page, 2);
});

test("a question card: the answer lets the turn go on", async ({ page, script }) => {
  script("question");
  await send(page, "Read a file of my choice");
  const card = page.locator(`${H} .bubble.question`);
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
  // The answered card keeps the reply that asked it, under its "Q → A" line, as plain text (no
  // "##", its heading set off by " · "); after a reload too.
  const said = page.locator("#history .bubble.question .question-said");
  await expect(said).toContainText("Two files · I can start from either file: README.md describes the project");
  await page.reload();
  await expect(page.locator("#history .bubble.question summary")).toContainText("Which file should I read? → README.md");
  await expect(said).toContainText("I can start from either file: README.md describes the project");
  // Opened, the whole reply is in the card's body (selectable), not in its summary.
  await page.locator("#history .bubble.question summary").click();
  await expect(said).toBeHidden();
  // With web.markdown on, rendered at that first open: its heading, its link in a new tab.
  const full = page.locator("#history .bubble.question .question-said-full");
  await expect(full.locator("h2")).toHaveText("Two files");
  await expect(full).toHaveText(
    "Two files I can start from either file: README.md describes the project and Gemfile lists its gems. JIRA-7 asks different questions (why).");
  await expect(full.locator('a[target="_blank"]')).toHaveAttribute("href", "https://example.com/files");
  // A plugin's ref on that reply (e2e-answer-refs, :question_asked): paired in the card's body and on the
  // step's text in the history (the reload's), its action in the ref's menu.
  await expect(full.locator('[data-ref-kind="issue"]')).toHaveText("JIRA-7");
  const stepRef = page.locator("#history .gen > .gen-text [data-ref-kind=\"issue\"]");
  await expect(stepRef).toHaveText("JIRA-7");
  // Its one action: a click opens it in a new tab.
  await page.evaluate(() => {
    window.__opened = [];
    window.open = (...args) => { window.__opened.push(args); return null; };
  });
  await full.locator('[data-ref-kind="issue"]').click();
  expect(await page.evaluate(() => window.__opened)).toEqual([["https://example.test/JIRA-7", "_blank", "noopener,noreferrer"]]);
});

// The step limit asks as a question (kind continue) between turns: its card,
// the session card's badge, a reload, and Continue running the turn on.
// Stop and its reason are unit specs (question_cards.test.js, worker_spec).
test("a turn at its step limit asks to continue: the card survives a reload, Continue finishes the turn", async ({ page, script, turnLimit }) => {
  script("step_limit");
  turnLimit(3);
  await send(page, "Do a long task");
  const card = page.locator(`${HC} .bubble.question.step-limit`);
  await expect(card.locator(".question-text")).toContainText("The turn ran out of iterations (3 steps) before it answered. Continue it?");
  await expect(card.locator(".question-choice")).toHaveText(["Continue", "Stop"]);
  await expect(card.locator(".question-dismiss")).toHaveCount(0);
  // The old continue card isn't drawn beside it.
  await expect(page.locator(".bubble.continue")).toHaveCount(0);
  await expect(page.locator("#topStrip .card.waiting .attn")).toHaveText("out of steps");

  await page.reload();
  await expect(card).toHaveCount(1);
  await expect(page.locator(".bubble.continue")).toHaveCount(0);

  await card.locator(".continue-yes").click();
  await expect(answer(page)).toHaveText("Finished after the continue: STEP-LIMIT-DONE");
  await expect(page.locator(`${H} .bubble.question.step-limit .question-result`)).toHaveText("Continued");
  await expect(page.locator("#topStrip .card.waiting")).toHaveCount(0);
});

test("an approval card: allowing it runs the tool", async ({ page, script }) => {
  script("approval");
  await watchShifts(page);
  await watchStage(page);
  await startSnaps(page);
  await send(page, "Run the command that needs approval");
  const card = page.locator(`${H} .bubble.question.approval`);
  await expect(card.locator(".approval-what")).toHaveText(APPROVAL_COMMAND);
  await expect(card.locator(".approval-why")).toContainText("e2e-ask");
  // The stage shows the reply that asked for it above the card.
  await expect(page.locator("#turnStage .ts-asking")).toHaveText("Running the command that needs approval.");
  // The plain flip: the first words stream as the answer, then the tool
  // starts; the stage holds its height and nothing in it moves. (The
  // composer card settles into a new session's layout meanwhile.)
  const marks = await stageMarks(page);
  const shownAt = momentAt(marks, (m) => !m.hidden);
  // (A fast stream can start the tool in the first words' frame.)
  const plainAt = momentAt(marks, (m) => /\bplain\b/.test(m.cls)) ?? shownAt;
  const waitingAt = momentAt(marks, (m) => /\bwaiting\b/.test(m.cls));
  expect(plainAt).toBeLessThan(waitingAt);
  expect(await shiftSum(page, { from: plainAt, to: waitingAt, where: "stage", withInput: true })).toBeLessThan(0.01);
  // The card's arrival grows the stage once, with a short ease: read once
  // that window has passed and the growth is over, so the answer below
  // comes after it (a starved page can still be growing when the card
  // shows, and the growth would count as the answer's shift).
  await page.waitForFunction((until) => performance.now() >= until && document.querySelector("#turnStage").getAnimations().length === 0, waitingAt + 600);
  expect(await shiftSum(page, { from: waitingAt, to: waitingAt + 600, withInput: true })).toBeLessThan(0.15);
  expect(await snaps(page, { from: waitingAt, to: waitingAt + 600 })).toEqual([]);
  // Answered from the keyboard: the card took the focus from the empty
  // composer; pick the first option and press Enter.
  const first = card.locator(".question-option input").first();
  await expect(first).toBeFocused();
  await first.check();
  const answerAt = await pageNow(page);
  await first.press("Enter");
  await expect(card.locator(".question-result")).toContainText("Allow");
  await expect(answer(page)).toHaveText("The approved command ran.");
  // The answer: the stage keeps its height and nothing in it shifts. This
  // card is taller than its room (its options in sight, its top scrolled
  // out), so it can't keep its top: its line comes into the stage's view
  // (the focus may scroll the stage to it). The question test has a card
  // that keeps it.
  const endAt = momentAt(await stageMarks(page), (m) => /\bended\b/.test(m.cls), answerAt);
  expect(await shiftSum(page, { from: answerAt, to: endAt, withInput: true })).toBeLessThan(0.01);
  expect(await snaps(page, { from: answerAt, to: endAt, keys: ["status", "chip", "composer"] })).toEqual([]);
  const line = await card.locator("summary").boundingBox();
  const view = await page.locator("#turnStage .ts-scroll").boundingBox();
  expect(line.y).toBeGreaterThanOrEqual(view.y);
  expect(line.y + line.height).toBeLessThanOrEqual(view.y + view.height);
  await turnEnded(page, 1);
  const row = page.locator("#history .activity-row").filter({ hasText: "execute" });
  await expect(row.locator(".activity-status")).toHaveAttribute("aria-label", "done");
  await expect(row.locator(".activity-output")).toContainText("E2E_APPROVED");
});

// The approval relay: a delegate's approval opens on the parent's page as
// the parent's own card; allowing it there runs the child's command, and the
// parent's model gets the outcome line with the reply.
test("a delegate's approval is answered on the parent's page", async ({ page, script }) => {
  script("delegate_relay");
  await send(page, "Delegate the command that needs approval");
  const card = page.locator(`${H} .bubble.question.approval`);
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

test("an edit's approval card shows its diff; the row keeps the change after a reload", async ({ page, script }) => {
  script("edit");
  await send(page, "Make the font bigger");
  const card = page.locator(`${H} .bubble.question.approval`);
  await expect(card.locator(".approval-what")).toContainText(EDIT_ASK_FILE);
  await expect(card.locator(".approval-diff .diff-del")).toHaveText("-font_size 12");
  await expect(card.locator(".approval-diff .diff-add")).toHaveText("+font_size 14");
  await card.locator(".question-option").first().click();
  await card.locator(".question-submit").click();
  await expect(answer(page)).toHaveText("The font size is 14 now: e2e-settings.conf:1.");
  await turnEnded(page, 1);
  const editRow = () => page.locator("#history .activity-row").filter({ has: page.locator(".activity-tool", { hasText: /^edit$/ }) });
  const check = async () => {
    const diff = editRow().locator(".activity-diff");
    await expect(diff.locator("summary")).toHaveText("diff +1 \u22121");
    await expect(diff).not.toHaveAttribute("open", "");
    await diff.locator("summary").click({ force: true });
    await expect(diff.locator(".diff-add")).toHaveText("+font_size 14");
  };
  // The steps block is its outline (the write's step said something), open
  // live and after a reload; the edit's step (tool-only) is behind its fold.
  const openEditStep = async () => {
    await page.locator("#history .turn-work.outline[open] > .outline-fold").click();
    await page.locator("#history .turn-work > details.gen").nth(1).locator("> summary").click();
  };
  await openEditStep();
  await check();
  await page.reload();
  await turnEnded(page, 1);
  await openEditStep();
  await check();
});

// Refs: a file row's title, its diff lines and a ref in the answer open
// the file in the editor (web.editor's default, vscode; this page is a
// loopback viewer); the answer's ref's menu shows the row in the turn. The window.__chiRefOpen seam records the URL instead
// of opening it; refs.js checks for it at click time.
test("an edit's approval card, then its row's title and diff lines, open the file in the editor; the answer's ref shows its row; live and after a reload", async ({ page, script }) => {
  const recordOpens = () => page.evaluate(() => {
    window.__refOpened = [];
    window.__chiRefOpen = (url) => window.__refOpened.push(url);
  });
  const opened = () => page.evaluate(() => window.__refOpened.splice(0));
  const url = (line) => new RegExp(`^vscode://file/.+/${EDIT_ASK_FILE.replace(".", "\\.")}:${line}$`);
  script("edit");
  await send(page, "Make the font bigger");
  const card = page.locator(`${HC} .bubble.question.approval`);
  // Before approving: the card's path opens the current file at the dry
  // run's first change, a diff line at its own.
  await recordOpens();
  const path = card.locator(".approval-what .ref");
  await expect(path).toHaveAttribute("data-ref-kind", "file");
  await path.click();
  await card.locator(".approval-diff .diff-ctx").filter({ hasText: "theme dark" }).click();
  expect(await opened()).toEqual([expect.stringMatching(url(1)), expect.stringMatching(url(2))]);
  await card.locator(".question-option").first().click();
  await card.locator(".question-submit").click();
  await expect(answer(page)).toHaveText("The font size is 14 now: e2e-settings.conf:1.");
  await turnEnded(page, 1);
  await expect(page.locator("body")).toHaveClass(/\bhas-editor\b/);

  const editRow = () => page.locator(`${H} .activity-row`).filter({ has: page.locator(".activity-tool", { hasText: /^edit$/ }) });
  const check = async () => {
    await recordOpens();
    const title = editRow().locator(".activity-params.ref");
    await expect(title).toHaveAttribute("data-ref-kind", "file");
    // The edit named no line: its title opens at the first changed line.
    await title.click();
    const diff = editRow().locator(".activity-diff");
    await diff.locator("summary").click({ force: true });
    await diff.locator(".diff-add").click();
    await diff.locator(".diff-ctx").filter({ hasText: "theme dark" }).click();
    // The answer's `path:line` and the step's bare path name the touched
    // file (ref_scan.js): refs too.
    await expect(page.locator(`${H} details.gen .gen-text .ref`)).toHaveText(EDIT_ASK_FILE);
    await answer(page).locator(".ref").click();
    expect(await opened()).toEqual([expect.stringMatching(url(1)), expect.stringMatching(url(1)), expect.stringMatching(url(2)), expect.stringMatching(url(1))]);
    // The ref's menu (its ▾): "Show in turn" opens the steps and the
    // edit's diff, scrolls to the line and flashes the row.
    // The edit's step is tool-only: folded in the outline, so the row is
    // hidden until the reveal unfolds it.
    await page.evaluate(() => {
      for (const details of document.querySelectorAll("#history .turn-work, #history .activity-diff")) details.open = false;
      for (const fold of document.querySelectorAll("#history .outline-fold.open")) fold.click();
    });
    expect(await editRow().evaluate((el) => el.checkVisibility())).toBe(false);
    await answer(page).locator(".ref").hover();
    await page.locator(".ref-more").click();
    await expect(page.getByRole("menuitem")).toHaveText(["Open in editor", "Show in turn", "Copy path"]);
    await page.getByRole("menuitem", { name: "Show in turn" }).click();
    await expect(page.locator(".ref-menu")).toHaveCount(0);
    await expect(page.locator("#history .turn-work")).toHaveJSProperty("open", true);
    await expect(editRow().locator(".activity-diff")).toHaveJSProperty("open", true);
    await expect(editRow()).toHaveClass(/\bref-flash\b/);
    expect(await editRow().evaluate((el) => el.checkVisibility())).toBe(true);
    await expect(editRow().locator('.diff-add[data-line="1"]')).toBeInViewport();
    expect(await opened()).toEqual([]);
  };
  // The steps block, the edit's fold and its step, opened when they are closed.
  const openSteps = async () => {
    const block = page.locator("#history .turn-work");
    if (!(await block.evaluate((el) => el.open))) await block.locator("> summary").click();
    const fold = block.locator("> .outline-fold");
    if (!(await fold.evaluate((el) => el.classList.contains("open")))) await fold.click();
    const step = block.locator("> details.gen").nth(1);
    if (!(await step.evaluate((el) => el.open))) await step.locator("> summary").click();
  };
  await openSteps();
  await check();
  await page.reload();
  await turnEnded(page, 1);
  await openSteps();
  await check();
});

// Annotate presets: a pill quotes the selection with its text as the note
// into the composer and sends nothing. The selection is set with a Range
// (a mouse drag is the same selectionchange, less exact). A plugin's pill
// (e2e-annotation's chi.annotation) fills its command line and the quote;
// Send runs that command with the note. Verify, last, runs its check.
test("an annotate preset fills the composer with the quote and never sends; a plugin's pill prepares its command; Verify on an answer gets a verdict card, and a Revise of that answer stacks it under the card", async ({ page, script }) => {
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
  await expect(bar.locator("button")).toHaveText(["Annotate", "Agreed", "Could you please elaborate?", "Verify", "E2E check", "Copy link"]);
  await bar.getByRole("button", { name: "Agreed" }).click();
  await expect(page.locator("#prompt")).toHaveValue("> PONG from the fake model.\n\nAgreed");
  await expect(bar).toBeHidden();
  await expect(page.locator("#prompt")).toBeFocused();
  await expect(page.locator("#history .bubble.user")).toHaveCount(1);
  expect(turnPosts).toEqual([]);

  // The plain Annotate quote ends in a blank line, and sent as it is the
  // message (trimmed) still clears the composer.
  await page.locator("#prompt").fill("");
  await page.evaluate(() => {
    const text = [...document.querySelectorAll("#history .bubble.output")].pop().querySelector("p").firstChild;
    const range = document.createRange();
    range.setStart(text, 0);
    range.setEnd(text, "PONG from the fake model.".length);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  });
  await bar.getByRole("button", { name: "Annotate" }).click();
  await expect(page.locator("#prompt")).toHaveValue("> PONG from the fake model.\n\n");
  await page.locator("#actionBtn").click();
  await expect(page.locator(`${H} .bubble.user`).last()).toHaveAttribute("data-user-content", "> PONG from the fake model.");
  await turnEnded(page, 2);
  await expect(page.locator("#prompt")).toHaveValue("");

  // The plugin's pill: its command line on top, the quote, the caret under it.
  await page.evaluate(() => {
    const text = [...document.querySelectorAll("#history .bubble.output")].pop().querySelector("p").firstChild;
    const range = document.createRange();
    range.setStart(text, 0);
    range.setEnd(text, "PONG".length);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  });
  await bar.getByRole("button", { name: "E2E check" }).click();
  await expect(page.locator("#prompt")).toHaveValue("/e2e-check quote\n> PONG\n\n");
  await expect(page.locator("#prompt")).toBeFocused();
  await page.keyboard.type("why?");
  await page.locator("#actionBtn").click();
  await expect(page.locator(`${H} .bubble.command .command-output`).last()).toHaveText("checked: quote\n> PONG\n\nwhy?");
  await expect(page.locator("#prompt")).toHaveValue("");

  // The built-in Verify (verify_preset.js) on the first answer: the quote and
  // the ask in the composer, unsent; Send runs the check with that turn's
  // anchor, and its verdict's card ("You") lands after the checked turn,
  // live and after a reload. Its variants: verdict_card, verify_* and
  // send_turn's node tests.
  script("verdict");
  await page.evaluate(() => {
    const text = document.querySelector("#history .bubble.output p").firstChild;
    const range = document.createRange();
    range.setStart(text, 0);
    range.setEnd(text, "PONG".length);
    const sel = window.getSelection();
    sel.removeAllRanges();
    sel.addRange(range);
  });
  await bar.getByRole("button", { name: "Verify" }).click();
  await expect(page.locator("#prompt")).toHaveValue(/^> PONG\n\nVerify this claim against the code\./);
  await expect(page.locator(`${H} .bubble.user`)).toHaveCount(2);
  await page.locator("#actionBtn").click();
  await turnEnded(page, 3);
  const verdict = async () => {
    const card = page.locator("#history .verify-verdict");
    await expect(card).toHaveCount(1);
    await expect(card).toHaveClass(/confirmed/);
    await expect(card.locator(".verify-verdict-who")).toHaveText("You");
    await expect(card.locator(".verify-verdict-quote")).toHaveText("PONG");
    // After the first turn, before the second's prompt.
    expect(await card.evaluate((node) => {
      const second = document.querySelectorAll("#history .bubble.user")[1];
      return !!(node.compareDocumentPosition(second) & Node.DOCUMENT_POSITION_FOLLOWING);
    })).toBe(true);
  };
  await verdict();
  await page.reload();
  await turnEnded(page, 3);
  await verdict();

  // A Revise of the checked answer: the Verify turn's answer has no Revise
  // (app.js's verifyTurn reads the session's verdicts); the revised first
  // turn folds to its stub, the verdict card stays on view, and the new
  // answer is the stack's top with its version chip, live and after a
  // reload. The stack's own variants: revise_stack.test.js.
  const [, quoteTurnId, verifyTurnId] = await page.locator("#history .bubble.user").evaluateAll((els) => els.map((el) => el.dataset.turnId));
  expect(verifyTurnId).toBeTruthy();
  await expect(page.locator("#history .revise-btn")).toHaveCount(2);
  await expect(page.locator(`#history .revise-btn[data-revise="${verifyTurnId}"]`)).toHaveCount(0);
  script("plain");
  const first = page.locator("#history .bubble.output").first();
  await first.hover();
  await page.locator("#history .revise-btn").first().click();
  await expect(page.locator("#reviseChip .revise-chip")).toContainText("Revising: PONG from the fake model.");
  await send(page, "Shorter");
  await turnEnded(page, 4);
  const stacked = async () => {
    await expect(page.locator("#history .stack-stub")).toHaveCount(1);
    await expect(page.locator("#history .stack-stub")).toContainText(/^v1 · “PONG from the fake model\. .*” · 1 line — superseded by v2/);
    await expect(page.locator("#history .bubble.user:visible").first()).toHaveAttribute("data-turn-id", quoteTurnId);
    await expect(page.locator("#history .verify-verdict")).toBeVisible();
    await expect(page.locator("#history .stack-versions > summary")).toHaveText("v2 · 1 earlier");
    await expect(page.locator("#history .bubble.output:visible").last()).toHaveText("PONG from the fake model. It streams word by word. Then the turn ends.");
    await expect(page.locator("#history .revise-row.stacked")).toHaveCount(1);
  };
  await stacked();
  await page.reload();
  await turnEnded(page, 4);
  await stacked();
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

test("the model picker lists chi web's models; searching 'deepseek4.1 fla' picks the flash with ⏎, Recent keeps two picks, Esc changes nothing", async ({ page, script }) => {
  const button = page.locator("#modelPick");
  const panel = page.locator("#modelPanel");
  const search = page.locator("#modelSearch");
  const options = page.locator("#modelList .model-option");
  // chi web's own /api/models: the fake model alone.
  await expect(button).toHaveText("fake-script");
  await button.click();
  await expect(options).toHaveText(["fake-scriptdefault"]);
  await search.press("Escape");
  await expect(panel).toBeHidden();

  await page.route("**/api/models", (route) => route.fulfill({ json: MANY_MODELS }));
  await page.reload();
  await expect(button).toHaveText("fake-script");

  await button.click();
  await expect(search).toBeFocused();
  await search.fill("deepseek4.1 fla");
  await expect(options.first()).toHaveText("openrouter · deepseek/deepseek-v4.1-flash");
  await expect(options.first()).toHaveClass(/active/);
  await expect(options.first().locator("mark")).toHaveText(["deepseek", "4.1", "fla"]);
  await search.press("Enter");
  await expect(panel).toBeHidden();
  await expect(button).toHaveText("openrouter · deepseek-v4.1-flash");
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
  // The title shows once: in the card while the strip shows it, in the top bar when hidden.
  const title = page.locator("#sessionTitle");
  await expect(title).toBeHidden();
  // The strip's grip (the handle on the chat's top edge) hides the strip with
  // a drag up and shows it with a tap (the keyboard and the other directions
  // are unit-tested).
  const dragGrip = async (dy) => {
    const box = await page.locator("#stripGrip").boundingBox(); // re-queried: the grip moves with the strip
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2 + dy, { steps: 8 });
    await expect(page.locator("#stripGrip")).toHaveClass(/will-toggle/);
    await page.mouse.up();
  };
  await dragGrip(-60);
  await expect(page.locator("#topStrip")).toBeHidden();
  await expect(page.locator("#stripGrip")).toHaveAttribute("aria-expanded", "false");
  await expect(title).toBeVisible();
  await expect(title).toHaveText("Say pong");
  await expect(page).toHaveTitle(/^Say pong · Chi/);
  await page.locator("#stripGrip").click();
  await expect(page.locator("#topStrip")).toBeVisible();
  await expect(page.locator("#stripGrip")).toHaveAttribute("aria-expanded", "true");
  await expect(title).toBeHidden();
  // Hidden again (a tap), the status pill is the strip's other way out: a
  // click opens All sessions, Esc leaves it.
  await page.locator("#stripGrip").click();
  await expect(page.locator("#topStrip")).toBeHidden();
  await expect(page.locator("#stripStatus")).toBeVisible();
  await page.locator("#stripStatus").click();
  await expect(page.locator("#filter")).toBeVisible();
  await expect(page).toHaveURL(/#\/sessions$/);
  // There the pill stays, pressed: the view's own button.
  await expect(page.locator("#stripStatus")).toHaveAttribute("aria-pressed", "true");
  await page.keyboard.press("Escape");
  await expect(page.locator("#stripStatus")).toHaveAttribute("aria-pressed", "false");
  await expect(page.locator("#filter")).toBeHidden();
  await page.locator("#stripGrip").click();
  await expect(stripCard).toBeVisible();

  await expect(page.locator("#infoBar > button:visible")).toHaveText(["continue →", "archive", "stop session", "delete"]);
  // The active card's ✎ renames it (/title through the worker): the input
  // over the card's title, the card following the saved file.
  await page.locator("#topStrip .card.active .card-rename").click();
  const renameInput = page.locator(".rename-input");
  await expect(renameInput).toBeFocused();
  const [inputBox, rowBox] = [await renameInput.boundingBox(), await page.locator("#topStrip .card.active .preview-row").boundingBox()];
  expect(Math.abs(inputBox.x - rowBox.x)).toBeLessThan(2);
  expect(Math.abs(inputBox.y + inputBox.height / 2 - (rowBox.y + rowBox.height / 2))).toBeLessThan(2);
  await page.keyboard.type("Pong check");
  await page.keyboard.press("Enter");
  await expect(renameInput).toHaveCount(0);
  await expect(stripCard).toContainText("Pong check");
  // Hidden, the strip leaves the title to the top bar, its ✎ right after it.
  await page.locator("#stripGrip").click();
  await expect(page.locator("#sessionTitle")).toHaveText("Pong check");
  await page.locator("#titleRenameBtn").click();
  await expect(renameInput).toBeFocused();
  await expect(renameInput).toHaveValue("Pong check");
  await page.keyboard.press("Escape");
  await expect(renameInput).toHaveCount(0);
  await expect(page.locator("#titleRenameBtn")).toBeFocused();
  await page.locator("#stripGrip").click();
  await expect(stripCard).toBeVisible();
  // Dragging the composer's grip down folds the composer away (the info bar
  // stays, the grip stays as its handle): the history's reserve shrinks, and
  // the choice survives a reload.
  const grip = page.locator("#composeGrip");
  const dockH = () => page.locator("#center").evaluate((el) => parseFloat(el.style.getPropertyValue("--dock-h")));
  const expandedH = await dockH();
  await expect(grip).toHaveAttribute("aria-expanded", "true");
  const gripMiddle = async () => {
    const b = await grip.boundingBox();
    return [b.x + b.width / 2, b.y + b.height / 2];
  };
  const promptH = () => page.locator("#prompt").evaluate((el) => el.offsetHeight);
  // A drag up gives the box a custom height (the grip's floor), saved per browser.
  const [gx, gy] = await gripMiddle();
  await page.mouse.move(gx, gy);
  await page.mouse.down();
  await page.mouse.move(gx, gy - 60, { steps: 6 });
  await page.mouse.up();
  const floorPx = await promptH();
  expect(await page.evaluate(() => Number(localStorage.getItem("chi_composer_floor")))).toBe(floorPx);
  const [fx, fy] = await gripMiddle();
  await page.mouse.move(fx, fy);
  await page.mouse.down();
  // Far enough down to fold: the box clamps at its one-line minimum, so the
  // fold asks for 32 px or more under the height the box actually shows.
  await page.mouse.move(fx, fy + 120, { steps: 8 });
  await expect(grip).toHaveClass(/will-fold/);
  await page.mouse.up();
  await expect(page.locator("#composer")).toBeHidden();
  await expect(grip).toHaveAttribute("aria-expanded", "false");
  // A fold keeps the height: opening brings the box back at the floor it had
  // (a double-click is the only reset).
  expect(await page.evaluate(() => Number(localStorage.getItem("chi_composer_floor")))).toBe(floorPx);
  await expect.poll(dockH).toBeLessThan(expandedH - 30);
  await page.reload();
  await expect(page.locator("#infoArchiveBtn")).toHaveText("archive");
  await expect(page.locator("#composer")).toBeHidden();
  await expect(grip).toHaveAttribute("aria-expanded", "false");
  // Typing on the page brings it back, the key in the box; folded again
  // with it (the keyboard: Enter on the handle), the handle says there is a
  // draft; a click on it opens the box and focuses it.
  await page.keyboard.press("h");
  await expect(page.locator("#composer")).toBeVisible();
  await expect(page.locator("#prompt")).toHaveValue("h");
  await expect(page.locator("#prompt")).toBeFocused();
  await expect(grip).toHaveAttribute("aria-expanded", "true");
  // ... at the height the grip had set, before the fold.
  await expect.poll(promptH).toBe(floorPx);
  await grip.focus();
  await page.keyboard.press("Enter");
  await expect(page.locator("#composer")).toBeHidden();
  await expect(grip).toHaveClass(/draft/);
  await grip.click();
  await expect(page.locator("#composer")).toBeVisible();
  await expect(page.locator("#prompt")).toHaveValue("h");
  await expect(page.locator("#prompt")).toBeFocused();
  await page.locator("#prompt").fill("");
  // Pulled up from folded, the handle opens it and the box follows the
  // pointer: with a multi-line draft (a tall box) it stays open on release
  // (re-based at the box's height after the unfold, not at the minimum).
  const draft = "one\ntwo\nthree\nfour\nfive";
  await page.locator("#prompt").fill(draft);
  await grip.focus();
  await page.keyboard.press("Enter");
  await expect(page.locator("#composer")).toBeHidden();
  await expect(grip).toHaveClass(/draft/);
  const handle = await grip.boundingBox();
  await page.mouse.move(handle.x + handle.width / 2, handle.y + handle.height / 2);
  await page.mouse.down();
  await page.mouse.move(handle.x + handle.width / 2, handle.y + handle.height / 2 - 70, { steps: 7 });
  await expect(grip).not.toHaveClass(/will-fold/);
  await page.mouse.up();
  await expect(page.locator("#composer")).toBeVisible();
  await expect(page.locator("#prompt")).toHaveValue(draft);
  await expect(page.locator("#prompt")).toBeFocused();
  await expect.poll(() => page.locator("#prompt").evaluate((el) => el.offsetHeight)).toBeGreaterThan(PROMPT_LINE_PX * 3);
  await page.locator("#prompt").fill("");
  // A floor set in a big window is held to half of the window the box is shown
  // in (a resized window, a rotated phone, another device on the same origin):
  // the saved floor itself stays, so the height comes back with the room.
  const [bx, by] = await gripMiddle();
  await page.mouse.move(bx, by);
  await page.mouse.down();
  await page.mouse.move(bx, by - 300, { steps: 10 });
  await page.mouse.up();
  const tallFloor = await promptH();
  await page.setViewportSize({ width: 500, height: 400 });
  await expect.poll(promptH).toBe(200);
  expect(await page.evaluate(() => Number(localStorage.getItem("chi_composer_floor")))).toBe(tallFloor);
  await page.setViewportSize({ width: 1280, height: 720 });
  await expect.poll(promptH).toBe(tallFloor);
  await page.locator("#infoArchiveBtn").click();
  await expect(page.locator("#infoArchiveBtn")).toHaveText("unarchive");
  await expect(page.locator("#toast")).toContainText(`Archived ${id.slice(0, 8)}`);
  await expect(stripCard).toHaveCount(0);
  await expect(page.locator("#infoStopBtn")).toBeHidden();
  // Still on the session, its composer as it was (archiving it there decides nothing).
  await expect(page).toHaveURL(new RegExp(`#/s/${id}$`));
  await expect(page.locator("#composer")).toBeVisible();
  // Opened afresh (a reload: the list may not hold it yet), an archived
  // session is folded, and it fits a phone that way.
  await page.reload();
  await expect(page.locator("#infoArchiveBtn")).toHaveText("unarchive");
  await expect(page.locator("#composer")).toBeHidden();
  await expect(grip).toHaveAttribute("aria-expanded", "false");
  await page.setViewportSize({ width: 390, height: 700 });
  await expectNoHorizontalOverflow(page);
  await page.setViewportSize({ width: 1280, height: 720 });
  await grip.click();
  await expect(page.locator("#composer")).toBeVisible();

  await page.locator("#allTile").click();
  const listed = page.locator(`#allList .card[data-id="${id}"]`);
  await expect(listed).toHaveCount(0);
  await page.locator("#includeArchived").click();
  await expect(page.locator("#includeArchived")).toHaveAttribute("aria-pressed", "true");
  await expect(listed).toHaveClass(/archived/);
  await expect(listed.locator(".archived-badge")).toHaveText("archived");
  await listed.click();

  // A new visit of the archived session: folded again (the unfold above
  // was for that visit only), unarchive still there.
  await expect(page.locator("#composer")).toBeHidden();
  await expect(page.locator("#infoArchiveBtn")).toHaveText("unarchive");
  await page.locator("#infoArchiveBtn").click();
  await expect(page.locator("#infoArchiveBtn")).toHaveText("archive");
  await expect(stripCard).toBeVisible();
});

// Two models on the default host: the fresh link's picker switches between them.
const TWO_MODELS = {
  default: "fake-script",
  models: [
    { name: "fake-script", host: "main", id: "fake-script" },
    { name: "fake-b", host: "main", id: "fake-b" },
  ],
};

test("continue → starts the next link with the opener in the composer, unsent, and the model picker until its first turn; the previous link is archived and reached from the chain's chip and the ← → links; its open delegate moves to the new link", async ({ page, script, chi }) => {
  script("plain");
  // start_page.js loadModels() runs at page load (and on + new session): route, then reload.
  await page.route("**/api/models", (route) => route.fulfill({ json: TWO_MODELS }));
  await page.reload();
  await expect(page.locator("#modelPick")).toHaveText("fake-script");
  await send(page, "Chain day one");
  await turnEnded(page, 1);
  const first = page.url().match(/#\/s\/([0-9a-f-]+)$/)[1];
  // A delegate of the first link with a reply it wasn't given: open, it moves.
  const kid = seedDelegate(chi, first, { tag: "Chain" });
  try {
    await continueAndCheck(page, first, kid.id);
  } finally {
    kid.remove();
  }
});

// The opener the second link is sent with, and the third one is filled with.
const CHAIN_OPENER = "Chain opener: check the queue";

async function continueAndCheck(page, first, kid) {
  await page.locator("#infoContinueBtn").click();
  await expect(page).not.toHaveURL(new RegExp(`#/s/${first}$`));
  const second = page.url().match(/#\/s\/([0-9a-f-]+)$/)[1];
  // Filled, not sent: no turn ran in the new link.
  await expect(page.locator("#prompt")).toHaveValue("Continue where we left off.");
  await expect(page.locator(`${H} .bubble.user`)).toHaveCount(0);
  await expect(page.locator("#actionBtn")).toHaveText("Send");
  await expect(page.locator("#toast")).toContainText(`Continued ${first.slice(0, 8)} in ${second.slice(0, 8)}`);
  await expect(page.locator("#toast")).toContainText("1 open delegate moved");
  // A fresh link: the picker shows its model; a pick runs /model in it, the
  // start page's remembered model and Recent stay, the opener stays.
  const pick = page.locator("#modelPick");
  const infoModel = page.locator("#infoText .meta .status + .model");
  const stored = await page.evaluate(() => [localStorage.getItem("chi_model"), localStorage.getItem("chi_model_recent")]);
  await expect(pick).toBeVisible();
  await expect(pick).toHaveText("fake-script");
  await expect(pick).toHaveAttribute("aria-label", "Model this link starts on");
  await pick.click();
  await page.locator("#modelSearch").fill("fake-b");
  await page.locator("#modelSearch").press("Enter");
  await expect(pick).toHaveText("fake-b");
  await expect(infoModel).toContainText("fake-b");
  await expect(page.locator(`${H} .bubble`).filter({ hasText: "/model fake-b" })).toHaveCount(1);
  expect(await page.evaluate(() => [localStorage.getItem("chi_model"), localStorage.getItem("chi_model_recent")])).toEqual(stored);
  await expect(page.locator("#prompt")).toHaveValue("Continue where we left off.");
  await expect(page.locator("#prompt")).toBeFocused();
  // The moved delegate folds under the new link, unarchived.
  const family = page.locator(`#topStrip .card[data-id="${second}"] .family-chip`);
  await expect(family).toContainText("1 delegate");
  await family.click();
  await expect(page.locator(`#familyPop .family-row[data-id="${kid}"]`)).toBeVisible();
  await page.keyboard.press("Escape");

  // The previous link is archived: its card is folded into the new one's #N chip.
  await expect(page.locator(`#topStrip .card[data-id="${first}"]`)).toHaveCount(0);
  const chip = page.locator(`#topStrip .card[data-id="${second}"] .chain-chip`);
  await expect(chip).toHaveText("↩#2");
  const back = page.locator("#infoBar a.chain-link");
  // Both links made in this run: the time (the date across a midnight).
  await expect(back).toHaveText(/^← (\d{2}:\d{2}|\d{4}-\d{2}-\d{2})$/);
  await expect(back).toHaveAttribute("href", `#/s/${first}`);
  await expect(page.locator("#infoContinueBtn")).toBeVisible();

  // The chip's popover lists the earlier link; a click opens it.
  await chip.click();
  await page.setViewportSize({ width: 390, height: 700 });
  const row = page.locator(`#chainPop .chain-row[data-id="${first}"]`);
  await expect(row.locator(".cr-n")).toHaveText("#1");
  await expect(row.locator(".archived-badge")).toHaveText("archived");
  await expectNoHorizontalOverflow(page);
  await page.setViewportSize({ width: 1280, height: 720 });
  await row.click();
  await expect(page).toHaveURL(new RegExp(`#/s/${first}$`));
  await expect(page.locator("#chainPop")).toBeHidden();
  await expect(page.locator("#infoArchiveBtn")).toHaveText("unarchive");
  // A link continued already: its → link, no Continue, no picker (it has turns).
  await expect(page.locator("#infoContinueBtn")).toBeHidden();
  await expect(pick).toBeHidden();
  const forward = page.locator("#infoBar a.chain-link");
  await expect(forward).toHaveText(/^(\d{2}:\d{2}|\d{4}-\d{2}-\d{2}) →$/);
  await forward.click();
  await expect(page).toHaveURL(new RegExp(`#/s/${second}$`));
  await expect(page.locator("#prompt")).toHaveValue("Continue where we left off.");
  await expect(pick).toHaveText("fake-b");

  // Its first turn, on an opener of the user's own: the picker goes.
  await page.locator("#prompt").fill(CHAIN_OPENER);
  await page.locator("#actionBtn").click();
  await turnEnded(page, 1);
  await expect(pick).toBeHidden();
  // The turn asked for fake-b (the fake server stamps fake-script on every answer).
  await expect(infoModel).toHaveAttribute("title", /asked for fake-b/);
  // The next continue brings that opener back, not the constant.
  await page.locator("#infoContinueBtn").click();
  await expect(page).not.toHaveURL(new RegExp(`#/s/${second}$`));
  await expect(page.locator("#prompt")).toHaveValue(CHAIN_OPENER);
  await expect(page.locator(`${H} .bubble.user`)).toHaveCount(0);
  // Sent, the link's title (the tab, the top bar) is still its chain's, as its card's,
  // after a reload too (its snapshot's first user message is the opener now).
  await page.locator("#actionBtn").click();
  await turnEnded(page, 1);
  await expect(page).toHaveTitle(/^Chain day one · Chi/);
  await page.reload();
  await expect(page.locator(`${H} .bubble.user`)).toHaveCount(1);
  await expect(page).toHaveTitle(/^Chain day one · Chi/);
  // The start page: its own remembered model came back.
  await page.locator("#newBtn").click();
  await expect(pick).toBeVisible();
  await expect(pick).toHaveText("fake-script");
  await expect(pick).toHaveAttribute("aria-label", "Model for the new session: fake-script");
  expect(await page.evaluate(() => [localStorage.getItem("chi_model"), localStorage.getItem("chi_model_recent")])).toEqual(stored);
  // A panel open on the start page closes when a session (not a fresh link) opens without a click
  // outside it (a hash change: back, a link), and stays closed back here.
  await pick.click();
  await expect(page.locator("#modelPanel")).toBeVisible();
  await page.evaluate((id) => { location.hash = `#/s/${id}`; }, second);
  await expect(page).toHaveURL(new RegExp(`#/s/${second}$`));
  await expect(pick).toHaveAttribute("aria-expanded", "false");
  await page.locator("#newBtn").click();
  await expect(pick).toBeVisible();
  await expect(page.locator("#modelPanel")).toBeHidden();
}

test("all sessions: a card's archive button hides it without opening it, the toast's Undo brings it back", async ({ page, script }) => {
  script("plain");
  await send(page, "Card archive pong");
  await turnEnded(page, 1);
  const id = page.url().match(/#\/s\/([0-9a-f-]+)$/)[1];

  await page.locator("#allTile").click();
  await expect(page).toHaveURL(/#\/sessions$/);
  const card = page.locator(`#allList .card[data-id="${id}"]`);
  await card.hover();
  const arch = card.locator(".card-tools .card-arch");
  await expect(arch).toHaveAttribute("aria-label", `Archive session ${id.slice(0, 8)}`);
  await arch.click();
  await expect(page.locator("#toast")).toContainText(`Archived ${id.slice(0, 8)}`);
  await expect(card).toHaveCount(0);
  // Still in the list, not on the session.
  await expect(page).toHaveURL(/#\/sessions$/);

  await page.locator("#toast .toast-action").click();
  await expect(page.locator("#toast")).toContainText(`Unarchived ${id.slice(0, 8)}`);
  await expect(card).toBeVisible();
  await expect(card).not.toHaveClass(/archived/);
});

test("all sessions: select mode archives a Shift-click range and one more pick in one batch, Undo brings them back", async ({ page, script }) => {
  script("plain");
  const ids = [];
  for (const n of [1, 2, 3]) {
    const res = await page.request.post(new URL("/api/sessions", page.url()).href, { data: { prompt: `Bulk archive pong ${n}` } });
    ids.push((await res.json()).id);
  }
  await page.locator("#allTile").click();
  await page.locator("#filter").fill("Bulk archive pong");
  const cards = page.locator("#allList .card[data-id]");
  // Idle first: a running turn is refused (busy).
  // (A card's status is the last word of its tooltip: cards have no status dot.)
  for (const id of ids) await expect(page.locator(`#allList .card[data-id="${id}"]`)).toHaveAttribute("title", / · idle( · mem: .*)?$/, { timeout: 15_000 });
  await expect(cards).toHaveCount(3);

  await page.locator("#selectBtn").click();
  await cards.nth(0).click();
  await cards.nth(1).click({ modifiers: ["Shift"] });
  await expect(page.locator("#selectCount")).toHaveText("2 selected");
  await cards.nth(2).locator(".card-pick").click();
  await expect(page.locator("#selectCount")).toHaveText("3 selected");
  await expect(cards.locator(".card-pick:checked")).toHaveCount(3);
  await expect(page).toHaveURL(/#\/sessions$/);

  await page.locator("#batchArchiveBtn").click();
  await expect(page.locator("#toast")).toContainText("Archived 3");
  await expect(cards).toHaveCount(0);
  await expect(page.locator("#selectCount")).toHaveText("0 selected");

  await page.locator("#toast .toast-action").click();
  await expect(page.locator("#toast")).toContainText("Unarchived 3");
  await expect(cards).toHaveCount(3);
  await expect(cards.locator(".card-pick:checked")).toHaveCount(0);
});

// Session families: a parent's delegates fold into its card. Seeded
// sessions (no worker): a parent and two delegates, then again with one
// waiting on the user.
test("a parent's delegates fold into its card: one strip card with a popover, inline rows in all sessions, search and a waiting one open them, select mode leaves rows alone", async ({ page, chi }) => {
  // A parent whose title wraps on a phone: its card needs more than the grid's
  // 72px row minimum, which is the card the row-collapse bug cut in half.
  const TAG = "Fold a wide refactor across worktrees and cards";
  const fam = await seedFamily(chi, { tag: TAG, parentMemories: ["project:notes", "user:style"] });
  let waitingFam = null;
  try {
    // The strip: the family is one card; its chip opens the rows in a popover under it.
    const stripCard = page.locator(`#topStrip .card[data-id="${fam.parent}"]`);
    const stripChip = stripCard.locator(".family-chip");
    const pop = page.locator("#familyPop");
    await expect(stripChip).toContainText("2 delegates");
    const familyIds = [fam.parent, ...fam.children].map((id) => `[data-id="${id}"]`).join(",");
    await expect(page.locator(`#topStrip .card:is(${familyIds})`)).toHaveCount(1);
    await stripChip.click();
    await expect(pop).toBeVisible();
    await expect(pop.locator(".family-row")).toHaveCount(2);
    await expect(stripChip).toHaveAttribute("aria-expanded", "true");
    const chipBox = await stripChip.boundingBox();
    const cardBox = await stripCard.boundingBox();
    const popBox = await pop.boundingBox();
    expect(popBox.y).toBeGreaterThanOrEqual(chipBox.y + chipBox.height);
    expect(Math.abs(popBox.x - cardBox.x)).toBeLessThan(2);
    // A modal dialog as every popover (chip_popover.js modalDialog): Tab from the
    // chip goes into it (it sits at the end of body), Shift+Tab before its first
    // stop wraps to its last; Esc gives the chip its focus back.
    await expect(pop).toHaveAttribute("aria-modal", "true");
    await page.keyboard.press("Tab");
    await expect(pop.locator(".fr-open").first()).toBeFocused();
    await page.keyboard.press("Shift+Tab");
    expect(await pop.evaluate((el) => el.contains(document.activeElement))).toBe(true);
    await expect(pop.locator(".fr-open").first()).not.toBeFocused();
    await page.keyboard.press("Escape");
    await expect(pop).toBeHidden();
    await expect(stripChip).toHaveAttribute("aria-expanded", "false");
    await expect(stripChip).toBeFocused();
    await stripChip.click();
    await expect(pop).toBeVisible();
    await page.locator("#prompt").click();
    await expect(pop).toBeHidden();
    await stripChip.click();
    await pop.locator(`.family-row[data-id="${fam.children[0]}"]`).click();
    await expect(page).toHaveURL(new RegExp(`#/s/${fam.children[0]}$`));
    await expect(pop).toBeHidden();
    await expect(stripCard).toHaveClass(/contains-active/);

    await page.locator("#allTile").click();
    const card = page.locator(`#allList .card[data-id="${fam.parent}"]`);
    const chip = card.locator(".family-chip");
    const rows = card.locator(".family-row");
    await expect(chip).toContainText("2 delegates");
    await expect(chip).toHaveAttribute("aria-expanded", "false");
    // The card's tooltip: its id, update and status, then the memories it used.
    await expect(card).toHaveAttribute("title", new RegExp(`^${fam.parent} · updated .+ · mem: project:notes, user:style$`));

    // Once the list scrolls the card keeps the height of its content: the chip and
    // the meta row stay inside it instead of hanging under its bottom border.
    // Checked before any click (a click scrolls the chip into view and passes on
    // broken CSS), and only when the list really overflows — this worker's chi is
    // shared, so the number of cards varies.
    try {
      for (const height of [300, 240, 200, 160]) {
        await page.setViewportSize({ width: 390, height });
        if (await page.evaluate(() => {
          const list = document.querySelector("#allList");
          return list.scrollHeight > list.clientHeight;
        })) break;
        if (height === 160) throw new Error("#allList never scrolls: the step cannot check anything");
      }
      const cardBox = await card.boundingBox();
      const cardBottom = cardBox.y + cardBox.height;
      for (const [name, part] of [["chip", chip], ["meta row", card.locator(".meta")]]) {
        const box = await part.boundingBox();
        expect(box.y + box.height, `the card's ${name} hangs below the card`).toBeLessThanOrEqual(cardBottom + 1);
      }
      await chip.click();
      await expect(rows).toHaveCount(2);
      await chip.click();
      await expect(rows).toHaveCount(0);
    } finally {
      await page.setViewportSize({ width: 1280, height: 720 });
    }

    await expect(rows).toHaveCount(0);
    for (const id of fam.children) await expect(page.locator(`#allList .card[data-id="${id}"]`)).toHaveCount(0);
    await expect(page.locator("#count")).toHaveText(/^\d+ · \d+ delegates$/);

    await chip.click();
    await expect(chip).toHaveAttribute("aria-expanded", "true");
    await expect(rows).toHaveCount(2);
    await expect(card.locator(`.family-row[data-id="${fam.children[0]}"]`)).toContainText("child one fixes");
    await expect(page).toHaveURL(/#\/sessions$/);
    await chip.click();
    await expect(rows).toHaveCount(0);

    // A search that matches a delegate brings its family, open, the row marked.
    await page.locator("#filter").fill("child two");
    await expect(page.locator("#allList .card[data-id]")).toHaveCount(1);
    await expect(card.locator(`.family-row.match[data-id="${fam.children[1]}"]`)).toBeVisible();
    await expect(card.locator(`.family-row.dim[data-id="${fam.children[0]}"]`)).toBeVisible();
    await page.locator("#filter").fill("");

    // Select mode: the chip still opens the list; rows have no checkbox and pick nothing.
    await page.locator("#selectBtn").click();
    await chip.click();
    await expect(rows).toHaveCount(2);
    await expect(card.locator(".family-row .card-pick, .family-row .card-arch")).toHaveCount(0);
    await rows.nth(0).click();
    await expect(page.locator("#selectCount")).toHaveText("0 selected");
    await expect(page).toHaveURL(/#\/sessions$/);
    await page.locator("#selectDoneBtn").click();

    // A row opens its delegate.
    await card.locator(`.family-row[data-id="${fam.children[1]}"]`).click();
    await expect(page).toHaveURL(new RegExp(`#/s/${fam.children[1]}$`));

    // A delegate that waits on the user opens its family and marks the parent.
    waitingFam = await seedFamily(chi, { tag: "Waits", waiting: true });
    await page.locator("#allTile").click();
    // The list now starts under the top bar, where the tile was: move the pointer off it, or the order
    // drawn under it holds (lists_view.js listOrder) and the waiting family seeded just now lands last.
    await page.mouse.move(2, 700);
    const waitingCard = page.locator(`#allList .card[data-id="${waitingFam.parent}"]`);
    await expect(waitingCard).toHaveClass(/\bwaiting\b/);
    // Open (a member waits), the chip is just the count: the rows carry the marks, no status dots.
    const waitingChip = waitingCard.locator(".family-chip");
    await expect(waitingChip).toHaveAttribute("aria-expanded", "true");
    await expect(waitingChip).toHaveText("▸2 delegates");
    await expect(waitingCard.locator(`.family-row[data-id="${waitingFam.children[1]}"] .attn`)).toHaveText("question");
    await expect(waitingCard.locator(".dot")).toHaveCount(0);
    // Waiting families sort first.
    await expect(page.locator("#allList .card[data-id]").first()).toHaveAttribute("data-id", waitingFam.parent);
    // Folded, it carries the counts.
    await waitingChip.click();
    await expect(waitingChip).toHaveAttribute("aria-expanded", "false");
    await expect(waitingCard.locator(".family-chip.waiting")).toContainText("2 delegates · 1 live · 1 waiting");
    await waitingChip.click();
    await expect(waitingChip).toHaveAttribute("aria-expanded", "true");
    // In the strip too: the waiting family's card first, warn chip, its popover row says what for.
    // The pressed sessions pill (the strip shown) goes back to the chat.
    await expect(page.locator("#stripStatus")).toHaveAttribute("aria-pressed", "true");
    await page.locator("#stripStatus").click();
    await expect(page).not.toHaveURL(/#\/sessions$/);
    const waitingStrip = page.locator(`#topStrip .card[data-id="${waitingFam.parent}"]`);
    await expect(page.locator("#topStrip .card[data-id]").first()).toHaveAttribute("data-id", waitingFam.parent);
    await expect(waitingStrip).toHaveClass(/\bwaiting\b/);
    await waitingStrip.locator(".family-chip.waiting").click();
    await expect(page.locator(`#familyPop .family-row[data-id="${waitingFam.children[1]}"] .attn`)).toHaveText("question");
    await page.keyboard.press("Escape");
  } finally {
    fam.remove();
    waitingFam?.remove();
  }
});

test("the info bar: a click on the id copies the full id, delete removes the session after the confirm", async ({ page, script }) => {
  script("plain");
  await send(page, "Say pong");
  await turnEnded(page, 1);
  const id = page.url().match(/#\/s\/([0-9a-f-]+)$/)[1];
  const stripCard = page.locator(`#topStrip .card[data-id="${id}"]`);
  await expect(stripCard).toBeVisible();

  // What the id hands the clipboard (headless Chromium's own clipboard
  // needs a permission grant and focus).
  await page.evaluate(() => {
    window.__copied = [];
    navigator.clipboard.writeText = async (text) => { window.__copied.push(text); };
  });
  const idChip = page.locator("#infoBar .id");
  await expect(idChip).toHaveText(id.slice(0, 8));
  await idChip.click();
  await expect(page.locator("#toast")).toContainText("Session id copied");
  expect(await page.evaluate(() => window.__copied)).toEqual([id]);

  let confirmText = null;
  page.once("dialog", (dialog) => { confirmText = dialog.message(); dialog.accept(); });
  const deleted = page.waitForResponse((res) => res.url().includes(id) && res.request().method() === "DELETE");
  await page.locator("#infoDeleteBtn").click();
  expect((await deleted).ok()).toBe(true);
  expect(confirmText).toContain(`Delete session ${id.slice(0, 8)}`);
  await expect(stripCard).toHaveCount(0);
  await expect(page).not.toHaveURL(new RegExp(id));
  await expect(page.locator("#infoDeleteBtn")).toBeHidden();
  await expect(page.locator("#actionBtn")).toHaveText("Start");
});

test("the start page's ⚙ panel and 🧰 list start the new session under the thinking, strategy and kit picked; they are not kept for the next one", async ({ page, script }) => {
  script("plain");
  const gear = page.locator("#settingsNew");
  const chip = page.locator("#llmContextNew");
  const think = page.locator("#thinkingNew");
  await expect(gear).toBeVisible();
  await expect(chip).toBeHidden();
  await expect(think).toBeHidden();
  await gear.click();
  const pop = page.locator("#startSettingsPopover");
  await expect(pop.locator(".sset-seg [aria-pressed=true]").first()).toBeFocused();
  // A budget chi wouldn't take is said under the fields; an edit clears it.
  await pop.getByRole("button", { name: /Apply and budget/ }).click();
  await pop.locator('input[name="budget"]').fill("12");
  await pop.locator(".llmctx-set").click();
  await expect(pop.locator(".sset-ctx-form .ctx-pop-error")).toContainText("A budget is a number of tokens");
  await pop.locator('input[name="budget"]').fill("");
  await expect(pop.locator(".sset-ctx-form .ctx-pop-error")).toBeHidden();
  // A pick applies at once; the panel stays open.
  await pop.getByRole("group", { name: "Context" }).getByRole("button", { name: "stale", exact: true }).click();
  await pop.getByRole("group", { name: "Thinking" }).getByRole("button", { name: "low", exact: true }).click();
  await expect(pop).toBeVisible();
  await expect(chip).toHaveText("ctx stale");
  await expect(think).toHaveText("think low");
  await page.keyboard.press("Escape");
  await expect(pop).toBeHidden();
  await expect(gear).toBeFocused();
  // 🧰: without toolkit.suggest on no Auto row, the default checked; a pick closes the list.
  const kits = page.locator("#toolkitBtn");
  const kitList = page.locator("#startToolkitPopover");
  await kits.click();
  await expect(kitList.locator(".st-row[aria-pressed=true]")).toContainText("full");
  await expect(kitList.locator(".st-row[aria-pressed=true]")).toBeFocused();
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("Enter");
  await expect(kitList).toBeHidden();
  await expect(kits).toBeFocused();
  await expect(page.locator("#toolkitNew")).toHaveText("tools: lean");
  const created = page.waitForRequest((r) => r.url().endsWith("/api/sessions") && r.method() === "POST");

  await send(page, "Say pong");
  expect((await created).postDataJSON()).toMatchObject({ thinking: "low", llm_context: { strategy: "stale" },
                                                         toolkit: "lean" });
  await turnEnded(page, 1);
  await expect(chip).toBeHidden();
  await expect(gear).toBeHidden();
  await expect(kits).toBeHidden();
  await expect(page.locator("#infoBar .settings-chip")).toHaveText("⚙ think low · ctx stale");
  await expect(page.locator("#infoBar .settings-chip")).toHaveClass(/\bown\b/);
  // 🧰 after ⚙: the session's kit, not the default one (GET /api/sessions/:id's toolkit_default).
  await expect(page.locator("#infoBar .settings-chip + .tools-chip")).toHaveText("🧰 lean");

  await page.locator("#newBtn").click();
  await expect(gear).toBeVisible();
  await expect(chip).toBeHidden();
  await expect(page.locator("#toolkitNew")).toBeHidden();
  await expect(page).not.toHaveURL(/#\/s\//);

  // Opening a session drops a choice made for a new session.
  await gear.click();
  await pop.getByRole("group", { name: "Context" }).getByRole("button", { name: "stale", exact: true }).click();
  await expect(chip).toHaveText("ctx stale");
  await page.locator("#topStrip .card[data-id]").first().click();
  await expect(page).toHaveURL(/#\/s\//);
  await expect(pop).toBeHidden();
  await page.locator("#newBtn").click();
  await expect(chip).toBeHidden();
});

// The confirm step before a change that restarts the prompt cache (CacheConfirm), one mechanism for /thinking and
// /reasoning-history: the reply asks, its Apply button sends the --yes line. The e2e host is a local chat host and
// plain.json's reply has thinking, so a change to all rewrites the earlier reply (ReasoningHistory.cache_cost).
test("a costly /reasoning-history asks first; the reply's Apply sends it, and the ⚙ chip follows", async ({ page, script }) => {
  script("plain");
  await send(page, "Say pong");
  await turnEnded(page, 1);
  const chip = page.locator("#infoBar .settings-chip");
  await expect(chip).toHaveText("⚙");

  await page.locator("#prompt").fill("/reasoning-history all");
  await page.locator("#actionBtn").click();
  // Filtered, not .last(): the --yes reply adds a newer bubble once Apply is clicked.
  const asked = page.locator("#history .bubble.command").filter({ hasText: "Nothing changed yet" });
  await expect(asked).toContainText("Nothing changed yet: send `/reasoning-history all --yes` to apply.");
  const apply = asked.locator("[data-confirm-line]");
  await expect(apply).toHaveText("Apply (restarts the cache)");
  await expect(chip).toHaveText("⚙");

  await apply.click();
  await expect(apply).toBeDisabled();
  await expect(chip).toHaveText("⚙ reasoning all");
  await expect(page.locator("#history .bubble.command").last()).toContainText("reasoning history: all (session)");
  await page.reload();
  await expect(page.locator("#infoBar .settings-chip")).toHaveText("⚙ reasoning all");
  // The ⚙ panel's Reasoning history row (a chat host's): the own level pressed, default plain.
  await page.locator("#infoBar .settings-chip").click();
  const rh = page.locator("#settingsPopover").getByRole("group", { name: "Reasoning" });
  await expect(rh.locator("[aria-pressed=true]")).toHaveText("all");
  await rh.getByRole("button", { name: "default", exact: true }).click();
  await expect(page.locator("#infoBar .settings-chip")).toHaveText("⚙");
  await expect(rh.locator("[aria-pressed=true]")).toHaveText(/^default \(/);
});

test("the info bar's ⚙ panel sets the session's own settings through its worker, a tap its field alone, and a reload keeps them", async ({ page, script }) => {
  script("plain");
  await send(page, "Say pong");
  await turnEnded(page, 1);
  const chip = page.locator("#infoBar .settings-chip");
  await expect(chip).toHaveText("⚙");
  await expect(chip).not.toHaveClass(/\bown\b/);
  // On the default kit (full here), 🧰 alone; its tooltip names the kit.
  await expect(page.locator("#infoBar .tools-chip")).toHaveText("🧰");
  await expect(page.locator("#infoBar .tools-chip")).toHaveAttribute("title", /^Toolkit: full \(the default\)/);

  await chip.click();
  const pop = page.locator("#settingsPopover");
  await expect(pop).toBeVisible();
  const ctx = pop.getByRole("group", { name: "Context" });
  await expect(ctx.locator("[aria-pressed=true]")).toHaveText("default (none)");
  // A tap runs its command at once (its reply in the conversation); the panel stays open, and the
  // pressed segment and the chip follow the reply.
  await pop.getByRole("group", { name: "Thinking" }).getByRole("button", { name: "low", exact: true }).click();
  await expect(page.locator("#history .bubble.command").last()).toContainText("thinking: low (session)");
  await expect(chip).toHaveText("⚙ think low");
  await expect(chip).toHaveClass(/\bown\b/);
  await expect(pop).toBeVisible();
  await expect(pop.getByRole("group", { name: "Thinking" }).locator("[aria-pressed=true]")).toHaveText("low");
  await ctx.getByRole("button", { name: "stale + forget", exact: true }).click();
  await expect(page.locator("#history .bubble.command").last()).toContainText("forget_outputs joins the tool list");
  await expect(chip).toHaveText("⚙ think low · ctx stale,forget");
  await expect(ctx.locator("[aria-pressed=true]")).toHaveText("stale + forget");
  await expect(ctx.getByRole("button", { name: "default", exact: true })).toBeVisible();

  // The disclosure's Set sends the apply rule alone: the session's own strategy stays (D2).
  await pop.getByRole("button", { name: /Apply and budget/ }).click();
  await pop.locator('select[name="apply"]').selectOption("turn_end");
  await pop.locator(".llmctx-set").click();
  await expect(page.locator("#history .bubble.command").last()).toContainText("/llm-context apply turn_end");
  await expect(page.locator("#history .bubble.command").last()).toContainText("this session's own: strategy stale, forget; apply turn_end");
  await expect(chip).toHaveText("⚙ think low · ctx stale,forget · apply turn_end");
  await page.keyboard.press("Escape");
  await expect(pop).toBeHidden();
  await page.reload();
  await expect(page.locator("#infoBar .settings-chip")).toHaveText("⚙ think low · ctx stale,forget · apply turn_end");

  // A strategy tap keeps the own apply rule; the Context row's default resets all three.
  await page.locator("#infoBar .settings-chip").click();
  await ctx.getByRole("button", { name: "stale", exact: true }).click();
  await expect(page.locator("#history .bubble.command").last()).toContainText("this session's own: strategy stale; apply turn_end");
  await expect(page.locator("#infoBar .settings-chip")).toHaveText("⚙ think low · ctx stale · apply turn_end");
  await ctx.getByRole("button", { name: "default", exact: true }).click();
  await expect(page.locator("#infoBar .settings-chip")).toHaveText("⚙ think low");
  await expect(ctx.locator("[aria-pressed=true]")).toHaveText("default (none)");
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

// One tab, behind, through the bell, a question and a check-in card. The
// variants are the node tests': the badge's rules (the bell off still
// counts, an answered question leaves it, visible clears it) in
// notifications.test.js, the attention kinds and their closing in
// notify.test.js.
test("notifications in one tab: the bell, a question behind (notified, badged, cleared in front, none after a reload), a check-in behind (resolved elsewhere drops the badge)", async ({ page, script }) => {
  await withNotificationStub(page);
  const bell = page.locator("#notifyBtn");
  const id = () => page.url().match(/#\/s\/([0-9a-f-]+)$/)[1];

  await test.step("the bell asks for permission once and stays on across a reload", async () => {
    await expect(bell).toHaveAttribute("data-state", "off");
    await bell.click();
    await expect(bell).toHaveAttribute("data-state", "on");
    await expect(bell).toHaveAttribute("aria-pressed", "true");
    await page.reload();
    await expect(bell).toHaveAttribute("data-state", "on");
  });

  await test.step("a question behind: one notification and a title badge; visible (before focus, Safari's order) clears it; a reload shows none", async () => {
    script("question");
    await send(page, "Read a file of my choice");
    const card = page.locator(`${H} .bubble.question`);
    await expect(card.locator(".question-text")).toHaveText("Which file should I read?");
    await expect.poll(() => notes(page)).toEqual([
      expect.objectContaining({ title: "Read a file of my choice", body: "needs an answer", tag: expect.stringMatching(/:/) }),
    ]);
    await expect(page).toHaveTitle(/^\(1\) .+ · Chi/);
    await page.evaluate(() => window.__showTab());
    await expect(page).not.toHaveTitle(/^\(/);

    // A reload (behind again) with the question still open: old state, no
    // notification, no badge.
    await page.reload();
    await expect(card.locator(".question-text")).toHaveText("Which file should I read?");
    await expect(page.locator("#topStrip .card").first()).toBeVisible();
    await expect(page).not.toHaveTitle(/^\(/);
    expect(await notes(page)).toEqual([]);

    // In front: answering counts nothing.
    await page.evaluate(() => window.__setFront(true));
    await card.locator(".question-option", { hasText: "README.md" }).click();
    await card.locator(".question-submit").click();
    await turnEnded(page, 1);
    expect(await notes(page)).toEqual([]);
    await expect(page).not.toHaveTitle(/^\(/);
  });

  await test.step("a check-in card behind: one 'needs you' notification; resolved from another client, the badge drops while the turn runs", async () => {
    await page.evaluate(() => window.__setFront(false));
    script("check_in");
    await send(page, "Look through the README");
    const card = page.locator(`${HC} > .plugin-card`).filter({ hasText: "3 tool calls, no answer yet" });
    await expect(card).toBeVisible();
    await expect.poll(() => notes(page)).toEqual([
      expect.objectContaining({ body: "needs you", tag: expect.stringMatching(/:card:check-in-/) }),
    ]);
    await expect(page).toHaveTitle(/^\(1\) .+ · Chi/);
    const res = await page.request.post(new URL(`/api/sessions/${id()}/command`, page.url()).href, { data: { line: "/checkin later" } });
    expect(res.ok()).toBe(true);
    await expect(page.locator(`${H} .plugin-card .card-action`)).toHaveCount(0);
    await expect(page).not.toHaveTitle(/^\(/);
    await expect(page.locator("#turnStage .ts-cancel")).toBeVisible();
    await turnEnded(page, 2);
    expect(await notes(page)).toHaveLength(1);
  });

  await test.step("the bell off stays off across a reload", async () => {
    await bell.click();
    await expect(bell).toHaveAttribute("data-state", "off");
    await page.reload();
    await expect(bell).toHaveAttribute("data-state", "off");
  });
});

// Two chi tabs: the one in front tells the other (BroadcastChannel), which
// then neither notifies nor badges; alone behind, it would. The tab behind
// records each "seen" word after its own handler took it (its channel
// wrapped): from then on its hold for that key can't deliver (notify.js
// createNotifyGate marks the key seen; the hold's timing is notify.test.js').
test("two tabs: one in front, the one behind shows no notification and no badge", async ({ page, script }) => {
  await withNotificationStub(page);
  const behind = await page.context().newPage();
  await behind.goto(page.url());
  await behind.addInitScript(() => {
    window.__heard = [];
    const Native = window.BroadcastChannel;
    window.BroadcastChannel = class extends Native {
      set onmessage(handler) {
        super.onmessage = (e) => {
          handler(e);
          if (e.data?.type === "seen") window.__heard.push(...(e.data.keys || []));
        };
      }
      get onmessage() { return super.onmessage; }
    };
  });
  await withNotificationStub(behind);
  await behind.locator("#notifyBtn").click();
  await expect(behind.locator("#notifyBtn")).toHaveAttribute("data-state", "on");
  await page.evaluate(() => window.__setFront(true));

  script("question");
  await send(page, "Read a file of my choice");
  const card = page.locator(`${H} .bubble.question`);
  await expect(card.locator(".question-text")).toHaveText("Which file should I read?");
  // The front tab's word has reached the tab behind's gate: no notification
  // and no badge there, now or after the question closes.
  const qid = await card.getAttribute("data-qid");
  await expect.poll(() => behind.evaluate(() => window.__heard)).toContainEqual(expect.stringContaining(qid));
  expect(await notes(behind)).toEqual([]);
  await expect(behind).not.toHaveTitle(/^\(/);
  await card.locator(".question-option", { hasText: "README.md" }).click();
  await card.locator(".question-submit").click();
  await turnEnded(page, 1);
  expect(await notes(behind)).toEqual([]);
  await behind.close();
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

// A turn that fails after a tool step keeps it (turn_failed's kept_steps):
// no prompt goes back, and its failure line is drawn again after a reload
// from the turn record (SessionMetrics' failure; turn_block.js failedLineHtml).
test("a turn that fails after a tool step keeps its step and its failure line, live and after a reload", async ({ page, script }) => {
  script("failed_after_steps");
  await send(page, "Check the shell");
  const line = "✕ turn failed: server error from host main: HTTP 500: boom; partial progress kept (!rollback restores the pre-turn state)";
  const shown = async () => {
    await expect(page.locator("#history .bubble.cancel")).toHaveText(line);
    await expect(page.locator("#history .bubble.user.failed")).toHaveCount(0);
    await expect(page.locator("#history .turn-work")).toContainText("1 tool call");
  };
  await turnEnded(page, 1);
  await shown();
  await expect(page.locator("#prompt")).toHaveValue("");
  await page.reload();
  await turnEnded(page, 1);
  await shown();
});

// A stream that drops mid-answer (the fake cuts it partway through its second sentence)
// is asked again by the chat loop. Live, the retry's note shows and the step
// is back to "…" (the fake holds each stream 1.5 s): the dropped sentence
// is gone, not left above the new one. The answer reads once, at the end and
// after a reload.
test("a step whose stream drops mid-answer is asked again: the partial goes live, and the answer shows once", async ({ page, script, configExtra }) => {
  // The e2e config has retry.max 0, which turns the ask-again off.
  configExtra("retry:\n  max: 1\n  base_delay: 0.05\n");
  script("stream_drop");
  await send(page, "Answer in one piece");
  // Each live state lasts about a second: checked every frame, not by
  // expect's backoff polling.
  const live = (text, note) => page.waitForFunction(([want, note]) => {
    const step = [...document.querySelectorAll(".gen.live .gen-text")].pop();
    const timing = [...document.querySelectorAll(".turn-timing")].pop();
    return step?.innerText.trim() === want && (!note || timing?.innerText.includes(note));
  }, [text, note], { timeout: 10_000 });
  await live("The first sentence comes.");
  await live("…", "↻ retrying (stream dropped) in 0.1s, 1/1");
  const answer = "The first sentence comes. The whole answer comes in one piece.";
  await turnEnded(page, 1);
  await expect(page.locator("#history .bubble.output")).toHaveText(answer);
  await page.reload();
  await turnEnded(page, 1);
  await expect(page.locator("#history .bubble.output")).toHaveText(answer);
});

test("/model X sent mid-turn shows queued, survives a reload, and applies once the turn ends", async ({ page, script }) => {
  script("mid_turn_command");
  await send(page, "Take a moment");
  await expect(page.locator("#turnStage .ts-cancel")).toBeVisible();
  // --yes: a switch on a session with a model reply asks first (it restarts the prompt cache).
  await page.locator("#prompt").fill("/model fake-other --yes");
  await page.locator("#actionBtn").click();
  const bubble = page.locator(`${H} .bubble.command`).filter({ hasText: "/model fake-other" });
  await expect(bubble).toHaveCount(1);
  await expect(bubble).toHaveClass(/queued/);
  await expect(bubble.locator(".command-output")).toHaveText("queued: runs after this turn");
  // Below the running turn's card, not among its rows (the stage's queued slot).
  const queuedSlot = page.locator("#turnStage .ts-queued .bubble.command");
  await expect(queuedSlot).toHaveCount(1);
  // The session's model in the info bar (not the new session's picker).
  const model = page.locator("#infoText .meta .status + .model");
  await expect(model).toHaveText(/^fake-script/);

  await page.reload();
  await expect(page.locator("#turnStage .ts-cancel")).toBeVisible();
  await expect(bubble).toHaveCount(1);
  await expect(bubble).toHaveClass(/queued/);
  await expect(queuedSlot).toHaveCount(1);

  await expect(answer(page)).toHaveText("Done after a while.", { timeout: 15_000 });
  await turnEnded(page, 1);
  await expect(bubble).toHaveCount(1);
  await expect(bubble).not.toHaveClass(/queued|failed|busy/);
  await expect(bubble.locator(".command-output")).toContainText("fake-other");
  await expect(model).toHaveText(/^fake-other/);
  // It ran after the turn: its bubble follows the turn's answer and timing
  // line, not where it waited among the turn's rows.
  const after = (sel) => bubble.evaluate((el, s) => {
    const other = [...document.querySelectorAll(s)].at(-1);
    return !!other && !!(other.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING);
  }, sel);
  await expect.poll(() => after("#history .bubble.output")).toBe(true);
  await expect.poll(() => after("#history .turn-timing:not(.live)")).toBe(true);
});

// check-in (after: 3 in the e2e config): the card comes up in the running
// step after the 3rd call; Nudge puts its message into the turn as a nudge
// row of that step, and the model's next step answers it.
test("check-in: the card mid-turn, Nudge makes a nudge row before the answer, live and after a reload", async ({ page, script }) => {
  script("check_in");
  await send(page, "Look through the README");
  const card = page.locator(`${HC} > .plugin-card`).filter({ hasText: "3 tool calls, no answer yet" });
  await expect(card).toBeVisible();
  // Its session card waits on the plugin card: a "needs you" pill (its kind,
  // "card", once made the badge a session card: a 72 px circle).
  const badge = page.locator("#topStrip .card.waiting .attn");
  await expect(badge).toHaveText("needs you");
  expect((await badge.boundingBox()).height).toBeLessThan(24);
  await card.locator(".card-action", { hasText: "Nudge" }).click();
  // The step that answers it shows it (open, live), before the answer (in
  // the stage: in its cloud, which the chip opens; the nudge flashes in the
  // trail meanwhile, so it is seen with the cloud closed).
  const row = page.locator(`${H} .steer-row`);
  await expect(row.locator("summary")).toHaveText("check-in nudged the model");
  const flashed = page.locator("#turnStage .ts-trail-item.steer");
  await expect(flashed).toHaveText("↪ check-in nudged the model");
  await expect(flashed).toBeVisible();
  await page.locator("#turnStage .ts-chip-label").click();
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
// DOM (inside the closed cloud); after the hand-off the block has them in
// the cut generation's step.
test("thinking loop: loop-guard cuts it, asks again, answers", async ({ page, script }) => {
  script("thinking_loop");
  await send(page, "How many r letters are in strawberry?");
  const rows = page.locator(`${H} .hook-notice`);
  const cut = rows.filter({ hasText: "thinking repeats itself" });
  const again = rows.filter({ hasText: "↻ cut by loop-guard, asking again (1/1)" });
  await expect(page.locator("#turnStage .ts-trail")).toContainText("thinking repeats itself");
  await expect(cut).toHaveCount(1);
  await expect(again).toHaveCount(1);
  await expect(cut).toContainText("(\"Wait, the count of the letter r in the word might be three,…\", 3 sentences ×3");
  await expect(page.locator("#turnStage .ts-cancel")).toBeVisible();
  await expect(answer(page)).toHaveText("PONG after the cut.");
  await turnEnded(page, 1);
  // Handed off: both rows are the cut generation's, the block's first step.
  const steps = page.locator("#history .turn-work .gen");
  await expect(steps).toHaveCount(2);
  await expect(steps.first().locator(".hook-notice")).toHaveCount(2);
  // Well before the loop's own end (~11 s of streaming, then the 3 s hold):
  // the cut turn takes ~5 s. Timed by the worker (the turn's own seconds),
  // not from the test's start, which adds the worker's spawn and tipped a
  // 9 s wall-clock bound over under load.
  // The list's summary can trail the page's turn end by a moment: polled.
  const id = page.url().match(/#\/s\/([0-9a-f-]+)$/)[1];
  const turnSeconds = async () => {
    const list = await (await page.request.get(new URL("/api/sessions", page.url()).href)).json();
    return Number(list.find((s) => s.id === id)?.last_turn?.seconds) || 0;
  };
  await expect.poll(turnSeconds).toBeGreaterThan(0);
  expect(await turnSeconds()).toBeLessThan(9);
});

// A warn card in a step (here the e2e-warn-card test bundle's, at the first
// step's read) stays in sight when that step closes mid-turn: it leaves the
// collapsing step for the block, and after the turn ends it is under the
// block, where a reload puts it, also once the session is stopped.
test("a warn card stays in sight when its step closes mid-turn", async ({ page, script }) => {
  script("warn_card");
  await send(page, "Read the flagged file");
  const card = page.locator(`${H} .plugin-card.warn`).filter({ hasText: "e2e warn card" });
  await expect(card).toHaveCount(1);
  // The next step started: the card's step is closed, the turn still runs
  // (the last step holds 4 s before it answers). In the stage the card sits
  // in the extras, not in its step inside the closed cloud.
  await expect(page.locator("#turnStage .ts-trail")).toContainText("read README.md");
  await expect(page.locator("#turnStage .ts-extras > .plugin-card.warn")).toHaveCount(1);
  await expect(card).toBeVisible({ timeout: 1000 });
  // Still running: Stop turn is up, no final timing line yet.
  await expect(page.locator("#turnStage .ts-cancel")).toBeVisible({ timeout: 1000 });
  await expect(page.locator("#history .turn-timing:not(.live)")).toHaveCount(0);
  await turnEnded(page, 1);
  await expect(card).toBeVisible();
  await expect(page.locator("#history > .plugin-card.warn")).toHaveCount(1);
  // Handed off: the block's steps, the card's step closed, the next one's read in it.
  const steps = page.locator("#history .turn-work .gen");
  await expect(steps.nth(1).locator(".activity-row")).toHaveCount(1);
  await expect(steps.first()).not.toHaveAttribute("open", "");
  // The worker saved it with the session: stopped, a reload still shows it.
  page.once("dialog", (dialog) => dialog.accept());
  const stopped = page.waitForResponse((res) => /\/stop$/.test(res.url()) && res.request().method() === "POST");
  await page.locator("#infoStopBtn").click();
  expect((await stopped).ok()).toBe(true);
  await page.reload();
  await expect(page.locator("#history .bubble.user")).toHaveCount(1);
  await expect(page.locator("#history > .plugin-card.warn").filter({ hasText: "e2e warn card" })).toHaveCount(1);
});

// The Stop button asks first what the worker still has that the user can
// stop (stop_sheet.js): a background task the turn started is listed at phone
// width as a bottom sheet with its three answers, and "Stop all" runs the
// worker's stop-all step before the stop itself.
test("stop asks about the background task still running: the sheet, then Stop all stops it and the session", async ({ page, script }) => {
  script("stop_sheet");
  await send(page, "Start a background task");
  await turnEnded(page, 1);
  const id = page.url().match(/#\/s\/([0-9a-f-]+)$/)[1];

  await page.setViewportSize({ width: 390, height: 700 });
  await page.locator("#infoStopBtn").click();

  const sheet = page.locator("#stopSheet");
  await expect(sheet).toBeVisible();
  await expect(sheet.locator(".ss-line")).toHaveCount(1);
  await expect(sheet.locator(".ss-line").first()).toContainText("1 background task");
  await expect(sheet.locator(".ss-line").first()).toContainText("sleep 120");
  await expect(sheet.locator(".ss-acts button")).toHaveText(["Stop all", "Stop session only", "Cancel"]);
  await page.screenshot({ path: "tmp/e2e/stop-sheet-phone.png" });

  const held = page.waitForResponse((res) => res.url().endsWith(`/api/sessions/${id}/holds/stop`) && res.status() === 200);
  const stopped = page.waitForResponse((res) => res.url().endsWith(`/api/sessions/${id}/stop`) && res.status() === 200);
  await sheet.locator('[data-act="all"]').click();
  expect((await held).ok()).toBe(true);
  expect((await stopped).ok()).toBe(true);
  await expect(sheet).toBeHidden();
  // The worker is gone: the page says so, and the sheet is not left open.
  await expect(page.locator("#infoStopBtn")).toBeHidden();
});

// A notice marked fallback_for: display (here the e2e-fallback-notice test
// bundle's, after the answer) stands in for the answer's links, which the
// page renders (web.markdown on): it is never drawn, not even for a moment
// in the stage, and a reload doesn't bring it back. A plain notice next to
// it shows.
test("a notice that stands in for the rendered answer isn't shown, live or after a reload", async ({ page, script }) => {
  await page.evaluate(() => {
    window.fallbackSeen = false;
    new MutationObserver(() => {
      if (document.querySelector("#center").textContent.includes("e2e fallback line")) window.fallbackSeen = true;
    }).observe(document.querySelector("#center"), { subtree: true, childList: true, characterData: true });
  });
  script("fallback_notice");
  await send(page, "Name the ticket");
  await turnEnded(page, 1);
  await expect(page.locator("#history .bubble.output a[href='https://example.test/JIRA-1']")).toHaveCount(1);
  await expect(page.locator("#history").getByText("e2e plain line")).toHaveCount(1);
  await expect(page.locator("#center")).not.toContainText("e2e fallback line");
  expect(await page.evaluate(() => window.fallbackSeen)).toBe(false);

  await page.reload();
  await expect(page.locator("#history .bubble.user")).toHaveCount(1);
  await expect(page.locator("#history").getByText("e2e plain line")).toHaveCount(1);
  await expect(page.locator("#center")).not.toContainText("e2e fallback line");
});

// Refs a plugin attached to the answer (the e2e-answer-refs test bundle's,
// refs only: an answer_display with no display): JIRA-7 pairs with its
// markdown link (the href is its first action's URL), its menu offers both
// actions, the second opens in a new tab; ABC-3 pairs with its plain text.
// Live (the stage hands the bound answer off) and after a reload. The
// pairing may land with the answer_display re-read, after the turn ends.
// Its e2e_ticket row's refs (chi.tool refs:, D8): the title opens the
// first's action, its menu adds the second's, named, its URL on hover.
test("an answer's plugin refs pair with its link and text, a tool row's with its title and menu; actions open in a new tab; live and after a reload", async ({ page, script }) => {
  const recordOpens = () => page.evaluate(() => {
    window.__opened = [];
    window.open = (...args) => { window.__opened.push(args); return null; };
  });
  const check = async () => {
    await recordOpens();
    const link = page.locator('#history .bubble.output a.ref[data-ref-kind="issue"]');
    await expect(link).toHaveText("JIRA-7");
    await expect(link).toHaveAttribute("title", /JIRA-7 Login fails/);
    const plain = page.locator('#history .bubble.output span.ref[data-ref-kind="issue"]');
    await expect(plain).toHaveText("ABC-3");
    await link.hover();
    await page.locator(".ref-more").click();
    await expect(page.getByRole("menuitem")).toHaveText(["Open in Jira", "Jira board"]);
    await page.getByRole("menuitem", { name: "Jira board" }).click();
    await expect(page.locator(".ref-menu")).toHaveCount(0);
    // One action: a plain click opens it (no ▾).
    await plain.click();
    expect(await page.evaluate(() => window.__opened)).toEqual([
      ["https://example.test/board/JIRA-7", "_blank", "noopener,noreferrer"],
      ["https://example.test/ABC-3", "_blank", "noopener,noreferrer"],
    ]);

    for (const details of [page.locator("#history .turn-work"), page.locator("#history .turn-work details.gen").first()]) {
      if (!(await details.evaluate((el) => el.open))) await details.locator("> summary").click();
    }
    const title = page.locator('#history .activity-row .activity-params.ref[data-ref-kind="issue"]');
    await expect(title).toHaveText('id="JIRA-7"');
    await recordOpens();
    await title.click();
    await title.hover();
    await page.locator(".ref-more").click();
    await expect(page.getByRole("menuitem")).toHaveText(["Open in Jira", "PR #42 · Open on GitHub"]);
    await expect(page.getByRole("menuitem", { name: "PR #42 · Open on GitHub" })).toHaveAttribute("title", "https://example.test/pull/42");
    await page.getByRole("menuitem", { name: "PR #42 · Open on GitHub" }).click();
    expect(await page.evaluate(() => window.__opened)).toEqual([
      ["https://example.test/JIRA-7", "_blank", "noopener,noreferrer"],
      ["https://example.test/pull/42", "_blank", "noopener,noreferrer"],
    ]);
  };
  script("answer_refs");
  await send(page, "Name the tickets");
  await turnEnded(page, 1);
  await check();
  await page.reload();
  await turnEnded(page, 1);
  await check();
});

// The github-pr bundle's line links (its gh is support/fake_gh.sh): a
// `path:line` in the answer links to that line of the PR the prompt names,
// the Files changed anchor inside a hunk, the file at the PR's head outside.
// The PR's data is fetched off the turn, from its start: the scripted
// answer waits for the fake gh's files call (hold_until) and 1 s more, so it
// comes after the fetch however loaded the machine is.
test("a path:line in the answer links to the PR's line", async ({ page, script }) => {
  script("pr_line_links");
  await send(page, "Review https://github.com/acme/app/pull/42");
  await turnEnded(page, 1);
  // sha256("lib/foo.rb")
  const diff = "diff-47ce87534a4e96112fc42a7ab2170bca8347bb742ced63eedd4f8c260080005f";
  const output = page.locator("#history .bubble.output").last();
  await expect(output.locator(`a[href="https://github.com/acme/app/pull/42/files#${diff}R28"] code`)).toHaveText("lib/foo.rb:28");
  await expect(output.locator('a[href="https://github.com/acme/app/blob/e2ehead/lib/foo.rb#L100"]')).toHaveText("lib/foo.rb:100");
});

// A 1×1 PNG: an image prompt runs as its own next turn (steering merges
// text only), so B queues behind A.
const PNG_1PX = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

// The composer's image button opens the file picker; the picked images are
// chips, a file that isn't an image stays out with a toast, × drops a chip,
// and the rest go with the message (a thumbnail in its bubble).
test("the image button: picked images are chips, a non-image stays out with a toast, × drops one, the rest go with the message", async ({ page, script }) => {
  script("plain");
  const png = (name) => ({ name, mimeType: "image/png", buffer: Buffer.from(PNG_1PX, "base64") });
  await expect(page.locator("#attachBtn")).toBeVisible();
  const chooser = page.waitForEvent("filechooser");
  await page.locator("#attachBtn").click();
  await (await chooser).setFiles([png("one.png"), png("two.png"), { name: "notes.txt", mimeType: "text/plain", buffer: Buffer.from("hi") }]);
  await expect(page.locator("#chips .chip-name")).toHaveText(["one.png", "two.png"]);
  await expect(page.locator("#toast")).toContainText("1 file not added: not an image");
  await page.locator("#chips .chip-remove").first().click();
  await expect(page.locator("#chips .chip-name")).toHaveText(["two.png"]);
  await send(page, "Say pong");
  await expect(page.locator(`${H} .bubble.user`).last().locator("img.thumb")).toHaveCount(1);
  await expect(answer(page)).toHaveText("PONG from the fake model. It streams word by word. Then the turn ends.");
  await turnEnded(page, 1);
  await expect(page.locator("#chips")).toBeHidden();
});

// A's turn-end re-read (?tail=1) lands after B started: B keeps its own
// live line ("turn 2", ticking), A's line and answer are A's, and a reload
// draws the same two lines. B followed A at once: no gap divider; a reload
// whose turn A happened 40 minutes earlier (its stamps and record moved
// back) draws one, above B's prompt.
test("a queued turn keeps its own live timing line when the turn before it re-reads late", async ({ page, script }) => {
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
  await expect(page.locator(`${H} .turn-timing.live`)).toHaveText(LIVE_LINE(1));
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
  const lines = page.locator(`${H} .turn-timing`);
  const live = page.locator(`${H} .turn-timing.live`);
  await expect(lines).toHaveCount(2);
  await expect(live).toHaveCount(1);
  release();
  // A's re-read landed: its answer is the rendered markdown.
  await expect(page.locator(`${H} .bubble.output strong`)).toHaveText("bold");
  await expect(live).toHaveCount(1);
  await expect(live).toHaveText(LIVE_LINE(2));
  await expect(lines.first()).toHaveText(/^turn 1 · /);
  const before = await live.textContent();
  await expect.poll(() => live.textContent(), { timeout: 3000 }).not.toBe(before);
  await expect(live).toHaveText(LIVE_LINE(2));
  // B ends: its own line, final.
  await expect(page.locator(`${H} .bubble.output`).last()).toHaveText("Second answer, from the queued turn.", { timeout: 15_000 });
  await turnEnded(page, 2);
  const final = await page.locator("#history .turn-timing").allTextContents();
  expect(final).toHaveLength(2);
  expect(final[0]).toMatch(/^turn 1 · /);
  expect(final[1]).toMatch(/^turn 2 · /);
  await expect(page.locator("#history .time-gap")).toHaveCount(0);
  await page.route(/\/api\/sessions\/[^/?]+\?parts=1$/, async (route) => {
    const response = await route.fetch();
    const json = await response.json();
    const earlier = (iso) => new Date(Date.parse(iso) - 40 * 60_000).toISOString();
    const second = json.messages.findIndex((m) => m.role === "user" && /QUEUED-B/.test(m.content));
    json.messages.forEach((m, i) => { if (i < second && m.at) m.at = earlier(m.at); });
    const [first] = json.timing?.turn_records || [];
    if (first?.started_at) first.started_at = earlier(first.started_at);
    await route.fulfill({ response, json });
  });
  await page.reload();
  await turnEnded(page, 2);
  const reloaded = await page.locator("#history .turn-timing").allTextContents();
  expect(reloaded).toHaveLength(2);
  expect(reloaded[0]).toMatch(/^turn 1 · /);
  expect(reloaded[1]).toMatch(/^turn 2 · /);
  const gap = page.locator("#history > .time-gap");
  await expect(gap).toHaveCount(1);
  await expect(gap).toHaveText(/^── .+ · (39|40) min later ──$/);
  expect(await gap.evaluate((el) => el.nextElementSibling?.matches(".bubble.user") && el.nextElementSibling.textContent.includes("QUEUED-B"))).toBe(true);
  await expect(page.locator("#history .bubble.user").first()).toHaveAttribute("title", /^\w{3} \d+ \w{3} \d{4} \d\d:\d\d:\d\d$/);
});
