// A turn test's last check: the history reads the same after a reload as it
// did live (live is the truth). The shape is the page's own module
// (/assets/history_shape.js: the normalizer and the ACCEPTED allowlist the
// opt-in reload check uses too); +allow+ names the ACCEPTED entries this
// scenario has, each with its reason there. Call it once the turn has ended
// (turnEnded: handed off into #history) and the answer has its copy button.
import { expect } from "@playwright/test";

async function shapeOf(page) {
  return page.evaluate(async () => {
    const { historyShape } = await import("/assets/history_shape.js");
    return historyShape(document.querySelector("#history"));
  });
}

async function compare(page, live, reloaded, allow) {
  return page.evaluate(async ({ live, reloaded, allow }) => {
    const { compareShapes } = await import("/assets/history_shape.js");
    return compareShapes(live, reloaded, { allow });
  }, { live, reloaded, allow });
}

// +settled(page)+ waits until a (re)loaded page shows the ended turn(s)
// (the caller's turnEnded and copy-button waits).
export async function expectSameAfterReload(page, settled, { allow = [] } = {}) {
  await settled(page);
  const live = await shapeOf(page);
  await page.reload();
  await settled(page);
  const reloaded = await shapeOf(page);
  const result = await compare(page, live, reloaded, allow);
  const lines = (shape) => shape.map((it) => `  ${it.kind}${it.cls ? `.${it.cls}` : ""} ${it.text}${it.edit ? ` [${it.edit}]` : ""}`).join("\n");
  expect(result.differences, `the history after a reload differs in: ${result.kinds.join(", ")}\n`
    + `live:\n${lines(live)}\nreloaded:\n${lines(reloaded)}`).toEqual([]);
  return { live, reloaded };
}
