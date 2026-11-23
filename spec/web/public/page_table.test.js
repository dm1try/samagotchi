// A page's table: its pure rules (page_table_model.js: cells, the sort, the
// phone's key columns) and its drawing (page_table.js: the desktop table,
// a header's sort, the phone's rows that open).
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import { cellText, countText, nextSort, numericColumn, phoneColumns, sortRows } from "../../../lib/samagotchi/web/public/page_table_model.js";
import { tableTemplate } from "../../../lib/samagotchi/web/public/page_table.js";

// The usage fixture's table as Build 1 stores it (spec/fixtures/pages/usage.rb).
const USAGE = {
  type: "table",
  columns: [{ key: "model", label: "Model" }, { key: "turns", label: "Turns", key_column: true },
            { key: "prompt", label: "Prompt", format: "count" }, { key: "cost", label: "Stored", format: "money", key_column: true }],
  rows: [["claude:sonnet-5-5", 96, 18_400_000, 14.221], ["openrouter:deepseek-v4", 141, 22_100_000, 3.9042],
         ["splash:qwen3.8-flash-next", 175, 31_700_000, 0]],
  total: ["Total", 412, 72_200_000, 18.1252],
  dropped: 0,
};

test("a cell's words follow chi page run's summary", () => {
  assert.equal(cellText(14.221, "money"), "$14.2210");
  assert.equal(cellText(0, "money"), "$0.0000");
  assert.equal(cellText(212_000, "count"), "212k");
  assert.equal(cellText(1_160_000, "count"), "1.2M");
  assert.equal(cellText(999, "count"), "999");
  assert.equal(countText(-2500), "-2.5k");
  assert.equal(cellText(null, "money"), "—");
  assert.equal(cellText(true), "true");
  assert.equal(cellText(false), "false");
  assert.equal(cellText("ok", "money"), "ok");
  assert.equal(cellText(3.5), "3.5");
});

test("the sort: numbers as numbers before text, blanks last both ways, stable", () => {
  const rows = [["a", 10], ["b", null], ["c", 9], ["d", "n/a"], ["e", 10], ["f", 100]];
  assert.deepEqual(sortRows(rows, 1, "asc").map((r) => r[0]), ["c", "a", "e", "f", "d", "b"]);
  assert.deepEqual(sortRows(rows, 1, "desc").map((r) => r[0]), ["f", "a", "e", "c", "d", "b"]);
  assert.deepEqual(sortRows(rows, null).map((r) => r[0]), ["a", "b", "c", "d", "e", "f"]);
  assert.deepEqual(rows.map((r) => r[0]), ["a", "b", "c", "d", "e", "f"], "the rows given aren't changed");
  assert.deepEqual(nextSort(null, 3, true), { index: 3, dir: "desc" });
  assert.deepEqual(nextSort(null, 0, false), { index: 0, dir: "asc" });
  assert.deepEqual(nextSort({ index: 3, dir: "desc" }, 3, true), { index: 3, dir: "asc" });
  assert.equal(numericColumn(USAGE, 1), true);
  assert.equal(numericColumn(USAGE, 0), false);
  assert.deepEqual(phoneColumns(USAGE), { keys: [1, 3], rest: [2] });
});

function drawn(block, opts) {
  const root = document.createElement("div");
  render(tableTemplate(block, opts), root);
  return root;
}
const texts = (nodes) => [...nodes].map((n) => n.textContent.replace(/\s+/g, " ").trim());

test("desktop: a real table, numbers formatted and right-aligned, the total at the bottom whatever the sort", () => {
  const sorts = [];
  const root = drawn(USAGE, { sort: { index: 3, dir: "asc" }, onSort: (i, numeric) => sorts.push([i, numeric]) });
  assert.deepEqual(texts(root.querySelectorAll("th")), ["Model", "Turns", "Prompt", "Stored ↑"]);
  assert.equal(root.querySelectorAll("th")[3].getAttribute("aria-sort"), "ascending");
  assert.ok(root.querySelectorAll("th")[0].getAttribute("aria-sort") === null);
  assert.deepEqual(texts(root.querySelectorAll("tbody td:first-child")), ["splash:qwen3.8-flash-next", "openrouter:deepseek-v4", "claude:sonnet-5-5"]);
  assert.deepEqual(texts(root.querySelectorAll("tfoot td")), ["Total", "412", "72.2M", "$18.1252"]);
  assert.equal(root.querySelector("tbody td:nth-child(4)").className, "pg-num");
  root.querySelectorAll(".pg-sort")[1].click();
  assert.deepEqual(sorts, [[1, true]]);
  assert.ok(root.querySelector(".pg-note") === null);
});

test("desktop: dropped rows are said under the table", () => {
  const root = drawn({ ...USAGE, dropped: 12 }, {});
  assert.equal(root.querySelector(".pg-note").textContent, "12 more rows were dropped");
});

test("phone: the first and key columns per row, a tap opens the rest as label and value lines, the total last", () => {
  const toggles = [];
  const root = drawn(USAGE, { phone: true, opened: new Set([1]), onToggle: (r) => toggles.push(r) });
  assert.ok(root.querySelector("table") === null);
  const rows = root.querySelectorAll(".pg-row");
  assert.equal(rows.length, 4);
  assert.deepEqual(texts(rows[0].querySelectorAll(".pg-row-main > span")), ["claude:sonnet-5-5", "Turns96", "Stored$14.2210"]);
  assert.equal(rows[0].querySelector("button").getAttribute("aria-expanded"), "false");
  assert.equal(rows[1].querySelector("button").getAttribute("aria-expanded"), "true");
  assert.deepEqual(texts(rows[1].querySelectorAll(".pg-cells span")), ["Prompt22.1M"]);
  assert.ok(rows[0].querySelector(".pg-cells") === null);
  assert.ok(rows[3].classList.contains("pg-total"));
  assert.ok(rows[3].querySelector("button") === null);
  rows[2].querySelector("button").click();
  assert.deepEqual(toggles, [2]);
});

test("phone: a table with only key columns has no rows to open", () => {
  const block = { ...USAGE, columns: USAGE.columns.map((c, i) => (i === 2 ? { ...c, key_column: true } : c)) };
  const root = drawn(block, { phone: true });
  assert.ok(root.querySelector(".pg-row button") === null);
});
