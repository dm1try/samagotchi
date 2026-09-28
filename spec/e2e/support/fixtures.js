// Playwright fixtures: `chi` is the isolated chi of this worker (started
// once, torn down after the last test or a failure), `script(name)` picks the
// fake model's script, and `page` opens chi web's start page.
import { test as base, expect } from "@playwright/test";
import { startEnv, stopEnv, useScript } from "./env.js";

export const test = base.extend({
  chi: [async ({}, use) => {
    const env = await startEnv();
    try {
      await use(env);
    } finally {
      await stopEnv(env);
    }
  }, { scope: "worker", timeout: 60_000 }],

  script: async ({ chi }, use) => {
    await use((name) => useScript(chi, name));
  },

  page: async ({ page, chi }, use) => {
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(chi.baseURL + "/");
    await use(page);
    expect(errors, "page errors").toEqual([]);
  },
});

export { expect };
