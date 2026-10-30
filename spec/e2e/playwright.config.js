// The web e2e suite: `npm run e2e`. One chi (fake model, temp dirs, its own
// ports) per Playwright worker, see support/fixtures.js; a worker's scenarios
// share it serially, and the workers split the scenarios test by test.
// The checkout's playwright.config.js re-exports it, so a bare `npx playwright
// test spec/e2e/...` from the root runs with it too (without it Playwright's
// defaults apply: a 5 s expect timeout, which the stage hand-offs outlast).
// Its paths are absolute for that: Playwright reads a relative one against
// the config file it loaded.
import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig, devices } from "@playwright/test";
import { privateIPv4 } from "./support/env.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  testDir: HERE,
  testMatch: "*.spec.js",
  outputDir: path.join(HERE, "../../tmp/e2e/results"),
  workers: process.env.CI ? 2 : 4,
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: 0,
  timeout: 30_000,
  expect: { timeout: 10_000 },
  reporter: process.env.CI
    ? [["list"], ["html", { outputFolder: path.join(HERE, "../../tmp/e2e/report"), open: "never" }]]
    : [["list"]],
  use: {
    ...devices["Desktop Chrome"],
    trace: "retain-on-failure",
  },
  // chromium: every scenario but the LAN's and the proxy's (a running turn
  // is in #turnStage, then handed off into #history).
  projects: [
    { name: "chromium", testIgnore: ["lan.spec.js", "proxy.spec.js"] },
    // chi web --web-host lan, reached at the LAN address: the access token.
    // On a machine without a private IPv4, chi web on loopback only: the
    // LAN tests skip and the review journey runs on loopback (lan.spec.js).
    { name: "lan", testMatch: "lan.spec.js", use: { lan: !!privateIPv4() } },
    // chi web behind an auth proxy (support/pod_proxy.rb, web.public_url).
    { name: "proxy", testMatch: "proxy.spec.js", use: { authProxy: true, ignoreHTTPSErrors: true } },
  ],
});
