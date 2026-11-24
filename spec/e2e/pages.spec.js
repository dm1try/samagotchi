// Pages in chi web (docs/pages.md), the shared path once: the top bar's
// pages pill appears live when the first page's script is made (the hub's
// `pages` event, no reload), opens the Pages list, whose card opens the
// page; Refresh runs its script and changes the result, a script that raises
// keeps the last result under the failure line, Back returns to the list.
// All sessions has no Pages group. The page is the usage fixture of Build
// 1's specs (spec/fixtures/pages), written into this worker's config and
// removed after.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test, expect } from "./support/fixtures.js";
import { usePage } from "./support/env.js";

const FIXTURES = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../fixtures/pages");
const USAGE_RB = fs.readFileSync(path.join(FIXTURES, "usage.rb"), "utf8");
const USAGE_JSON = fs.readFileSync(path.join(FIXTURES, "usage.json"), "utf8");

test("a page: the pill appears live, opens the Pages list, a card opens the page; Refresh changes the result, a failed run keeps it under the failure line", async ({ page, chi }) => {
  await page.goto(`${chi.baseURL}/#/sessions`);
  const pill = page.locator("#pagesBtn");
  await expect(page.locator("#allView")).toBeVisible();
  await expect(pill).toBeHidden();
  let remove = () => {};
  try {
    // Making the script is what the hub sees (a run doesn't touch the scripts folder).
    remove = usePage(chi, "usage", USAGE_RB, { "usage.json": USAGE_JSON });
    await expect(pill).toBeVisible({ timeout: 10_000 });
    await expect(page.locator("#allView .pg-card")).toHaveCount(0);
    await expect(page.locator("#pagesGroup")).toBeHidden();
    await pill.click();

    await expect(page).toHaveURL(/#\/pages$/);
    await expect(pill).toHaveAttribute("aria-pressed", "true");
    const card = page.locator("#pagesList .pg-card", { hasText: "usage" });
    await expect(card).toContainText("never ran");
    await card.click();

    await expect(page).toHaveURL(/#\/p\/usage$/);
    const view = page.locator("#pageView");
    await expect(view.locator(".pg-note")).toHaveText("No result yet: Refresh runs the script.");
    await expect(page.locator("#center")).toBeHidden();

    await view.locator(".pg-refresh").click();
    await expect(view.locator(".pg-title")).toHaveText("Usage, last 7 days");
    await expect(view.locator("tfoot td").last()).toHaveText("$18.1252");
    await expect(view.locator("tbody tr").first().locator("td").first()).toHaveText("claude:sonnet-5-5");
    await expect(view.locator(".pg-meta")).toContainText("ran just now");

    const dir = path.join(chi.dirs.config, "samagotchi", "pages");
    fs.writeFileSync(path.join(dir, "usage.json"), USAGE_JSON.replace('"cost": 18.1252', '"cost": 20.5'));
    await view.locator(".pg-refresh").click();
    await expect(view.locator("tfoot td").last()).toHaveText("$20.5000");

    fs.writeFileSync(path.join(dir, "usage.rb"), 'page "Usage, last 7 days" do |ui|\n  ui.text "x"\n  nil.fetch(:a)\nend\n');
    await view.locator(".pg-refresh").click();
    await expect(view.locator(".pg-failed")).toContainText("The script failed at line 3:");
    await expect(view.locator(".pg-failed")).toContainText("Showing the result from");
    await expect(view.locator(".pg-blocks.pg-kept tfoot td").last()).toHaveText("$20.5000");

    await expect(view.locator(".pg-back")).toHaveText("← Pages");
    await view.locator(".pg-back").click();
    await expect(page).toHaveURL(/#\/pages$/);
    await expect(page.locator("#pagesList .pg-card", { hasText: "Usage, last 7 days" })).toContainText("failed just now");
  } finally {
    remove();
  }
});
