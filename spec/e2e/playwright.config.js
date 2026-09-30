// The web e2e suite: `npm run e2e`. One chi (fake model, temp dirs, its own
// ports) per Playwright worker, see support/fixtures.js; a worker's scenarios
// share it serially, and the workers split the scenarios test by test.
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "*.spec.js",
  outputDir: "../../tmp/e2e/results",
  workers: process.env.CI ? 2 : 4,
  fullyParallel: true,
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
  // chromium runs every scenario on the default view (web.view: stage: the
  // running turn in #turnStage, then handed off into #history); the turn
  // project runs the ones tagged @turn again on ?view=turn.
  projects: [
    { name: "chromium", testIgnore: "lan.spec.js" },
    { name: "turn", grep: /@turn/, use: { view: "turn" }, testIgnore: ["lan.spec.js", "stage.spec.js"] },
    // chi web --web-host lan, reached at the LAN address: the access token.
    { name: "lan", testMatch: "lan.spec.js", use: { lan: true } },
  ],
});
