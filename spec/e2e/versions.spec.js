// chi versions on the page: chi web here believes a newer chi is installed
// (SAMAGOTCHI_INSTALLED_VERSION=99.0.0) than it runs.
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
