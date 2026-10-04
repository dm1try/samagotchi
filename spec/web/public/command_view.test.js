import test from "node:test";
import assert from "node:assert/strict";
import { commandBlockHtml, rowHover } from "../../../lib/samagotchi/web/public/command_view.js";
import { copyButtonHtml } from "../../../lib/samagotchi/web/public/copy.js";

const COPY = copyButtonHtml("code");

test("commandBlockHtml: the command as written, escaped, with a copy button", () => {
  assert.equal(commandBlockHtml({ command: "cd /p && rg -n '<a>' lib |\n  head -5" }),
    `<div class="activity-command code-wrap"><pre><code>cd /p &amp;&amp; rg -n '&lt;a&gt;' lib |\n  head -5</code></pre>${COPY}</div>`);
});

test("commandBlockHtml: the call's cwd as given, above the command", () => {
  assert.equal(commandBlockHtml({ command: "npm test", cwd: "web/<x>" }),
    `<div class="activity-command code-wrap"><div class="activity-command-cwd">in <span>web/&lt;x&gt;</span></div>` +
    `<pre><code>npm test</code></pre>${COPY}</div>`);
});

test("commandBlockHtml: a cut command says how much of it is shown, outside the copied code", () => {
  const html = commandBlockHtml({ command: "x".repeat(8000), truncated: true, chars: 12345 });
  assert.match(html, /<\/pre><button[^]*<\/button><div class="activity-command-cut">… \(8,000 of 12,345 chars\)<\/div><\/div>$/);
});

test("commandBlockHtml: nothing for a call without a view", () => {
  assert.equal(commandBlockHtml(undefined), "");
  assert.equal(commandBlockHtml(null), "");
  assert.equal(commandBlockHtml({ command: "" }), "");
});

test("rowHover: the full command, else the params behind a title, else nothing", () => {
  assert.equal(rowHover({ title: "rg foo", params: 'command="cd /p && rg foo"', view: { command: "cd /p &&\nrg foo" } }), "cd /p &&\nrg foo");
  assert.equal(rowHover({ title: "lib/a.rb", params: 'path="/p/lib/a.rb"' }), 'path="/p/lib/a.rb"');
  assert.equal(rowHover({ params: 'id="t1"' }), "");
  assert.equal(rowHover(undefined), "");
});

test("copyButtonHtml: the markup the copy observer's button has", () => {
  assert.match(copyButtonHtml("code"), /^<button type="button" class="copy-btn copy-code" title="Copy code" aria-label="Copy code"><svg/);
});
