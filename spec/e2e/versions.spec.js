// chi versions on the page: chi web here believes a newer chi is installed
// (SAMAGOTCHI_INSTALLED_VERSION=99.0.0) than it runs.
import fs from "node:fs";
import path from "node:path";
import { test, expect } from "./support/fixtures.js";
import { restartWeb } from "./support/env.js";

test.use({ installed: "99.0.0" });

test("a newer chi installed: the page says to restart chi web, once, and not again after a reconnect", async ({ chi, context }) => {
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  // Counts the events stream's snapshots: one per (re)connect.
  await page.addInitScript(() => {
    window.snapshots = 0;
    const Original = window.EventSource;
    window.EventSource = class extends Original {
      constructor(...args) {
        super(...args);
        if (String(args[0]).startsWith("/api/events")) this.addEventListener("snapshot", () => { window.snapshots += 1; });
      }
    };
  });
  await page.goto(chi.baseURL + "/");

  const toast = page.locator("#toast");
  await expect(toast).toBeVisible();
  await expect(toast).toContainText("chi 99.0.0 is installed; this chi web runs");
  await expect(toast).toContainText("Restart it: Ctrl-C in its terminal, then chi web");
  await expect(toast.locator(".toast-action")).toHaveCount(0); // nothing the page could do
  await toast.locator(".toast-close").click();
  await expect(toast).toBeHidden();

  // chi web restarts on the same version: the tab reconnects, and its new
  // snapshot (the same versions) brings no toast back.
  const before = await page.evaluate(() => window.snapshots);
  await restartWeb(chi);
  await expect.poll(() => page.evaluate(() => window.snapshots), { timeout: 15_000 }).toBeGreaterThan(before);
  await expect(toast).toBeHidden();
  expect(errors, "page errors").toEqual([]);
});

// The running turn sits in the stage (the default view), then moves into
// the history.
const H = ":is(#history, #turnStage)";

async function turnEnded(page, turns) {
  await page.mouse.move(0, 0);
  await expect(page.locator("#history .turn-timing:not(.live)")).toHaveCount(turns);
  await expect(page.locator("#actionBtn")).toHaveText("Send");
  await expect(page.locator("#actionBtn")).toBeEnabled();
}

function sidecar(chi, id) {
  return JSON.parse(fs.readFileSync(path.join(chi.dirs.state, "samagotchi", "sessions", id, "bridge.json"), "utf8"));
}

test("a worker on an older chi: the badge's Restart moves the session to a new worker, the draft stays, the next turn answers", async ({ page, chi, script }) => {
  script("plain");
  await page.locator("#prompt").fill("Say pong");
  await page.locator("#actionBtn").click();
  await expect(page).toHaveURL(/#\/s\/[0-9a-f-]+$/);
  await turnEnded(page, 1);
  const id = page.url().match(/#\/s\/([0-9a-f-]+)$/)[1];
  const before = sidecar(chi, id);

  const badge = page.locator("#infoBar .worker-badge");
  await expect(badge).toContainText(`chi ${before.version}`);
  await expect(badge).toHaveAttribute("title", /chi 99\.0\.0 is installed/);

  await page.locator("#prompt").fill("a draft I keep");
  let asked = "";
  page.once("dialog", (dialog) => {
    asked = dialog.message();
    dialog.accept();
  });
  await badge.locator(".worker-restart").click();
  await expect(page.locator("#toast")).toContainText("Restarted on chi");
  expect(asked).toContain("Restart this session's worker on chi 99.0.0");
  const after = sidecar(chi, id);
  expect(after.started_at).not.toBe(before.started_at);
  await expect(page.locator("#prompt")).toHaveValue("a draft I keep");

  // The page follows the new worker: the next turn streams its answer.
  await page.locator("#prompt").fill("Say pong again");
  await page.locator("#actionBtn").click();
  await expect(page.locator(`${H} .bubble.user`).last()).toContainText("Say pong again");
  await turnEnded(page, 2);
  await expect(page.locator(`${H} .bubble.output`).last()).toContainText("PONG from the fake model");
});
