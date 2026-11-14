// chi web on the LAN (--web-host lan), reached at this machine's LAN
// address as a phone would, and on loopback: the access token is asked for
// on both. Without a private IPv4 the project's chi web is on loopback only
// (playwright.config.js): the LAN tests skip, the participant journey runs there.
import fs from "node:fs";
import { test, expect } from "./support/fixtures.js";
import { clickBarItem } from "./support/layout.js";

const NO_LAN = "no private IPv4 address on this machine";
const PNG_1PX = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==";

test.describe("on the LAN", () => {
  // Decided by the project's option alone (playwright.config.js), before
  // any fixture: a skipped test starts no chi. Each test's own check covers
  // a chi web that found no LAN address after all.
  test.skip(({ lan }) => !lan, NO_LAN);

  test("the LAN page asks for the token, the token link gets in, a turn streams and a reload stays in", async ({ chi, context, script }) => {
    test.skip(!chi.lanURL, NO_LAN);
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
    // The stage hands the turn off into the history once the pointer
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
    test.skip(!chi.lanURL, NO_LAN);
    const context = await browser.newContext();
    const page = await context.newPage();
    const res = await page.goto(`${chi.lanURL}/?token=wrong`);
    expect(res.status()).toBe(401);
    const api = await context.request.get(`${chi.lanURL}/api/sessions`);
    expect(api.status()).toBe(401);
    // This machine's loopback too (a pair participant's shell runs here),
    // but for chi's token-less /api/info probe: its checked fields only.
    expect((await context.request.get(`${chi.baseURL}/api/sessions`)).status()).toBe(401);
    const probe = await context.request.get(`${chi.baseURL}/api/info`);
    expect(probe.status()).toBe(200);
    expect(Object.keys(await probe.json())).not.toContain("cwd");
    await context.close();
  });

  test("this machine's page asks for the token too, and chi web's Local link (a one-time code) gets in", async ({ chi, browser }) => {
    test.skip(!chi.lanURL, NO_LAN);
    const context = await browser.newContext();
    const page = await context.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    const refused = await page.goto(`${chi.baseURL}/`);
    expect(refused.status()).toBe(401);
    await expect(page.locator("input[name=token]")).toBeVisible();

    // chi web's start line: this machine's link with an owner's one-time code;
    // the 401 page trades it for the cookie on 127.0.0.1 and loads the page.
    const link = fs.readFileSync(chi.webLogPath, "utf8").match(/Local: (\S+#code=chc_\S+)/)[1];
    expect(link.startsWith(`${chi.baseURL}/`)).toBe(true);
    const started = page.waitForResponse((r) => r.url().endsWith("/api/models") && r.status() === 200);
    await page.goto(link);
    await started;
    await expect(page.locator("#actionBtn")).toHaveText("Start");
    expect(page.url()).not.toContain("code=");
    // The 127.0.0.1 cookie rides to every local port: it holds the loopback
    // value, never the token.
    const cookie = (await context.cookies(chi.baseURL)).find((c) => c.name === "chi_token");
    expect(cookie).toMatchObject({ httpOnly: true });
    expect(cookie.value).toMatch(/^chl_/);
    expect(cookie.value).not.toBe(fs.readFileSync(chi.tokenPath, "utf8").trim());
    // Used up: the same link again is refused.
    const again = await browser.newContext();
    const second = await again.newPage();
    await second.goto(link);
    await expect(second.locator("#trade")).toBeVisible();
    await again.close();
    await context.close();
    expect(errors, "page errors").toEqual([]);
  });
});

test("a participant: the owner invites from the panel, warned that their turns act; the link opens the main page (over the LAN when there is one) with the history and no owner control but the image button, a message with an image (a double Enter) is queued once, starts and gets its answer, a claim link opens in Alex's browser, and Alex revises their own answer (a stack on both pages)", async ({ chi, context, browser, script }) => {
  const owner = await context.newPage();
  const errors = [];
  owner.on("pageerror", (e) => errors.push(e.message));
  script("plain");
  // Alex's browser reaches chi web at the LAN address, as a phone would; on
  // a machine without one, at loopback (a grant's token is a participant
  // from any peer: docs/internals/participants.md, The gate).
  const guestURL = chi.lanURL || chi.baseURL;
  if (chi.lanURL) {
    // The owner on this machine: the token link on loopback sets the cookie.
    const token = fs.readFileSync(chi.tokenPath, "utf8").trim();
    await owner.goto(`${chi.baseURL}/?token=${token}`);
    expect(owner.url()).toBe(`${chi.baseURL}/`);
  } else {
    // A chi web on loopback only: this machine's browser is the owner.
    await owner.goto(`${chi.baseURL}/`);
  }
  await owner.locator("#prompt").fill("Say pong");
  await owner.locator("#actionBtn").click();
  await expect(owner).toHaveURL(/#\/s\/[0-9a-f-]+$/);
  await owner.mouse.move(0, 0);
  await expect(owner.locator("#history .bubble.output").last()).toHaveText(/PONG/);

  const chip = owner.locator("#infoText .participants-chip");
  await expect(chip).toHaveText("participants · invite");
  await clickBarItem(owner, "participants");
  await owner.locator("#participantsPopover input[name=chi-invitee]").fill("Alex");
  await owner.locator("#participantsPopover .pp-invite-btn").click();
  const link = await owner.locator("#participantsPopover .pp-link input").inputValue();
  expect(link).toMatch(/\/\?token=chp_[\w-]+#s=[0-9a-f-]+$/);
  // The warning: a participant's turns act in it.
  await expect(owner.locator("#participantsPopover .pp-warning").first()).toContainText("a participant's turns act in this session");
  // No "view as a participant" any more.
  await expect(owner.locator("#participantsPopover a[href*='as=participant']")).toHaveCount(0);
  await expect(chip).toHaveText("1 participant");

  // Another browser (on the LAN address): the main page, as Alex's.
  const guest = await browser.newContext();
  const page = await guest.newPage();
  const refused = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("response", (r) => { if (r.status() === 403) refused.push(`${r.request().method()} ${r.url()}`); });
  await page.goto(link.replace(/^http:\/\/[^/]+/, guestURL));
  // The grant's session, whatever the old link's #s= said; its history.
  await expect(page.locator("#sessionTitle")).toHaveText("an untitled session");
  await expect(page.locator("#participantWho .pb-who")).toHaveText("Alex · invited");
  const ownerPrompt = page.locator("#history .bubble.user").first();
  await expect(ownerPrompt).toContainText("Say pong");
  await expect(ownerPrompt.locator(".origin-label")).toHaveText("owner");
  await expect(page.locator("#history .bubble.output").first()).toHaveText(/PONG/);
  // No owner control: no new session, list, rename, model, session menu,
  // participants; no file panel (the Plan is gone with the old page). Their
  // own images: the image button.
  await expect(page.locator("#attachBtn")).toBeVisible();
  for (const id of ["newBtn", "scope", "stripStatus", "topStrip", "titleRenameBtn", "modelPick", "infoMoreBtn",
    "infoStopBtn", "infoContinueBtn", "notifyBtn"]) {
    await expect(page.locator(`#${id}`), id).toBeHidden();
  }
  await expect(page.locator("#infoText .participants-chip")).toHaveCount(0);
  await expect(page.locator("#planPath, #planDoc")).toHaveCount(0);
  // Their own usage in the bottom row: spend of the cap.
  await expect(page.locator("#participantBar [data-key=spent]")).toHaveText(/^\$\d+\.\d\d of \$2\.00 used$/);
  await expect(page.locator("#participantBar [data-key=status]")).toHaveText("idle");

  // A double Enter posts the message once (the post held in flight, as on
  // a phone's slow link); its queued bubble clears when its turn starts,
  // and the answer arrives.
  const posts = [];
  await page.route("**/turn", async (route) => {
    posts.push(route.request().url());
    const res = await route.fetch();
    await page.waitForTimeout(400); // eslint-disable-line no-restricted-syntax -- a slow post is the case
    await route.fulfill({ response: res });
  });
  // With an image of theirs (uploaded to /images, not counted above).
  await page.locator("#attachInput").setInputFiles({ name: "step3.png", mimeType: "image/png", buffer: Buffer.from(PNG_1PX, "base64") });
  await expect(page.locator("#chips .chip")).toHaveCount(1);
  await page.locator("#prompt").fill("Is step 3 safe?");
  await page.locator("#prompt").press("Enter");
  await page.locator("#prompt").press("Enter");
  const mine = page.locator("#history .bubble.user", { hasText: "Is step 3 safe?" });
  await expect(mine).toHaveCount(1);
  await expect(mine.locator(".author-badge")).toHaveText("Alex");
  await expect(mine.locator(".thumbs img.thumb")).toHaveCount(1);
  await expect(page.locator("#history .bubble.output")).toHaveCount(2);
  await expect(page.locator("#history .bubble.output").last()).toHaveText(/PONG from the fake model/);
  await expect(page.locator(".bubble.user.queued")).toHaveCount(0);
  await expect(mine).toHaveCount(1);
  expect(posts).toHaveLength(1);
  await page.unroute("**/turn");

  await expect(owner.locator("#history .bubble.user.by-participant .author-badge")).toHaveText("Alex · pair");
  await expect(owner.locator("#history .bubble.user.by-participant .thumbs img.thumb")).toHaveCount(1);

  // A claim link: the owner selects a word of the first answer, Copy link
  // gives Alex's link to that turn and quote; Alex's browser (its cookie,
  // no token) opens it with the answer marked and the word highlighted.
  await owner.evaluate(() => {
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText: async (text) => { window.copiedLink = text; } } });
    const bubble = document.querySelector("#history .bubble.output");
    const walker = document.createTreeWalker(bubble, NodeFilter.SHOW_TEXT);
    let node = walker.nextNode();
    while (node && !node.data.includes("PONG")) node = walker.nextNode();
    const range = document.createRange();
    range.setStart(node, node.data.indexOf("PONG"));
    range.setEnd(node, node.data.indexOf("PONG") + 4);
    getSelection().removeAllRanges();
    getSelection().addRange(range);
  });
  await expect(owner.locator("#annotateBar .annotate-link")).toHaveAttribute("title", /for Alex's browser/);
  await owner.locator("#annotateBar .annotate-link").click();
  const claimLink = await owner.evaluate(() => window.copiedLink);
  expect(claimLink).toMatch(/^http:\/\/[^/]+\/#s=[0-9a-f-]+&t=[0-9a-f-]{8}&q=PONG/);
  await page.goto(claimLink.replace(/^http:\/\/[^/]+/, guestURL));
  await expect(page.locator("#history .claim-hit").first()).toBeVisible();
  expect(await page.evaluate(() => CSS.highlights.get("chi-claim")?.size)).toBe(1);
  // A reload: Alex's own image loads from the session (theirs to read back).
  await page.reload();
  const thumb = page.locator("#history .bubble.user", { hasText: "Is step 3 safe?" }).locator("img.thumb");
  await expect(thumb).toHaveAttribute("src", /\/images\/[0-9a-f]{16}\.png$/);
  await expect.poll(() => thumb.evaluate((img) => img.complete && img.naturalWidth)).toBe(1);
  // Revise (participant_revise.js): on the answer to Alex's own message
  // only, none under the owner's "Say pong"; the next message rewrites it,
  // and the first version folds into a stub on Alex's page and the owner's.
  const mineId = await page.locator("#history .bubble.user", { hasText: "Is step 3 safe?" }).getAttribute("data-turn-id");
  await expect(page.locator("#history .revise-btn")).toHaveCount(1);
  await expect(page.locator("#history .revise-btn")).toHaveAttribute("data-revise", mineId);
  await page.locator("#history .bubble.output").last().hover();
  await page.locator("#history .revise-btn").click();
  await expect(page.locator("#reviseChip .revise-chip")).toContainText("Revising:");
  await page.locator("#prompt").fill("shorter");
  await page.locator("#prompt").press("Enter");
  await expect(page.locator("#reviseChip")).toBeHidden();
  // The ended turn leaves the stage for the history once the pointer is away,
  // on each page: the owner's pointer still rests where its Copy link click
  // left it, which the stage may cover by then (a hold that never ends: the
  // CI flake of 2026-11-14).
  await page.mouse.move(0, 0);
  await owner.mouse.move(0, 0);
  await expect(page.locator("#history .stack-stub")).toHaveCount(1);
  await expect(page.locator("#history .stack-versions > summary")).toHaveText("v2 · 1 earlier");
  await expect(owner.locator("#history .stack-stub")).toHaveCount(1);
  expect(refused, "requests answered 403").toEqual([]);
  await guest.close();
  expect(errors, "page errors").toEqual([]);
});
