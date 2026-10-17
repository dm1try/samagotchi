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
