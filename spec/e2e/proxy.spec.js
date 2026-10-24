// chi web behind an auth proxy (web.public_url): support/pod_proxy.rb plays
// oauth2-proxy (https, a sign-in cookie for every port, X-Forwarded-Email
// upstream, 401 {} for Accept: application/json when signed out), chi web
// trusts X-Forwarded-Email for the owner next to the token.
import fs from "node:fs";
import { test, expect } from "./support/fixtures.js";

test("the owner's fragment link signs in through the proxy, a turn streams, and a lost sign-in says so", async ({ chi, context, script }) => {
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  const token = fs.readFileSync(chi.tokenPath, "utf8").trim();

  // The proxy's sign-in (an IdP with a session) keeps the fragment; chi's
  // 401 page trades it for the __Host- cookie and loads the page without it.
  // The start page's model list: app.js runs (every module comes through
  // the proxy, a TLS connection each).
  const started = page.waitForResponse((r) => r.url().endsWith("/api/models") && r.status() === 200);
  await page.goto(`${chi.publicURL}/#token=${token}`);
  await started;
  await expect(page.locator("#actionBtn")).toHaveText("Start");
  expect(page.url()).toBe(`${chi.publicURL}/`);
  const cookies = await context.cookies(chi.publicURL);
  const chiCookie = cookies.find((c) => c.name === "__Host-chi_token");
  expect(chiCookie).toMatchObject({ secure: true, httpOnly: true, path: "/" });
  expect(chiCookie.domain).toBe(new URL(chi.publicURL).hostname);

  script("plain");
  await page.locator("#prompt").fill("Say pong");
  await page.locator("#actionBtn").click();
  await expect(page).toHaveURL(/#\/s\/[0-9a-f-]+$/);
  await page.mouse.move(0, 0);
  const answer = page.locator("#history .bubble.output").last();
  await expect(answer).toHaveText("PONG from the fake model. It streams word by word. Then the turn ends.");

  // A reload a minute ago (the stamp): the banner, not another reload. The
  // proxy ends the sign-in and cuts the streams; the list's EventSource
  // reconnects into the sign-in page and gives up.
  await page.evaluate(() => sessionStorage.setItem("chi.authReloadAt", String(Date.now())));
  await page.evaluate(() => fetch("/oauth2/expire"));
  await expect(page.locator("#authLost")).toContainText("Signed out");
  expect(errors, "page errors").toEqual([]);
});
