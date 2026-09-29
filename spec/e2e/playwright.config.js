// The web e2e suite: `npm run e2e`. One chi (fake model, temp dirs) per
// Playwright worker, see support/fixtures.js; the scenarios share it serially.
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "*.spec.js",
  outputDir: "../../tmp/e2e/results",
  workers: 1,
  fullyParallel: false,
  forbidOnly: !!process.env.CI,
  retries: 0,
  timeout: 30_000,
  expect: { timeout: 10_000 },
  reporter: process.env.CI
    ? [["list"], ["html", { outputFolder: "../../tmp/e2e/report", open: "never" }]]
    : [["list"]],
  use: {
    ...devices["Desktop Chrome"],
    trace: "retain-on-failure",
  },
  // The stage view (web.view: stage) runs the scenarios tagged @stage again
  // on ?view=stage: the running turn in #turnStage, then handed off into
  // #history.
  projects: [
    // @stage-only: the stage view's own scenarios (stage.spec.js).
    { name: "chromium", grepInvert: /@stage-only/ },
    { name: "stage", grep: /@stage/, use: { view: "stage" } },
  ],
});
