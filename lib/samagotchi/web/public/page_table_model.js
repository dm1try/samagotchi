// A page's table as data (docs/pages.md): a cell's shown text, the sort and
// the phone's key columns. Pure: page_table.js draws them. The cells stay
// raw in the stored page (a number is a number), so the sort compares
// numbers as numbers; the words follow `chi page run`'s summary
// (PageCommand.cell): money $0.0000, count 1.2k / 3.4M, nil —.

export const BLANK = "—";

// 1.2k / 3.4M; under 1000 as it is (PageCommand.count).
export function countText(value) {
  if (Math.abs(value) < 1000) return String(value);
  const [n, unit] = Math.abs(value) < 1_000_000 ? [value / 1000, "k"] : [value / 1_000_000, "M"];
  return `${n.toFixed(1).replace(/\.0$/, "")}${unit}`;
}

// A cell as the page shows it.
export function cellText(value, format) {
  if (value === null || value === undefined) return BLANK;
  if (typeof value !== "number") return String(value);
  if (format === "money") return `$${value.toFixed(4)}`;
  if (format === "count") return countText(value);
  return String(value);
}

// Whether column +index+ holds numbers (a format, or every cell that isn't
// blank a number): right-aligned, sorted high first.
export function numericColumn(block, index) {
  const column = block.columns[index] || {};
  if (column.format) return true;
  const cells = (block.rows || []).map((row) => row[index]).filter((v) => v !== null && v !== undefined);
  return cells.length > 0 && cells.every((v) => typeof v === "number");
}

// The rows sorted by column +index+, +dir+ "asc" or "desc": numbers before
// text (numbers as numbers, text by locale), blanks last either way, rows
// that compare equal in their order (stable). The total is no row: it stays
// at the bottom. A null +index+ keeps the script's order.
export function sortRows(rows, index, dir = "asc") {
  if (index === null || index === undefined) return rows.slice();
  const sign = dir === "desc" ? -1 : 1;
  const rank = (v) => {
    if (v === null || v === undefined || v === "") return 2;
    return typeof v === "number" ? 0 : 1;
  };
  return rows.map((row, at) => ({ row, at })).sort((a, b) => {
    const x = a.row[index];
    const y = b.row[index];
    const rx = rank(x);
    const ry = rank(y);
    if (rx !== ry) return rx - ry;
    let order = 0;
    if (rx === 0) order = x - y;
    else if (rx === 1) order = String(x).localeCompare(String(y));
    return order === 0 ? a.at - b.at : sign * order;
  }).map(({ row }) => row);
}

// The next sort after a click on column +index+: a new column starts high
// first for numbers and A to Z for text; the same column flips.
export function nextSort(sort, index, numeric) {
  if (sort && sort.index === index) return { index, dir: sort.dir === "desc" ? "asc" : "desc" };
  return { index, dir: numeric ? "desc" : "asc" };
}

// The columns a phone's row shows besides the first: those the script (or
// the builder's default) marked key_column; the rest open on a tap.
// @return {keys: [index], rest: [index]}
export function phoneColumns(block) {
  const keys = [];
  const rest = [];
  (block.columns || []).forEach((column, i) => {
    if (i === 0) return;
    (column.key_column ? keys : rest).push(i);
  });
  return { keys, rest };
}
