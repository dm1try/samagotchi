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

test("a participant: the owner invites from the panel, the link joins over the LAN, a comment gets its reply, the owner sees their badge", async ({ chi, context, browser, script }) => {
  const owner = await context.newPage();
  const errors = [];
  owner.on("pageerror", (e) => errors.push(e.message));
  script("plain");
  await owner.goto(`${chi.baseURL}/`);
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
  await expect(chip).toHaveText("1 participant");

  // Another browser on the LAN address: the participant page, no owner page.
  const guest = await browser.newContext();
  const page = await guest.newPage();
  page.on("pageerror", (e) => errors.push(e.message));
  await page.goto(link.replace(/^http:\/\/[^/]+/, chi.lanURL));
  await expect(page.locator("#title")).toContainText("Alex's review");
  await expect(page.locator("#thread .p-msg.user").first()).toContainText("Say pong");
  await expect(page.locator("#actionBtn")).toHaveCount(0);

  await page.locator("#comment").fill("Is step 3 safe?");
  await page.locator("#send").click();
  await expect(page.locator("#thread .p-msg.user.mine")).toContainText("Is step 3 safe?");
  await expect(page.locator("#thread .p-msg.reply .p-bubble")).toHaveCount(2);
  await expect(page.locator("#thread .p-msg.reply .p-bubble").last()).toHaveText(/PONG from the fake model/);
  // A shell line is refused in words, before it reaches the session.
  await page.locator("#comment").fill("!ls");
  await page.locator("#send").click();
  await expect(page.locator("#error")).toContainText("can't start with");

  await expect(owner.locator("#history .bubble.user.by-participant .author-badge")).toHaveText("Alex · review");
  await guest.close();
  expect(errors, "page errors").toEqual([]);
});
