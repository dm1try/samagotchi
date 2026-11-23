// A page's table block as a lit template (docs/pages.md; page_table_model.js
// has its rules). Desktop: a real <table> in a box that scrolls sideways
// when it must, a column header sorts by that column (aria-sort), numbers
// right-aligned in tabular figures, the total row at the bottom whatever
// the sort, "N more rows were dropped" under it. Phone (decision D2 A): each
// row shows its first column and the key columns, and a tap opens the rest
// as label and value lines; rows keep the script's order there (no sort on
// a phone); the total is the last row. The view (page_view.js) keeps the
// sort and the opened rows; a cell reaches the page as text only.
import { html, nothing } from "./vendor/lit-html.js";
import { BLANK, cellText, numericColumn, phoneColumns, sortRows } from "./page_table_model.js";

const ARIA = { asc: "ascending", desc: "descending" };
const ARROW = { asc: " ↑", desc: " ↓" };

function cell(row, index, block) {
  const text = cellText(row?.[index], block.columns[index]?.format);
  return text === BLANK ? html`<span class="pg-blank">${BLANK}</span>` : text;
}

function droppedLine(block) {
  const n = Number(block.dropped) || 0;
  if (n <= 0) return nothing;
  return html`<div class="pg-note">${n === 1 ? "1 more row was dropped" : `${n} more rows were dropped`}</div>`;
}

function desktop(block, { sort, onSort }) {
  const columns = block.columns || [];
  const numeric = columns.map((_c, i) => numericColumn(block, i));
  const rows = sortRows(block.rows || [], sort ? sort.index : null, sort?.dir);
  const cls = (i) => (numeric[i] && i > 0 ? "pg-num" : "");
  const line = (row, className = "") => html`<tr class=${className}>${columns.map((_c, i) => html`<td class=${cls(i)}>${cell(row, i, block)}</td>`)}</tr>`;
  return html`<div class="pg-table">
    <div class="pg-scroll"><table>
      <thead><tr>${columns.map((column, i) => {
        const on = sort && sort.index === i ? sort.dir : null;
        return html`<th class=${cls(i)} aria-sort=${on ? ARIA[on] : nothing}><button type="button" class="pg-sort"
          @click=${() => onSort(i, numeric[i])}>${String(column.label ?? column.key ?? "")}${on ? ARROW[on] : ""}</button></th>`;
      })}</tr></thead>
      <tbody>${rows.map((row) => line(row))}</tbody>
      ${Array.isArray(block.total) ? html`<tfoot>${line(block.total, "pg-total")}</tfoot>` : nothing}
    </table></div>
    ${droppedLine(block)}
  </div>`;
}

function phone(block, { opened, onToggle }) {
  const columns = block.columns || [];
  const { keys, rest } = phoneColumns(block);
  const label = (i) => String(columns[i]?.label ?? columns[i]?.key ?? "");
  const shown = (row) => html`<span class="pg-k">${cell(row, 0, block)}</span>${keys.map((i) => html`<span class="pg-kv"><span class="pg-lab">${label(i)}</span>${cell(row, i, block)}</span>`)}`;
  const style = `--pg-keys:${keys.length}`;
  return html`<div class="pg-table">
    <div class="pg-rows" role="list">
      ${(block.rows || []).map((row, r) => {
        const open = opened.has(r);
        if (!rest.length) return html`<div class="pg-row" role="listitem"><div class="pg-row-main" style=${style}>${shown(row)}</div></div>`;
        return html`<div class="pg-row ${open ? "open" : ""}" role="listitem">
          <button type="button" class="pg-row-main" style=${style} aria-expanded=${open ? "true" : "false"}
            @click=${() => onToggle(r)}>${shown(row)}</button>
          ${open ? html`<div class="pg-cells">${rest.map((i) => html`<span><em>${label(i)}</em>${cell(row, i, block)}</span>`)}</div>` : nothing}
        </div>`;
      })}
      ${Array.isArray(block.total) ? html`<div class="pg-row pg-total" role="listitem"><div class="pg-row-main" style=${style}>${shown(block.total)}</div></div>` : nothing}
    </div>
    ${droppedLine(block)}
  </div>`;
}

// +phone+: the page's phone width; +sort+ {index, dir} or null and
// +onSort(index, numeric)+; +opened+ a Set of opened rows and +onToggle(row)+.
export function tableTemplate(block, { phone: narrow = false, sort = null, onSort = () => {}, opened = new Set(), onToggle = () => {} } = {}) {
  return narrow ? phone(block, { opened, onToggle }) : desktop(block, { sort, onSort });
}
