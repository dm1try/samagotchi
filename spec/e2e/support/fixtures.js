// Playwright fixtures: `chi` is the isolated chi of this worker (started
// once, torn down after the last test or a failure), `script(name)` picks the
// fake model's script, `fakeMode(mode)` makes it answer otherwise (an error;
// back to the script after the test), `configExtra(yaml)` adds a test's own
// settings, `projectFile(name, text)` a file of its own in the project, and
// `page` opens chi web's start page
// (the default view, stage; ?view=turn in the turn project: the `view`
// option). The lan project's
// chi web also listens on the LAN address (the `lan` option).
import fs from "node:fs";
import path from "node:path";
import { test as base, expect } from "@playwright/test";
import { startEnv, stopEnv, useConfigExtra, useHostModels, useMode, useScript, useTurnLimit } from "./env.js";

export const test = base.extend({
  view: ["stage", { option: true }],
  // The lan project: chi web --web-host lan (lan.spec.js).
  lan: [false, { option: true, scope: "worker" }],
  // The newest chi chi web believes installed (versions.spec.js).
  installed: [null, { option: true, scope: "worker" }],

  chi: [async ({ lan, installed }, use) => {
    const env = await startEnv({ lan, installed });
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

  // turnLimit(n): turn.max_iterations for this test (the default after it).
  turnLimit: async ({ chi }, use) => {
    try {
      await use((limit) => useTurnLimit(chi, limit));
    } finally {
      useTurnLimit(chi, null);
    }
  },

  // configExtra(yaml): settings of this test's own, appended to config.yml
  // (none after it).
  configExtra: async ({ chi }, use) => {
    try {
      await use((extra) => useConfigExtra(chi, extra));
    } finally {
      useConfigExtra(chi, null);
    }
  },

  // hostModels(yaml): hosts.main.models for this test (none after it).
  hostModels: async ({ chi }, use) => {
    try {
      await use((yaml) => useHostModels(chi, yaml));
    } finally {
      useHostModels(chi, null);
    }
  },

  // projectFile(name, text): a file in the project the turns run in (the
  // worker's chi is shared), removed after the test.
  projectFile: async ({ chi }, use) => {
    const made = [];
    try {
      await use((name, text) => {
        const file = path.join(chi.dirs.project, name);
        fs.writeFileSync(file, text);
        made.push(file);
      });
    } finally {
      for (const file of made) fs.rmSync(file, { force: true });
    }
  },

  page: async ({ page, chi, view }, use) => {
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(chi.baseURL + (view === "turn" ? "/?view=turn" : "/"));
    await use(page);
    expect(errors, "page errors").toEqual([]);
  },
});

export { expect };
