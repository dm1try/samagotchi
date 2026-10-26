// chi web on the LAN (--web-host lan), reached at this machine's LAN
// address as a phone would (not loopback, so the access token is asked for).
import fs from "node:fs";
import { test, expect } from "./support/fixtures.js";
import { privateIPv4 } from "./support/env.js";

test.skip(!privateIPv4(), "no private IPv4 address on this machine");

test("the LAN page asks for the token, the token link gets in, a turn streams and a reload stays in", async ({ chi, context, script }) => {
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));

  const refused = await page.goto(`${chi.lanURL}/`);
  expect(refused.status()).toBe(401);
  await expect(page.locator("body")).toContainText("scan its QR code");
  await expect(page.locator("input[name=token]")).toBeVisible();

  const token = fs.readFileSync(chi.tokenPath, "utf8").trim();
  await page.goto(`${chi.lanURL}/?token=${token}`);
  expect(page.url()).toBe(`${chi.lanURL}/`);
  expect(page.url()).not.toContain("token");
  await expect(page.locator("#actionBtn")).toHaveText("Start");
  // The page is an insecure origin: no bell, the title badge only.
  expect(await page.evaluate(() => window.isSecureContext)).toBe(false);
  await expect(page.locator("#notifyBtn")).toBeHidden();

  script("plain");
  await page.locator("#prompt").fill("Say pong");
  await page.locator("#actionBtn").click();
  await expect(page).toHaveURL(/#\/s\/[0-9a-f-]+$/);
  // The stage view hands the turn off into the history once the pointer
  // is away from it.
  await page.mouse.move(0, 0);
  const answer = page.locator("#history .bubble.output").last();
  await expect(answer).toHaveText("PONG from the fake model. It streams word by word. Then the turn ends.");
  await expect(page.locator("#history .turn-timing:not(.live)")).toHaveCount(1);

  // The cookie: a reload (and the session list) stays in.
  await page.reload();
  await expect(answer).toHaveText("PONG from the fake model. It streams word by word. Then the turn ends.");
  const list = await page.evaluate(async () => (await fetch("/api/sessions")).status);
  expect(list).toBe(200);
  expect(errors, "page errors").toEqual([]);
});

test("a wrong token gets the 401 page, and a browser without the cookie is refused the API", async ({ chi, browser }) => {
  const context = await browser.newContext();
  const page = await context.newPage();
  const res = await page.goto(`${chi.lanURL}/?token=wrong`);
  expect(res.status()).toBe(401);
  const api = await context.request.get(`${chi.lanURL}/api/sessions`);
  expect(api.status()).toBe(401);
  // The loopback address is this machine: no token asked.
  expect((await context.request.get(`${chi.baseURL}/api/sessions`)).status()).toBe(200);
  await context.close();
});

test("a review: the owner starts one for a file and invites from the panel, the link joins over the LAN with the Plan, annotates it, a comment (a double Enter) gets one reply and comes back on ↑, the owner applies it", async ({ chi, context, browser, script }) => {
  const owner = await context.newPage();
  const errors = [];
  owner.on("pageerror", (e) => errors.push(e.message));
  script("plain");
  await owner.goto(`${chi.baseURL}/`);
  // The start page's review chip: the new session is a review of README.md.
  await owner.locator("#reviewNew").click();
  await owner.locator("#reviewNewPopover textarea").fill("README.md");
  await owner.locator("#reviewNewPopover button[type=submit]").click();
  await expect(owner.locator("#reviewNew")).toHaveText("review: README.md");
  await owner.locator("#prompt").fill("Say pong");
  await owner.locator("#actionBtn").click();
  await expect(owner).toHaveURL(/#\/s\/[0-9a-f-]+$/);
  await owner.mouse.move(0, 0);
  await expect(owner.locator("#history .bubble.output").last()).toHaveText(/PONG/);

  const chip = owner.locator("#infoText .participants-chip");
  await expect(chip).toHaveText("invite");
  await chip.click();
  await owner.locator("#participantsPopover input[name=name]").fill("Alex");
  await owner.locator("#participantsPopover .pp-invite-btn").click();
  const link = await owner.locator("#participantsPopover .pp-link input").inputValue();
  expect(link).toMatch(/\/\?token=chp_[\w-]+#s=[0-9a-f-]+$/);
  // A review session: no warning about a working session's tool outputs.
  await expect(owner.locator("#participantsPopover .pp-warning")).toHaveCount(0);
  await expect(chip).toHaveText("1 participant");

  // Another browser on the LAN address: the participant page, no owner page.
  const guest = await browser.newContext();
  const page = await guest.newPage();
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(link.replace(/^http:\/\/[^/]+/, chi.lanURL));
  await expect(page.locator("#title")).toContainText("Alex's review");
  // The Plan beside the thread: the subject's rendered markdown.
  await expect(page.locator("#planPath")).toHaveText("README.md");
  await expect(page.locator("#planDoc h1")).toHaveText("e2e project");
  await expect(page.locator("#thread .p-msg.user").first()).toContainText("Say pong");
  // The shared composer, a participant's subset: no owner composer, no `/` list.
  await expect(page.locator("#actionBtn")).toHaveCount(0);
  await expect(page.locator("#commandList")).toHaveCount(0);
  await expect(page.locator("#composeGrip")).toHaveAttribute("aria-expanded", "true");
  // Annotate: a selection in the Plan quotes it into the comment box,
  // labelled with the subject's path; nothing is sent.
  await page.locator("#planDoc h1").selectText();
  await page.locator("#annotateBar .annotate-main").click();
  await expect(page.locator("#comment")).toHaveValue("From README.md:\n> e2e project\n\n");
  await expect(page.locator("#comment")).toBeFocused();

  // A double Enter posts the comment once (the post held in flight, as on
  // a phone's slow link).
  const posts = [];
  await page.route("**/turn", async (route) => {
    posts.push(route.request().url());
    const res = await route.fetch();
    await page.waitForTimeout(400); // eslint-disable-line no-restricted-syntax -- a slow post is the case
    await route.fulfill({ response: res });
  });
  await page.locator("#comment").fill("Is step 3 safe?");
  await page.locator("#comment").press("Enter");
  await page.locator("#comment").press("Enter");
  await expect(page.locator("#thread .p-msg.user.mine")).toContainText("Is step 3 safe?");
  await expect(page.locator("#thread .p-msg.reply .p-bubble")).toHaveCount(2);
  await expect(page.locator("#thread .p-msg.user.mine")).toHaveCount(1);
  expect(posts).toHaveLength(1);
  await page.unroute("**/turn");
  await expect(page.locator("#thread .p-msg.reply .p-bubble").last()).toHaveText(/PONG from the fake model/);
  // A shell line is refused in words, before it reaches the session.
  await page.locator("#comment").fill("!ls");
  await page.locator("#send").click();
  await expect(page.locator("#error")).toHaveText("A participant can't do that: only the session's owner can.");
  // ↑ in the emptied box: this link's own comment (a refused one isn't kept), never the owner's prompts.
  await page.locator("#comment").fill("");
  await page.locator("#comment").press("ArrowUp");
  await expect(page.locator("#comment")).toHaveValue("Is step 3 safe?");

  await expect(owner.locator("#history .bubble.user.by-participant .author-badge")).toHaveText("Alex · review");
  // Apply under the review turn's reply: the owner's turn in the composer,
  // the proposal quoted, not sent.
  await owner.locator(".review-apply-btn").last().click();
  await expect(owner.locator("#prompt")).toHaveValue(/^Apply this proposal from Alex's review turn \w+, as far as it fits the plan\. [^\n]*\n\n> PONG from the fake model/);
  await guest.close();
  expect(errors, "page errors").toEqual([]);
});
