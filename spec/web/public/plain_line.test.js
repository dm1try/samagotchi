import test from "node:test";
import assert from "node:assert/strict";
import { plainLine, plainText } from "../../../lib/samagotchi/web/public/plain_line.js";

test("plainLine: markdown syntax out of a line, the words kept", () => {
  assert.equal(plainLine("## Plan"), "Plan");
  assert.equal(plainLine("###### Deep"), "Deep");
  assert.equal(plainLine("| file | change |"), "file · change");
  assert.equal(plainLine("| settings.conf | **beta** to 3 |"), "settings.conf · beta to 3");
  assert.equal(plainLine("|---|---|"), "");
  assert.equal(plainLine("| :--- | ---: |"), "");
  assert.equal(plainLine("```ruby"), "");
  assert.equal(plainLine("~~~"), "");
  assert.equal(plainLine("---"), "");
  assert.equal(plainLine("I check **two files** and the `config` key, per [the docs](https://example.com/docs)."),
    "I check two files and the config key, per the docs.");
  assert.equal(plainLine("> - [x] done _now_, *really*"), "done now, really");
  assert.equal(plainLine("![a chart](chart.png) and <https://example.com/x>"), "a chart and https://example.com/x");
});

test("plainLine: a numbered item's number goes, a number in prose stays", () => {
  assert.equal(plainLine("1. **A**: keep the port"), "A: keep the port");
  assert.equal(plainLine("12) second"), "second");
  assert.equal(plainLine("2026. was a year"), "was a year");
  assert.equal(plainLine("In 2026. we shipped"), "In 2026. we shipped");
  assert.equal(plainLine("3.5 is the version"), "3.5 is the version");
});

test("plainLine: mid-stream leftovers go, code-ish text stays", () => {
  assert.equal(plainLine("**Bold start"), "Bold start");
  assert.equal(plainLine("see [the docs](https://exa"), "see the docs");
  assert.equal(plainLine("snake_case_name and `__init__.py`, `**kwargs`"), "snake_case_name and __init__.py, **kwargs");
  assert.equal(plainLine("2 * 3 * 4 is 24"), "2 * 3 * 4 is 24");
  assert.equal(plainLine("use a || b here"), "use a || b here");
});

test("plainText: one line, each line plain, syntax-only and blank lines gone, a fence's code kept as written", () => {
  const md = "## Decision needed\n\nThe `port` differs:\n\n- **A**: keep [8080](https://x.test)\n- **B**: use 9090\n\n```sh\nls **/*.rb\n```\n> Pick one.";
  assert.equal(plainText(md), "Decision needed · The port differs: A: keep 8080 · B: use 9090 · ls **/*.rb · Pick one.");
  assert.equal(plainText("I found two config files.\nThey disagree on the port."), "I found two config files. They disagree on the port.");
  assert.equal(plainText("He said \"go.\"\nSo I went"), "He said \"go.\" So I went");
  assert.equal(plainText(""), "");
  assert.equal(plainText(null), "");
});
