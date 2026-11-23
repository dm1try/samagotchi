// Pages in chi web (docs/pages.md), the shared path once: All sessions'
// Pages group opens a page, Refresh runs its script and changes the result,
// a script that raises keeps the last result under the failure line, Back
// returns to All sessions. The page is the usage fixture of Build 1's specs
// (spec/fixtures/pages), written into this worker's config and removed after.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test, expect } from "./support/fixtures.js";
import { usePage } from "./support/env.js";

const FIXTURES = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../fixtures/pages");
const USAGE_RB = fs.readFileSync(path.join(FIXTURES, "usage.rb"), "utf8");
const USAGE_JSON = fs.readFileSync(path.join(FIXTURES, "usage.json"), "utf8");

test("a page: opened from the Pages group, Refresh changes the result, a failed run keeps it under the failure line", async ({ page, chi }) => {
  const remove = usePage(chi, "usage", USAGE_RB, { "usage.json": USAGE_JSON });
  try {
    await page.goto(`${chi.baseURL}/#/sessions`);
    const card = page.locator("#pagesGroup .pg-card", { hasText: "usage" });
    await expect(card).toContainText("never ran");
    await expect(page.locator("#pagesGroup .pg-group-label")).toHaveText(["Pages", "Sessions"]);
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

    await view.locator(".pg-back").click();
    await expect(page).toHaveURL(/#\/sessions$/);
    await expect(page.locator("#pagesGroup .pg-card", { hasText: "Usage, last 7 days" })).toContainText("failed just now");
  } finally {
    remove();
  }
});
