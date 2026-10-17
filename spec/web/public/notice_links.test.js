// A hook notice line's http(s) URLs as links (notice_links.js): the rest
// stays text, escaped by lit.
import { markupOf } from "./dom_shim.js";
import { readFileSync } from "node:fs";
import test from "node:test";
import assert from "node:assert/strict";
import { html } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";
import { linkedLine } from "../../../lib/samagotchi/web/public/notice_links.js";

const URL_ENDS = JSON.parse(readFileSync(new URL("../../fixtures/url_ends.json", import.meta.url), "utf8"));
const A = 'target="_blank" rel="noopener noreferrer"';
const link = (href, shown = href) => `<a ${A} href="${href}">${shown}</a>`;
const markup = (text) => markupOf(html`<div>${linkedLine(text)}</div>`);
const linkedUrls = (text) => Array.from(markup(text).matchAll(/href="([^"]+)"/g), ([, href]) => href);

test("a line with no URL is the string itself", () => {
  assert.equal(linkedLine("h: nothing to link"), "h: nothing to link");
  assert.equal(linkedLine(""), "");
  assert.equal(linkedLine(null), null);
});

test("one URL is a link, the text around it stays text", () => {
  assert.equal(markup("see https://example.com/a now"), `<div>see ${link("https://example.com/a")} now</div>`);
  assert.equal(markup("HTTPS://Example.com/a"), `<div>${link("https://example.com/a", "HTTPS://Example.com/a")}</div>`);
});

test("the sources line: each URL a link, the commas and the tail outside them", () => {
  const line = "source-links: sources: JIRA JIRA-1 → https://x.com/browse/JIRA-1, JIRA JIRA-2 → https://x.com/browse/JIRA-2, … +3 more";
  assert.equal(markup(line),
               `<div>source-links: sources: JIRA JIRA-1 → ${link("https://x.com/browse/JIRA-1")}, ` +
               `JIRA JIRA-2 → ${link("https://x.com/browse/JIRA-2")}, … +3 more</div>`);
});

test("the URL's end: trailing punctuation and an unbalanced ) are cut, a balanced one kept", () => {
  assert.equal(markup("(https://x.com/a)"), `<div>(${link("https://x.com/a")})</div>`);
  assert.equal(markup("https://x.com/Foo_(bar)"), `<div>${link("https://x.com/Foo_(bar)")}</div>`);
  assert.equal(markup("go to https://x.com/a."), `<div>go to ${link("https://x.com/a")}.</div>`);
  assert.equal(markup("https://x.com/a, b"), `<div>${link("https://x.com/a")}, b</div>`);
  assert.equal(markup("https://x.com/a)."), `<div>${link("https://x.com/a")}).</div>`);
  assert.equal(markup("<https://x.com/a>"), `<div>&lt;${link("https://x.com/a")}&gt;</div>`);
  assert.equal(markup("[https://x.com/a]"), `<div>[${link("https://x.com/a")}]</div>`);
});

test("shared URL-end cases link the fixture's web URLs", () => {
  for (const row of URL_ENDS.rows) assert.deepEqual(linkedUrls(row.text), row.js_urls, row.text);
});

test("other schemes, userinfo and bare schemes stay text", () => {
  for (const text of ["javascript:alert(1)", "ftp://x.com/a", "https://user@evil.example/", "https://", "data:text/html,<b>x</b>"]) {
    const out = linkedLine(text);
    assert.doesNotMatch(markup(text), /<a /, text);
    if (!/https?:\/\/\S/i.test(text)) assert.equal(out, text);
  }
});

test("markup in the line stays text", () => {
  assert.equal(markup('<b>x</b> https://x.com/a?q="<i>"'),
               `<div>&lt;b&gt;x&lt;/b&gt; ${link("https://x.com/a?q=")}"&lt;i&gt;"</div>`);
});
