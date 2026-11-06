// The dom-null-asserts lint rule (eslint.config.js "samagotchi/dom-null-asserts"): a failing
// assert.equal(domNode, null) formats the whole happy-dom node and hangs npm test, so the forms whose actual is a
// DOM lookup are flagged, and the ones that fail fast, or whose actual isn't a node, are left.
import test from "node:test";
import assert from "node:assert/strict";
import { Linter } from "eslint";
import config from "../../../eslint.config.js";

const block = config.find((b) => b.name === "samagotchi/dom-null-asserts");

function flaggedLines(code) {
  const linter = new Linter({ configType: "flat" });
  const messages = linter.verify(code, [{
    languageOptions: { ecmaVersion: "latest", sourceType: "module" },
    rules: block.rules,
  }]);
  return messages.map((m) => {
    assert.equal(m.ruleId, "no-restricted-syntax", m.message);
    return code.split("\n")[m.line - 1].trim();
  });
}

test("an equal of a DOM lookup to null or undefined is flagged, once", () => {
  const lookups = [
    "assert.equal(el.querySelector('.x'), null);",
    "assert.equal(document.getElementById('x'), null, 'gone');",
    "assert.strictEqual(row.closest('li'), null);",
    "assert.deepEqual(pop().querySelector('form'), null);",
    "assert.equal(el?.querySelector('.x'), null);",
    "assert.equal(document.activeElement?.closest?.('.row'), null);",
    "assert.equal(h.bubbles[0].el.parentNode, null);",
    "assert.equal(fig.nextElementSibling, undefined);",
    "assert.equal(document.activeElement, null);",
  ];
  assert.deepEqual(flaggedLines(lookups.join("\n")), lookups);
});

test("the fast forms, other values and other asserts are left alone", () => {
  const fine = [
    "assert.ok(el.querySelector('.x') === null);",
    "assert.ok(!el.querySelector('.x'));",
    "assert.notEqual(el.querySelector('.x'), null);",
    "assert.equal(el.querySelector('.x').textContent, 'hi');",
    "assert.equal(el.getAttribute('aria-current'), null);",
    "assert.equal(parseBudget('lots'), null);",
    "assert.equal(el.querySelector('.x'), other);",
  ];
  assert.deepEqual(flaggedLines(fine.join("\n")), []);
});
