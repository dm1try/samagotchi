import { expect } from "@playwright/test";

// The page doesn't scroll sideways (audit r7 web L5): at phone width wide
// content (tables, pre, popovers) must scroll inside its own box. On a
// failure the message names the first elements past the right edge.
export async function expectNoHorizontalOverflow(page) {
  const { scrollWidth, innerWidth, overflowing } = await page.evaluate(() => ({
    scrollWidth: document.documentElement.scrollWidth,
    innerWidth: window.innerWidth,
    overflowing: [...document.querySelectorAll("*")]
      .filter((el) => el.getBoundingClientRect().right > window.innerWidth)
      .map((el) => `${el.tagName.toLowerCase()}${el.id ? `#${el.id}` : ""}`)
      .slice(0, 10),
  }));
  expect(scrollWidth, `viewport ${innerWidth}px; right-overflowing elements: ${overflowing.join(", ")}`)
    .toBeLessThanOrEqual(innerWidth + 1);
}

// The bar's items (info_bar_model.js BAR_ITEMS) as the page serves them: the
// module imports lit, which needs a DOM, so it is read in the page.
const barItem = async (page, key) => page.evaluate(async (k) => {
  const { BAR_ITEMS } = await import("/assets/info_bar_model.js");
  const item = BAR_ITEMS.find((i) => i.key === k);
  return { selector: item.selector, group: item.group };
}, key);

// A session-bar item (BAR_ITEMS, by key) clicked where it is: on the row when
// it has a box there, else (folded into ⋯: display:none) through ⋯'s menu,
// its row or its action. "restart" is the worker badge's Restart (the worker
// row's own button in the menu).
export async function clickBarItem(page, key) {
  const item = key === "restart" ? { selector: ".worker-restart", group: "restart" } : await barItem(page, key);
  const chip = page.locator(`#infoBar ${item.selector}`);
  if (await chip.isVisible()) return chip.click();
  await page.locator("#infoMoreBtn").click();
  const sheet = page.locator("#moreSheet");
  const inMenu = item.group === "restart" ? sheet.locator(".more-restart")
    : item.group === "actions" ? sheet.locator(`.more-act.${key}`) : sheet.locator(`[data-row="${key}"]`);
  return inMenu.click();
}

// Whether the bar's item +key+ is on the row (has a box) or folded into ⋯.
export async function barItemOnRow(page, key) {
  const { selector } = await barItem(page, key);
  return page.locator(`#infoBar ${selector}`).isVisible();
}
