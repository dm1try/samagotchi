// Playwright fixtures: `chi` is the isolated chi of this worker (started
// once, torn down after the last test or a failure), `script(name)` picks the
// fake model's script, `fakeMode(mode)` makes it answer otherwise (an error;
// back to the script after the test), and `page` opens chi web's start page
// (?view=stage in the stage project: the `view` option).
import { test as base, expect } from "@playwright/test";
import { startEnv, stopEnv, useMode, useScript } from "./env.js";

export const test = base.extend({
  view: ["turn", { option: true }],

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

  fakeMode: async ({ chi }, use) => {
    try {
      await use((mode) => useMode(chi, mode));
    } finally {
      useMode(chi, "script");
    }
  },

  page: async ({ page, chi, view }, use) => {
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(chi.baseURL + (view === "stage" ? "/?view=stage" : "/"));
    await use(page);
    expect(errors, "page errors").toEqual([]);
  },
});

export { expect };
