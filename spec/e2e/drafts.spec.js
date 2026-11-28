// The composer's drafts (drafts.js): one per session window and the start
// page's own, the text kept over a reload in this browser, the images not;
// an answer that comes after a switch writes the draft it was sent from.
import { test, expect } from "./support/fixtures.js";

const H = ":is(#history, #turnStage)";
const PNG_1PX = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";
const png = (name) => ({ name, mimeType: "image/png", buffer: Buffer.from(PNG_1PX, "base64") });

async function turnEnded(page, turns) {
  await page.mouse.move(0, 0);
  await expect(page.locator("#history .turn-timing:not(.live)")).toHaveCount(turns);
  await expect(page.locator("#actionBtn")).toHaveText("Send");
  await expect(page.locator("#actionBtn")).toBeEnabled();
}

const openId = (page) => page.url().match(/#\/s\/([0-9a-f-]+)$/)?.[1];

// A new session from the start page (+ new), its first turn over: its id.
async function newSession(page, prompt) {
  await page.locator("#newBtn").click();
  await expect(page.locator("#prompt")).toHaveValue("");
  await page.locator("#prompt").fill(prompt);
  await page.locator("#actionBtn").click();
  await expect(page).toHaveURL(/#\/s\/[0-9a-f-]+$/);
  await expect(page.locator(`${H} .bubble.user`).last()).toContainText(prompt);
  await turnEnded(page, 1);
  return openId(page);
}

async function open(page, id) {
  await page.locator(`#topStrip .card[data-id="${id}"]`).click();
  await expect(page).toHaveURL(new RegExp(`#/s/${id}$`));
  await expect(page.locator("#history .hint", { hasText: "Loading" })).toHaveCount(0);
}

test("drafts are per session window: each its own text and images, + new its own, the text kept over a reload", async ({ page, script }) => {
  script("plain");
  const a = await newSession(page, "Say pong");
  script("inline_widgets");
  const b = await newSession(page, "How does it reconnect?");
  const prompt = page.locator("#prompt");

  await open(page, a);
  await prompt.fill("alpha draft");
  await page.locator("#attachInput").setInputFiles(png("one.png"));
  await expect(page.locator("#chips .chip-name")).toHaveText(["one.png"]);

  // (a) A's text and image aren't on B.
  await open(page, b);
  await expect(prompt).toHaveValue("");
  await expect(page.locator("#chips")).toBeHidden();
  await prompt.fill("beta");
  // A pick's Fill reply goes into B's draft, after B's own text.
  const picks = page.locator("#history .bubble.output").last().locator(".w.picks");
  await picks.getByRole("button", { name: "Fill reply" }).click();
  await expect(prompt).toHaveValue(/^beta\n1: /);
  const filled = await prompt.inputValue();

  await open(page, a);
  await expect(prompt).toHaveValue("alpha draft");
  await expect(page.locator("#chips .chip-name")).toHaveText(["one.png"]);
  await open(page, b);
  await expect(prompt).toHaveValue(filled);

  // (d) + new has its own draft.
  await page.locator("#newBtn").click();
  await expect(prompt).toHaveValue("");
  await expect(page.locator("#chips")).toBeHidden();
  await prompt.fill("start text");

  // (e) A reload keeps the text; the image is gone.
  await open(page, a);
  await page.reload();
  await expect(page.locator("#history .bubble.user").first()).toBeVisible();
  await expect(prompt).toHaveValue("alpha draft");
  await expect(page.locator("#chips")).toBeHidden();
  await page.locator("#newBtn").click();
  await expect(prompt).toHaveValue("start text");
  // The start page's own draft over a reload too (the Home Screen app opens at "/").
  await page.reload();
  await expect(prompt).toHaveValue("start text");
  await open(page, b);
  await expect(prompt).toHaveValue(filled);
});

test("an answer after a switch writes the draft it was sent from: A empties at its ack, B keeps what was typed meanwhile", async ({ page, script }) => {
  script("plain");
  const a = await newSession(page, "Say pong");
  const b = await newSession(page, "Say pong again");
  const prompt = page.locator("#prompt");
  await open(page, a);

  let release;
  const held = new Promise((resolve) => { release = resolve; });
  let posted;
  const reached = new Promise((resolve) => { posted = resolve; });
  await page.route("**/turn", async (route) => {
    if (route.request().method() !== "POST") return route.fallback();
    posted();
    await held;
    return route.fallback();
  });
  await prompt.fill("held line");
  await page.locator("#actionBtn").click();
  await reached;
  // The line in flight isn't in the saved copy: a reload now wouldn't bring it back to send again.
  expect(await page.evaluate((id) => localStorage.getItem(`chi_composer_draft:${id}`), a)).toBeNull();

  await open(page, b);
  await prompt.fill("b typing");
  const acked = page.waitForResponse((res) => res.request().method() === "POST" && res.url().endsWith(`/api/sessions/${a}/turn`));
  release();
  await acked;
  await page.unroute("**/turn");
  await expect(prompt).toHaveValue("b typing");
  await open(page, a);
  await expect(page.locator(`${H} .bubble.user`).filter({ hasText: "held line" })).toHaveCount(1);
  await expect(prompt).toHaveValue("");
});

// Holds continue →'s POST /api/sessions (a create is a POST there too: only the continue's).
async function holdContinue(page) {
  let release;
  const held = new Promise((resolve) => { release = resolve; });
  let posted;
  const reached = new Promise((resolve) => { posted = resolve; });
  await page.route("**/api/sessions", async (route) => {
    if (route.request().method() !== "POST" || !route.request().postDataJSON()?.continues) return route.fallback();
    posted();
    await held;
    return route.fallback();
  });
  return { reached, release: async () => { release(); await page.waitForResponse((res) => res.request().method() === "POST" && /\/api\/sessions$/.test(res.url())); } };
}

test("continue hands the session's draft to its next link, wherever the page is when it lands; no Restore draft", async ({ page, script }) => {
  script("plain");
  const a = await newSession(page, "Say pong");
  const b = await newSession(page, "Say pong again");
  const prompt = page.locator("#prompt");
  const toast = page.locator("#toast");

  // (b) On B when the continue lands: B keeps its own, the new link has A's draft.
  await open(page, a);
  await prompt.fill("plan X");
  let hold = await holdContinue(page);
  await page.locator("#infoContinueBtn").click();
  await hold.reached;
  await open(page, b);
  await prompt.fill("b stuff");
  await hold.release();
  await page.unroute("**/api/sessions");
  await expect(toast).toContainText(`Continued ${a.slice(0, 8)} in`);
  await expect(toast.getByRole("button", { name: "Restore draft" })).toHaveCount(0);
  await expect(prompt).toHaveValue("b stuff");
  await toast.getByRole("button", { name: "Open" }).click();
  await expect(page).not.toHaveURL(new RegExp(`#/s/(${a}|${b})$`));
  const a2 = openId(page);
  await expect(prompt).toHaveValue("plan X");

  // (c) Back on the link before it lands, text typed meanwhile: the next link opens with all of it.
  await prompt.fill("more");
  hold = await holdContinue(page);
  await page.locator("#infoContinueBtn").click();
  await hold.reached;
  await open(page, b);
  await expect(prompt).toHaveValue("b stuff");
  await open(page, a2);
  await expect(prompt).toHaveValue("more");
  await prompt.press("End");
  await prompt.pressSequentially(" plus");
  await hold.release();
  await page.unroute("**/api/sessions");
  await expect(page).not.toHaveURL(new RegExp(`#/s/${a2}$`));
  await expect(prompt).toHaveValue("more plus");
  await expect(prompt).toBeFocused();
  await expect(toast).toContainText(`Continued ${a2.slice(0, 8)} in`);
  await expect(toast.getByRole("button", { name: "Restore draft" })).toHaveCount(0);
  await open(page, b);
  await expect(prompt).toHaveValue("b stuff");
});
