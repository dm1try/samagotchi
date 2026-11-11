import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { CONTACT_WORDS, noContactFill } from "../../../lib/samagotchi/web/public/no_contact_fill.js";

const PUBLIC = join(dirname(fileURLToPath(import.meta.url)), "../../../lib/samagotchi/web/public");

test("noContactFill: autocomplete off and the name given; autocorrect only for prose", () => {
  const input = document.createElement("input");
  assert.equal(noContactFill(input, "chi-pick-note"), input);
  assert.equal(input.getAttribute("autocomplete"), "off");
  assert.equal(input.name, "chi-pick-note");
  assert.equal(input.getAttribute("autocorrect"), null);
  const area = noContactFill(document.createElement("textarea"), "chi-card-note", { prose: true });
  assert.equal(area.getAttribute("autocomplete"), "off");
  assert.equal(area.getAttribute("autocorrect"), "on");
  assert.equal(area.name, "chi-card-note");
});

test("noContactFill: a name with a contact word in it is refused", () => {
  for (const bad of ["name", "chi-name", "email", "session-title", "phone", "address"]) {
    assert.throws(() => noContactFill(document.createElement("input"), bad), /reads as a contact field/, bad);
  }
  for (const ok of ["chi-session-label", "chi-invitee", "chi-invitee-account", "cap", "dir", "budget"]) {
    assert.doesNotMatch(ok, CONTACT_WORDS, ok);
  }
});

// The <input …> and <textarea …> tags written in the page's sources (HTML
// and lit-html templates), each up to its own > (one inside a ${…} doesn't
// end it).
function tagsIn(source) {
  const tags = [];
  const start = /<(input|textarea)\b/g;
  let m;
  while ((m = start.exec(source))) {
    let depth = 0;
    let i = m.index;
    for (; i < source.length; i++) {
      if (source.startsWith("${", i)) { depth++; i++; } else if (depth && source[i] === "}") depth--;
      else if (!depth && source[i] === ">") break;
    }
    tags.push(source.slice(m.index, i + 1));
  }
  return tags;
}

const attr = (tag, name) => tag.match(new RegExp(`\\s${name}="([^"$]*)"`))?.[1];
const NOT_TEXT = new Set(["checkbox", "radio", "file", "hidden", "submit", "button", "range", "color"]);

test("every text field in the page's markup says it isn't a contact field", () => {
  const files = readdirSync(PUBLIC).filter((f) => /\.(js|html)$/.test(f));
  const fields = files.flatMap((f) => tagsIn(readFileSync(join(PUBLIC, f), "utf8")).map((tag) => ({ f, tag })))
    .filter(({ tag }) => !NOT_TEXT.has(attr(tag, "type")) && !/\sreadonly\b/.test(tag));
  assert.ok(fields.length >= 10, `found ${fields.length}`);
  const wrong = fields.filter(({ tag }) => {
    const name = attr(tag, "name");
    if (attr(tag, "autocomplete") !== "off" || !name) return true;
    return [name, attr(tag, "placeholder"), attr(tag, "aria-label")].some((w) => w && CONTACT_WORDS.test(w));
  });
  assert.deepEqual(wrong.map(({ f, tag }) => `${f}: ${tag}`), []);
});
