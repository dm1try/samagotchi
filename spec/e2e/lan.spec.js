// chi web on the LAN (--web-host lan), reached at this machine's LAN
// address as a phone would, and on loopback: the access token is asked for
// on both.
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
  // This machine's loopback too (a pair participant's shell runs here),
  // but for chi's token-less /api/info probe: its checked fields only.
  expect((await context.request.get(`${chi.baseURL}/api/sessions`)).status()).toBe(401);
  const probe = await context.request.get(`${chi.baseURL}/api/info`);
  expect(probe.status()).toBe(200);
  expect(Object.keys(await probe.json())).not.toContain("cwd");
  await context.close();
});

test("this machine's page asks for the token too, and chi web's Local link (a one-time code) gets in", async ({ chi, browser }) => {
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

test("a review: the owner starts one for a file and invites from the panel, the link joins over the LAN with the Plan, annotates it, a comment (a double Enter) gets one reply and comes back on ↑, the owner applies it, and a claim link opens in Alex's browser, where Verify on it gets a verdict card", async ({ chi, context, browser, script }) => {
  const owner = await context.newPage();
  const errors = [];
  owner.on("pageerror", (e) => errors.push(e.message));
  script("plain");
  // The owner on this machine: the token link on loopback sets the cookie.
  const token = fs.readFileSync(chi.tokenPath, "utf8").trim();
  await owner.goto(`${chi.baseURL}/?token=${token}`);
  expect(owner.url()).toBe(`${chi.baseURL}/`);
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
  // Their own usage under the comment box: spend of the cap, queue, the link's time left, the model.
  await expect(page.locator("#usage [data-key=spent]")).toHaveText(/^\$\d+\.\d\d of \$2\.00 cap$/);
  await expect(page.locator("#usage [data-key=queued]")).toHaveText("0/3 queued");
  await expect(page.locator("#usage [data-key=expires_at]")).toHaveText("link: 7 d left");
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

  // A claim link: the owner selects a word of the first answer, Copy link
  // gives Alex's link to that turn and quote; Alex's browser (its cookie,
  // no token) opens it with the reply marked and the word highlighted.
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
  await page.goto(claimLink.replace(/^http:\/\/[^/]+/, chi.lanURL));
  await expect(page.locator("#thread .p-msg.reply .p-bubble").first()).toHaveClass(/claim-hit/);
  await expect(page.locator("#thread .claim-hit")).toBeInViewport();
  expect(await page.evaluate(() => CSS.highlights.get("chi-claim")?.size)).toBe(1);

  // Verify from a reply: Alex selects the claim in the first answer, Verify
  // sends it with that turn's anchor, and the verdict's card lands after it.
  script("verdict");
  await page.locator("#comment").fill("");
  // Alex's own comment holds no claim the server takes: the bar, no Verify.
  await page.evaluate(() => {
    const range = document.createRange();
    range.selectNodeContents(document.querySelector("#thread .p-msg.user.mine .p-bubble"));
    getSelection().removeAllRanges();
    getSelection().addRange(range);
  });
  await expect(page.locator("#annotateBar .annotate-main")).toBeVisible();
  await expect(page.locator("#annotateBar .annotate-preset", { hasText: "Verify" })).toBeHidden();
  await page.evaluate(() => {
    const bubble = document.querySelector("#thread .p-msg.reply .p-bubble");
    const walker = document.createTreeWalker(bubble, NodeFilter.SHOW_TEXT);
    let node = walker.nextNode();
    while (node && !node.data.includes("PONG")) node = walker.nextNode();
    const range = document.createRange();
    range.setStart(node, node.data.indexOf("PONG"));
    range.setEnd(node, node.data.indexOf("PONG") + 4);
    getSelection().removeAllRanges();
    getSelection().addRange(range);
  });
  await page.locator("#annotateBar .annotate-preset", { hasText: "Verify" }).click();
  await page.locator("#send").click();
  const card = page.locator("#thread .verify-verdict");
  await expect(card).toHaveClass(/confirmed/);
  await expect(card.locator(".verify-verdict-quote")).toHaveText("PONG");
  expect(await card.evaluate((node) => node.previousElementSibling === document.querySelector("#thread .p-msg.reply"))).toBe(true);
  await guest.close();
  expect(errors, "page errors").toEqual([]);
});
