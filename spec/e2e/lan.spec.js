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
