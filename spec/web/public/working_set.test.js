import test from "node:test";
import assert from "node:assert/strict";
import {
  ariaLabel, BUDGETS, dirLabel, dropRefusal, fold, footprint, footprintText, groupState, isFresh, itemsOfTurn, labelText, labelTitle, memoryNames,
  newerSnapshot, nextSettle, opsText, overlay, parseSteerLine, pendingSteers, rowEntries, sessionItems, shown, STATES, steerId, steerLine,
  stepRange, stepTag, tokensText, urlLabel, urlOfParams,
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

// ── the server's truth (P2) ──────────────────────────────────────────────

const srv = (items, at = 10) => ({ items, at });
const sItem = (kind, key, state, tokens = 0) => ({ kind, key, state, tokens, ops: ["read"], count: 1, first_id: "t1" });

test("overlay: the server's state and tokens by key; files by absolute path, memories by name, cut URLs by prefix", () => {
  const longUrl = `https://docs.example.dev/${"a".repeat(80)}`;
  const turn = itemsOfTurn(turnOf([
    file("/p/lib/a.rb"), file("lib/b.rb", "read", "ok", null), memory("style"), fetch(`${longUrl.slice(0, 79)}\u2026`), fetch("https://x.dev/new"),
  ]), 0);
  const server = srv([
    sItem("file", "/p/lib/a.rb", "stale", 1234), sItem("file", "/p/lib/b.rb", "forgotten"), sItem("memory", "style", "forgotten", 12),
    sItem("url", longUrl, "stale", 99),
  ]);
  const out = overlay(turn, server);
  assert.deepEqual(out.map((i) => [i.key.slice(0, 30), i.state, i.tokens]), [
    ["/p/lib/a.rb", "stale", 1234],
    // A title fallback (no ref) never matches the server's absolute path.
    ["lib/b.rb", "live", undefined],
    ["style", "forgotten", 12],
    [`${longUrl.slice(0, 30)}`, "stale", 99],
    // A call the server doesn't know yet (running): live.
    ["https://x.dev/new", "live", undefined],
  ]);
  // The rows' at, ops and count are never the server's.
  assert.deepEqual(out[0].at, turn[0].at);
  assert.deepEqual(out[0].ops, turn[0].ops);
  // Nothing changed: the same objects; no server: the items as they are.
  assert.equal(overlay(turn, srv([]))[0], turn[0]);
  assert.equal(overlay(turn, null), turn);
  // An unknown state is ignored (live).
  assert.equal(overlay(turn, srv([sItem("file", "/p/lib/a.rb", "weird")]))[0].state, "live");
});

test("newerSnapshot: the first one; an event always (a rollback's smaller at too); a GET unless overtaken or behind a running turn", () => {
  const a = srv([], 5);
  const b = srv([], 7);
  assert.equal(newerSnapshot(null, a), a);
  assert.equal(newerSnapshot(a, b), b);
  assert.equal(newerSnapshot(b, a), a, "a GET when idle: the conversation got shorter (a rollback) while no event came");
  const same = srv([], 7);
  assert.equal(newerSnapshot(b, same), same, "an equal at wins: a GET after an idle file change");
  // An event is the server's latest: a rollback's empty or smaller set wins.
  assert.equal(newerSnapshot(b, a, { event: true }), a);
  const emptied = srv([], 3);
  assert.equal(newerSnapshot(b, emptied, { event: true }), emptied);
  // A GET an event overtook on its way loses, whatever its at.
  assert.equal(newerSnapshot(a, b, { overtaken: true }), a);
  // A GET built while a turn runs is behind that turn's events.
  assert.equal(newerSnapshot(b, { ...a, running: true }), b);
  const running = { ...srv([], 9), running: true };
  assert.equal(newerSnapshot(b, running), running);
  // A running GET answered from the turn's last event: its at is the kept event's, so it is taken.
  const turnSet = { ...srv([], 7), running: true };
  assert.equal(newerSnapshot(b, turnSet), turnSet);
  assert.equal(newerSnapshot(b, { items: [] }), b);
  assert.equal(newerSnapshot(b, null), b);
  assert.equal(newerSnapshot(b, null, { event: true }), b);
});

test("tokensText: ~840, ~1.2k, ~12k; nothing without tokens", () => {
  assert.equal(tokensText(840), "~840");
  assert.equal(tokensText(1234), "~1.2k");
  assert.equal(tokensText(2000), "~2k");
  assert.equal(tokensText(12_400), "~12k");
  assert.equal(tokensText(undefined), "");
});

test("state marks: a group struck only when all forgotten, faded when all stale or forgotten, ✂n its forgotten members", () => {
  const items = itemsOfTurn(turnOf([file("/w/a.js"), file("/w/b.js"), file("/w/c.js"), file("/x/d.rb"), file("/y/e.rb")]), 0);
  const states = (map) => overlay(items, srv(Object.entries(map).map(([key, state]) => sItem("file", key, state))));
  const groupOf = (its) => fold(its, 3).labels[0];
  let g = groupOf(states({ "/w/a.js": "forgotten", "/w/b.js": "stale" }));
  assert.deepEqual([g.type, g.cut, g.state], ["dir", 1, "live"]);
  g = groupOf(states({ "/w/a.js": "forgotten", "/w/b.js": "stale", "/w/c.js": "stale" }));
  assert.deepEqual([g.cut, g.state], [1, "stale"]);
  g = groupOf(states({ "/w/a.js": "forgotten", "/w/b.js": "forgotten", "/w/c.js": "forgotten" }));
  assert.deepEqual([g.cut, g.state], [3, "forgotten"]);
  assert.equal(groupState([]), "live");
  // A state change never refolds: the same labels, only their marks.
  assert.deepEqual(fold(states({ "/w/a.js": "forgotten" }), 3).labels.map((l) => l.id), fold(items, 3).labels.map((l) => l.id));
  // A leaf carries its item's state; its title and spoken label say it.
  const leaf = fold(states({ "/x/d.rb": "stale" }), 3).labels[1];
  assert.deepEqual([leaf.state, leaf.cut], ["stale", 0]);
  assert.equal(labelTitle(leaf), "/x/d.rb (stale)");
  assert.match(ariaLabel(fold(states({ "/w/a.js": "forgotten", "/x/d.rb": "stale" }), 3).labels), /w 3 files 1 forgotten, d\.rb stale, e\.rb\./);
});

test("opsText and the footprint say stale and forgotten in words (colour is never alone)", () => {
  const [a, b] = overlay(itemsOfTurn(turnOf([file("/p/a.rb"), file("/p/b.rb", "edit")]), 0),
    srv([sItem("file", "/p/a.rb", "stale"), sItem("file", "/p/b.rb", "forgotten")]));
  assert.equal(opsText(a), "read · stale");
  assert.equal(opsText(b), "edited · forgotten");
  assert.equal(footprint([a, b]).forgotten, 1);
  assert.equal(footprintText([a, b]), "touched a.rb · b.rb · edited 1 · 1 forgotten");
});

// ── steering (P3a: drop / undrop) ────────────────────────────────────────

test("steer lines: the words name a file by its path, a memory as memory:NAME, a cut URL row by the server's URL", () => {
  const file = { kind: "file", key: "/p/lib/a.rb", ops: ["read"] };
  const memory = { kind: "memory", key: "style", ops: ["read"] };
  const url = { kind: "url", key: "https://x.dev/aaa…", serverKey: "https://x.dev/aaa/full", ops: ["read"] };
  assert.equal(steerLine("drop", [file, memory, url]), "/working-set drop /p/lib/a.rb memory:style https://x.dev/aaa/full");
  assert.deepEqual(parseSteerLine("/working-set drop /p/lib/a.rb memory:style https://x.dev/aaa/full"),
    { op: "drop", ids: ["file:/p/lib/a.rb", "memory:style", "url:https://x.dev/aaa/full"] });
  assert.deepEqual([file, memory, url].map(steerId), ["file:/p/lib/a.rb", "memory:style", "url:https://x.dev/aaa/full"]);
  assert.equal(parseSteerLine("/working-set"), null);
  assert.equal(parseSteerLine("/working-set pin /p/a.rb"), null);
  assert.equal(parseSteerLine("/model x"), null);
});

test("pendingSteers: queued lines in order, an op then its inverse netting to nothing", () => {
  const pending = pendingSteers(["/working-set drop /p/a.rb /p/b.rb", "/model x", "/working-set undrop /p/a.rb", "/working-set undrop memory:m"]);
  assert.deepEqual([...pending], [["file:/p/b.rb", "drop"], ["memory:m", "undrop"]]);
  assert.equal(pendingSteers([]).size, 0);
});

test("dropRefusal: a read item drops; edit-only, preloaded-only, forgotten ones say why; muted, dropped, unknown have no drop", () => {
  const item = (extra) => ({ kind: "file", key: "/p/a.rb", ops: ["read"], state: "live", tokens: 40, ...extra });
  assert.equal(dropRefusal(item()), "");
  assert.equal(dropRefusal(item({ state: "stale" })), "");
  assert.match(dropRefusal(item({ ops: ["edit"], tokens: 0 })), /^only edited/);
  assert.match(dropRefusal(item({ state: "forgotten" })), /^forgotten/);
  assert.match(dropRefusal({ kind: "memory", key: "m", ops: [], preloaded: true, state: "live" }), /^preloaded/);
  assert.equal(dropRefusal(item({ tokens: undefined })), null);
  assert.equal(dropRefusal(item({ state: "dropped" })), null);
  assert.equal(dropRefusal(item({ muted: true })), null);
});

test("the server's dropped state: overlaid, struck in a group (dropped when all are), counted apart in the footprint", () => {
  const items = itemsOfTurn(turnOf([file("/w/lib/a.rb"), file("/w/lib/b.rb")]), 0);
  const lit = overlay(items, { items: [{ kind: "file", key: "/w/lib/a.rb", state: "dropped", tokens: 12 }, { kind: "file", key: "/w/lib/b.rb", state: "forgotten", tokens: 3 }], at: 4 });
  assert.deepEqual(lit.map((i) => i.state), ["dropped", "forgotten"]);
  assert.equal(groupState([lit[0]]), "dropped");
  assert.equal(groupState(lit), "forgotten");
  assert.match(footprintText(lit), /1 forgotten · 1 dropped$/);
  assert.match(labelTitle(fold(lit, 1).labels[0]), /a\.rb \(dropped\)/);
  assert.ok(STATES.includes("dropped"));
});
