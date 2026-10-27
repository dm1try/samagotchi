// chi versions on the page: chi web here believes a newer chi is installed
// (SAMAGOTCHI_INSTALLED_VERSION=99.0.0) than it runs.
import fs from "node:fs";
import path from "node:path";
import { test, expect } from "./support/fixtures.js";

test.use({ installed: "99.0.0" });

test("the available update notice opens a progress sheet with kept edits", async ({ chi, context }) => {
  const page = await context.newPage();
  const errors = [];
  const requests = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await page.setViewportSize({ width: 390, height: 844 });
  await page.addInitScript(() => {
    window.eventSources = [];
    const Original = window.EventSource;
    window.EventSource = class extends Original {
      constructor(...args) {
        super(...args);
        if (String(args[0]).startsWith("/api/events")) window.eventSources.push(this);
      }
    };
  });
  await page.route("**/api/update", async (route) => {
    requests.push(JSON.parse(route.request().postData()));
    await route.fulfill({ status: 202, contentType: "application/json", body: '{"state":"running","version":"100.0.0"}' });
  });
  await page.goto(chi.baseURL + "/");

  const toast = page.locator("#toast");
  await expect(toast).toContainText("chi 99.0.0 is installed");
  await toast.locator(".toast-close").click();
  await page.evaluate(() => {
    const source = window.eventSources.at(-1);
    source.dispatchEvent(new MessageEvent("chi", {
      data: JSON.stringify({ version: document.body.dataset.version, installed: null, available: "100.0.0", update_blocked: null }),
    }));
  });
  await expect(toast).toContainText("chi 100.0.0 is available");
  await toast.getByRole("button", { name: "Update" }).click();

  const sheet = page.locator("#updateSheet");
  await expect(sheet).toBeVisible();
  await expect.poll(() => requests).toEqual([{ version: "100.0.0" }]);
  await page.evaluate(() => {
    const source = window.eventSources.at(-1);
    const publish = (name, data) => source.dispatchEvent(new MessageEvent(name, { data: JSON.stringify(data) }));
    publish("chi_update", { operation: "install", version: "100.0.0", state: "running", progress: "Installing samagotchi", rows: [] });
    publish("chi_update", {
      operation: "install", version: "100.0.0", state: "done",
      rows: [{
        component: "chi (gem)", status: "updated", from: "0.123.0", to: "100.0.0",
        kept: ["config.yml", `memories/${"edited-".repeat(18)}notes.md`],
      }],
    });
  });
  await expect(sheet).toContainText("Kept edited files");
  await expect(sheet).toContainText("config.yml");
  await expect(toast.locator(".toast-action")).toHaveText(["Restart workers", "Restart chi web"]);
  const widths = await page.evaluate(() => {
    const dialog = document.querySelector("#updateSheet");
    return {
      viewport: document.documentElement.clientWidth,
      page: document.documentElement.scrollWidth,
      dialog: dialog.getBoundingClientRect().width,
      dialogContents: dialog.scrollWidth,
      dialogClient: dialog.clientWidth,
    };
  });
  expect(widths.dialog).toBeLessThanOrEqual(390);
  expect(widths.dialogContents).toBeLessThanOrEqual(widths.dialogClient);
  expect(widths.page).toBeLessThanOrEqual(widths.viewport);
  expect(errors, "page errors").toEqual([]);
});

test("a newer chi installed: the notice restarts chi web, once, and not again after reconnect", async ({ chi, context }) => {
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
  await expect(toast.locator(".toast-action")).toHaveText(["Restart workers", "Restart chi web"]);

  // chi web restarts on the same version: the tab reconnects, and its new
  // snapshot (the same versions) brings no toast back.
  const before = await page.evaluate(() => window.snapshots);
  await toast.getByRole("button", { name: "Restart chi web" }).click();
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
