import test from "node:test";
import assert from "node:assert/strict";
import {
  ariaLabel, BUDGETS, dirLabel, fold, footprint, footprintText, isFresh, itemsOfTurn, labelText, labelTitle, memoryNames, nextSettle,
  opsText, rowEntries, sessionItems, shown, stepRange, stepTag, urlLabel, urlOfParams,
} from "../../../lib/samagotchi/web/public/working_set.js";

const file = (path, tool = "read", status = "ok", ref = { kind: "file", path }) => ({ tool, status, title: path, ref });
const memory = (title, tool = "memory_read", status = "ok") => ({ tool, status, title });
const fetch = (url, status = "ok") => ({ tool: "web_fetch", status, params: `url=${JSON.stringify(url)}` });
const turnOf = (...gens) => ({ gens: gens.map((tools) => ({ tools })) });
const texts = (labels) => labels.map(labelText);

test("rowEntries: only an ok call counts; file tools by ref.path, memories by title, web_fetch by its url param", () => {
  for (const status of ["running", "error", "stopped", "blocked"]) assert.deepEqual(rowEntries(file("a/b.rb", "read", status)), []);
  assert.deepEqual(rowEntries(file("lib/x/a.rb")).map((e) => [e.kind, e.key, e.op]), [["file", "lib/x/a.rb", "read"]]);
  assert.deepEqual(rowEntries(file("lib/x/a.rb", "write")).map((e) => e.op), ["edit"]);
  assert.deepEqual(rowEntries(file("lib/x/a.rb", "edit")).map((e) => e.op), ["edit"]);
  // The title is cut; the ref's path is the key.
  assert.equal(rowEntries({ tool: "read", status: "ok", title: "…ng/path.rb", ref: { kind: "file", path: "/a/very/long/path.rb" } })[0].key, "/a/very/long/path.rb");
  assert.deepEqual(rowEntries(memory("a, b ,,")).map((e) => [e.kind, e.key]), [["memory", "a"], ["memory", "b"]]);
  assert.deepEqual(rowEntries(memory("")), []); // an index listing
  assert.deepEqual(rowEntries(memory("note", "memory_write")).map((e) => e.op), ["write"]);
  assert.deepEqual(rowEntries(fetch("https://x.dev/a")).map((e) => e.key), ["https://x.dev/a"]);
  assert.deepEqual(rowEntries({ tool: "execute", status: "ok", title: "cat README.md" }), []);
});

test("memoryNames: split on commas, trimmed, empty skipped", () => {
  assert.deepEqual(memoryNames("working-style,feedback-ui-polish"), ["working-style", "feedback-ui-polish"]);
  assert.deepEqual(memoryNames(" a , , b "), ["a", "b"]);
  assert.deepEqual(memoryNames(undefined), []);
});

test("urlOfParams: the inspect-quoted url param, escapes undone, a cut one kept as is", () => {
  assert.equal(urlOfParams('url="https://github.com/dm1try/samagotchi/pull/812"'), "https://github.com/dm1try/samagotchi/pull/812");
  assert.equal(urlOfParams('prompt="x" url="https://a.dev/q?x=\\"y\\""'), 'https://a.dev/q?x="y"');
  assert.equal(urlOfParams('url="https://a.dev/very/long…"'), "https://a.dev/very/long…");
  assert.equal(urlOfParams('url="https://a.dev/no-close'), "https://a.dev/no-close");
  assert.equal(urlOfParams('curl="https://no"'), null);
  assert.equal(urlOfParams(""), null);
});

test("urlLabel: host and the last two segments", () => {
  assert.equal(urlLabel("https://github.com/dm1try/samagotchi/pull/812"), "github.com/…/pull/812");
  assert.equal(urlLabel("https://x.dev/a/b"), "x.dev/a/b");
  assert.equal(urlLabel("https://x.dev"), "x.dev");
  assert.equal(urlLabel("not a url"), "not a url");
});

test("dirLabel: the path when it fits 22 characters, else …/ and its last two segments", () => {
  assert.equal(dirLabel("lib/samagotchi/llm"), "lib/samagotchi/llm/");
  assert.equal(dirLabel("lib/samagotchi/web/public"), "…/web/public/");
  assert.equal(dirLabel("spec"), "spec/");
});

test("itemsOfTurn: entry order, the first row's ordinals kept, later touches union ops and count", () => {
  const turn = turnOf(
    [file("lib/a.rb"), memory("m1")],
    [{ tool: "execute", status: "ok" }, file("lib/a.rb", "edit"), file("lib/b.rb", "read", "error")],
    [file("lib/a.rb"), fetch("https://x.dev/p")],
  );
  const items = itemsOfTurn(turn, 3);
  assert.deepEqual(items.map((i) => [i.kind, i.key, i.ops, i.count, i.at]), [
    ["file", "lib/a.rb", ["read", "edit"], 3, { turn: 3, step: 0, row: 0 }],
    ["memory", "m1", ["read"], 1, { turn: 3, step: 0, row: 1 }],
    ["url", "https://x.dev/p", ["read"], 1, { turn: 3, step: 2, row: 1 }],
  ]);
  assert.ok(items.every((i) => i.state === "live"));
  assert.deepEqual(itemsOfTurn(null, 0), []);
});

test("sessionItems: turns merged with the first entry kept; preloaded first (prompt), unexplained used memories after; muted apart", () => {
  const t0 = itemsOfTurn(turnOf([file("lib/a.rb"), memory("m1")]), 0);
  const t1 = itemsOfTurn(turnOf([], [file("lib/a.rb", "edit"), memory("pre")]), 1);
  const { items, muted } = sessionItems({ turns: [t0], live: t1, preloaded: ["pre"], muted: ["quiet"], used: ["m1", "old"] });
  assert.deepEqual(items.map((i) => [i.key, i.ops, i.count, stepTag(i, { session: true })]), [
    ["pre", ["read"], 1, "prompt"],
    ["lib/a.rb", ["read", "edit"], 2, "t1·s1"],
    ["m1", ["read"], 1, "t1·s1"],
    ["old", ["read"], 0, ""],
  ]);
  assert.deepEqual(muted.map((i) => [i.key, opsText(i)]), [["quiet", "muted (--mute)"]]);
  // The turn lists are left as they were.
  assert.deepEqual(t0[0].ops, ["read"]);
});

// The spec's §3 examples.
const files = (dir, names, edits = []) => names.map((n) => file(`${dir}/${n}`, edits.includes(n) ? "edit" : "read"));

test("fold: up to the budget, leaves in entry order (1–3 files → names)", () => {
  const items = itemsOfTurn(turnOf(files("lib/samagotchi/web/public", ["a.js", "b.js"]), [memory("m")]), 0);
  assert.deepEqual(texts(fold(items, BUDGETS.rail).labels), ["a.js", "b.js", "◆ m"]);
});

test("fold: nine files under one dir → …/web/public/ · 9 files ✎2", () => {
  const names = ["a", "b", "c", "d", "e", "f", "g", "h", "i"].map((n) => `${n}.js`);
  const items = itemsOfTurn(turnOf(files("lib/samagotchi/web/public", names, ["b.js", "e.js"])), 0);
  const { labels } = fold(items, BUDGETS.rail);
  assert.deepEqual(texts(labels), ["…/web/public/ · 9 files"]);
  assert.equal(labels[0].edited, 2);
  assert.equal(labelTitle(labels[0]).split("\n")[1], "lib/samagotchi/web/public/b.js ✎");
});

test("fold: four spread over llm/ and llm/adapters/ fold into lib/samagotchi/llm/ · 4 files", () => {
  const items = itemsOfTurn(turnOf([
    file("lib/samagotchi/llm/anthropic_messages.rb"), file("lib/samagotchi/llm/openai_chat.rb"),
    file("lib/samagotchi/llm/adapters/by_api.rb"), file("lib/samagotchi/llm/chat_loop.rb"),
    memory("a"), memory("b"),
  ]), 0);
  assert.deepEqual(texts(fold(items, BUDGETS.rail).labels), ["lib/samagotchi/llm/ · 4 files", "◆ a", "◆ b"]);
});

test("fold: groups repeat (web/public/ and llm/ side by side), then memories by kind count", () => {
  const items = itemsOfTurn(turnOf(
    files("lib/samagotchi/web/public", ["info_bar.js", "stage_view.js", "stage_slots.js"], ["info_bar.js"]),
    [memory("working-style")],
    files("lib/samagotchi/llm", ["anthropic_messages.rb", "openai_chat.rb"]),
    [memory("feedback-ui-polish"), fetch("https://github.com/dm1try/samagotchi/pull/812")],
    files("lib/samagotchi/web/public", ["format.js"]),
    [memory("feedback-per-ui-presentation")],
  ), 0);
  const { labels } = fold(items, BUDGETS.rail);
  assert.deepEqual(texts(labels), ["…/web/public/ · 4 files", "◆ 3 memories", "lib/samagotchi/llm/ · 2 files", "↗ github.com/…/pull/812"]);
  assert.equal(ariaLabel(labels), "Working set: web/public 4 files 1 edited, 3 memories, lib/samagotchi/llm 2 files, url github.com/…/pull/812. Open the list.");
});

test("fold: the last resort folds files in many dirs into N files · K dirs", () => {
  const items = itemsOfTurn(turnOf(["a/x.rb", "b/y.rb", "c/z.rb", "d/w.rb", "e/v.rb"].map((p) => file(p))), 0);
  assert.deepEqual(texts(fold(items, BUDGETS.row).labels), ["5 files · 5 dirs"]);
  // Without it (the footprint), the leaves stay and the rest is a tail.
  assert.deepEqual(texts(fold(items, BUDGETS.row, { lastResort: false }).labels), ["x.rb", "y.rb", "z.rb", "w.rb", "v.rb"]);
});

test("fold: append-only stability: a new item never reorders earlier labels; a folded group stays", () => {
  const rows = [
    file("lib/w/a.js"), memory("m1"), file("lib/w/b.js"), file("lib/w/c.js"), file("lib/w/d.js"), file("spec/x.rb"),
    memory("m2"), file("lib/w/e.js"), file("lib/k/z.rb"), fetch("https://u.dev/1"), file("lib/k/y.rb"), memory("m3"),
  ];
  let kept = [];
  let before = [];
  for (let n = 1; n <= rows.length; n += 1) {
    const items = itemsOfTurn(turnOf(rows.slice(0, n)), 0);
    const { labels, groups } = fold(items, BUDGETS.rail, { kept });
    // Every earlier group is still there.
    for (const spec of kept) assert.ok(groups.some((g) => JSON.stringify(g) === JSON.stringify(spec)), `group ${JSON.stringify(spec)} kept at ${n}`);
    // The labels that stay keep their relative order.
    const ids = labels.map((l) => l.id);
    const stayed = before.filter((id) => ids.includes(id));
    assert.deepEqual(ids.filter((id) => stayed.includes(id)), stayed, `order at ${n}`);
    kept = groups;
    before = ids;
    assert.ok(labels.length <= BUDGETS.rail);
  }
});

test("shown: the first budget − 1 labels and how many the rest hold", () => {
  const items = itemsOfTurn(turnOf([file("a.rb"), file("b.rb"), memory("m"), fetch("https://u.dev/1"), fetch("https://u.dev/2")]), 0);
  const { labels } = fold(items, 3, { lastResort: false });
  const view = shown(labels, 3);
  assert.equal(view.labels.length, 2);
  assert.equal(view.more, labels.slice(2).reduce((n, l) => n + l.n, 0));
  assert.deepEqual(shown(labels.slice(0, 2), 3), { labels: labels.slice(0, 2), more: 0 });
});

test("stepTag and stepRange: s3, t2·s3, prompt; a group's step range", () => {
  assert.equal(stepTag({ at: { turn: 1, step: 2, row: 0 } }), "s3");
  assert.equal(stepTag({ at: { turn: 1, step: 2, row: 0 } }, { session: true }), "t2·s3");
  assert.equal(stepTag({ preloaded: true, at: null }), "prompt");
  assert.equal(stepTag({ at: null }), "");
  const at = (step) => ({ at: { turn: 0, step, row: 0 } });
  assert.equal(stepRange([at(0), at(4), at(1)]), "s1–5");
  assert.equal(stepRange([at(1), at(1)]), "s2");
  assert.equal(stepRange([{ at: null }]), "");
});

test("opsText: read, read ×2, read 1–120, read, edited, written, fetched, preloaded", () => {
  const [a, b, c, u, m] = itemsOfTurn(turnOf(
    [file("a.rb"), file("a.rb"), file("b.rb"), file("b.rb", "edit"), { ...file("c.rb"), ref: { kind: "file", path: "c.rb", line: 1, end_line: 120 } }],
    [fetch("https://u.dev/1"), memory("n", "memory_write")],
  ), 0);
  assert.deepEqual([a, b, c, u, m].map(opsText), ["read ×2", "read, edited", "read 1–120", "fetched", "written"]);
  assert.equal(opsText({ preloaded: true, ops: [] }), "preloaded");
});

test("footprint: three labels, the rest as a tail, edited count; none for a turn that touched nothing", () => {
  const items = itemsOfTurn(turnOf(
    files("lib/samagotchi/web/public", ["info_bar.js", "info_bar_model.js", "stage_view.js"], ["info_bar.js", "info_bar_model.js"]),
    [memory("working-style")],
    files("lib/samagotchi/llm", ["anthropic_messages.rb", "openai_chat.rb"]),
    [memory("feedback-ui-polish"), fetch("https://github.com/dm1try/samagotchi/pull/812")],
    [], [memory("feedback-per-ui-presentation")],
  ), 0);
  const fp = footprint(items);
  assert.deepEqual(texts(fp.labels), ["…/web/public/ · 3 files", "◆ 3 memories", "lib/samagotchi/llm/ · 2 files"]);
  assert.equal(fp.tail, "+1 url");
  assert.equal(fp.edited, 2);
  assert.equal(footprintText(items), "touched …/web/public/ · 3 files · ◆ 3 memories s2–6 · lib/samagotchi/llm/ · 2 files · +1 url · edited 2");
  assert.equal(footprint([]), null);
  assert.equal(footprintText([]), "");
});

test("isFresh and nextSettle: the cue lasts FLASH_MS from an item's first sight", () => {
  assert.equal(isFresh(1000, 4999), true);
  assert.equal(isFresh(1000, 5000), false);
  assert.equal(isFresh(-Infinity, 0), false);
  assert.equal(nextSettle([1000, 3000, -Infinity], 4000), 1000);
  assert.equal(nextSettle([0], 9000), null);
});

test("ariaLabel: nothing yet, and the tail", () => {
  assert.equal(ariaLabel([]), "Working set: nothing yet. Open the list.");
  const { labels } = fold(itemsOfTurn(turnOf([file("a/b.rb", "edit")]), 0), 4);
  assert.equal(ariaLabel(labels, 2), "Working set: b.rb edited, and 2 more. Open the list.");
});

test("a file shows (and groups) by its project-relative title when the absolute ref path ends with it", () => {
  const row = { tool: "read", status: "ok", title: "lib/llm/a.rb", ref: { kind: "file", path: "/home/u/p/lib/llm/a.rb" } };
  const [e] = rowEntries(row);
  assert.deepEqual([e.key, e.path], ["/home/u/p/lib/llm/a.rb", "lib/llm/a.rb"]);
  assert.equal(rowEntries({ ...row, title: "…llm/a.rb" })[0].path, "/home/u/p/lib/llm/a.rb");
});
