// Playwright fixtures: `chi` is the isolated chi of this worker (started
// once, torn down after the last test or a failure), `script(name)` picks the
// fake model's script, `fakeMode(mode)` makes it answer otherwise (an error;
// back to the script after the test), `configExtra(yaml)` adds a test's own
// settings, `projectFile(name, text)` a file of its own in the project, and
// `page` opens chi web's start page. The lan project's
// chi web also listens on the LAN address (the `lan` option).
import fs from "node:fs";
import path from "node:path";
import { test as base, expect } from "@playwright/test";
import { startEnv, stopEnv, useConfigExtra, useHostModels, useMode, useScript, useTurnLimit } from "./env.js";

export const test = base.extend({
  // The stage's working set (web.working_set, on by default; false:
  // ?working_set=0, the mem chip's page).
  workingSet: [true, { option: true }],
  // The lan project: chi web --web-host lan (lan.spec.js).
  lan: [false, { option: true, scope: "worker" }],
  // The newest chi chi web believes installed (versions.spec.js).
  installed: [null, { option: true, scope: "worker" }],
  // The proxy project: chi web behind support/pod_proxy.rb (proxy.spec.js).
  authProxy: [false, { option: true, scope: "worker" }],
  // The stage's check (stage.spec.js): a "stage: waiting …" console warning
  // (card_kinds.js warnDiffers: the data and the node disagree) fails the
  // test, and so does a drift at its end: the stage's waiting cards as data
  // (stage_waiting.js, read off the stage's node: stage_view.js chiWaiting)
  // against the cards in its slots.
  stageCheck: [false, { option: true }],

  chi: [async ({ lan, installed, authProxy }, use) => {
    const env = await startEnv({ lan, installed, proxy: authProxy });
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

  page: async ({ page, chi, workingSet, stageCheck }, use) => {
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    const waitingWarnings = [];
    if (stageCheck) {
      page.on("console", (m) => { if (m.type() === "warning" && m.text().startsWith("stage: waiting")) waitingWarnings.push(m.text()); });
    }
    await page.goto(chi.baseURL + (workingSet ? "/" : "/?working_set=0"));
    await use(page);
    expect(errors, "page errors").toEqual([]);
    expect(waitingWarnings, "the stage's waiting cards as data agree with the cards drawn").toEqual([]);
    if (stageCheck && !page.isClosed()) expect(await stageDrift(page), "the stage's waiting cards as data agree with its slots").toEqual([]);
  },
});

// The stage's drift (fixtures' stageCheck): the keys the registry holds with no
// waiting card in the stage's extras or tail, and the waiting cards there with
// no entry, read with the page's own stage_waiting.js (the same module
// instance: its URL next to app.js). [] when the page has no stage.
async function stageDrift(page) {
  return page.evaluate(async () => {
    const stage = document.getElementById("turnStage");
    if (!stage?.chiWaiting) return [];
    const app = document.querySelector('script[type="module"][src$="app.js"]');
    const { waitingKey, waitingKind } = await import(new URL("stage_waiting.js", app.src).href);
    const slots = [...(stage.querySelector(".ts-extras")?.children || []), ...(stage.querySelector(".ts-tail")?.children || [])];
    const kinds = new Map(slots.map((el) => [waitingKey(el), waitingKind(el)]).filter(([key, kind]) => key && kind));
    const keys = new Set(stage.chiWaiting().map((e) => e.key));
    return [...[...keys].filter((key) => !kinds.has(key)), ...[...kinds.keys()].filter((key) => !keys.has(key))];
  });
}

export { expect };
