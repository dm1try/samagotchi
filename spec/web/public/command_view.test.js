import test from "node:test";
import assert from "node:assert/strict";
import { commandBlockHtml, heredocChip, rowHover, stepTextHtml, stepsHtml } from "../../../lib/samagotchi/web/public/command_view.js";
import { copyButtonHtml } from "../../../lib/samagotchi/web/public/copy.js";

const COPY = copyButtonHtml("code");

test("commandBlockHtml: the command as written, escaped, with a copy button", () => {
  assert.equal(commandBlockHtml({ command: "cd /p && rg -n '<a>' lib |\n  head -5" }),
    `<div class="activity-command code-wrap"><pre><code>cd /p &amp;&amp; rg -n '&lt;a&gt;' lib |\n  head -5</code></pre>${COPY}</div>`);
});

test("commandBlockHtml: the whole description first when the row's title cut it, never in place of the command", () => {
  const view = { command: "ls", description: "List <the> files in the project root and count them, then a little more" };
  assert.equal(commandBlockHtml(view, "List <the> files in the project root and count them, then…"),
    `<div class="activity-command code-wrap"><div class="activity-command-desc">List &lt;the&gt; files in the project root and count them, then a little more</div>` +
    `<pre><code>ls</code></pre>${COPY}</div>`);
  assert.equal(commandBlockHtml({ command: "ls", description: "List files" }, "List files"),
    `<div class="activity-command code-wrap"><pre><code>ls</code></pre>${COPY}</div>`);
  assert.match(commandBlockHtml({ ...view, steps: [{ text: "ls" }] }, "List…"),
    /^<div class="activity-command code-wrap has-steps"><div class="activity-command-desc">List &lt;the&gt;[^<]*<\/div><div class="activity-command-head bare">/);
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

test("commandBlockHtml: a view with steps shows them, the cd as an in tag, a raw toggle, the raw command kept for raw and copy", () => {
  const html = commandBlockHtml({ command: "cd /p && rg x | head -5", cwd: "lib", cd: "/p", steps: [{ text: "rg x", limit: "head 5" }] });
  assert.equal(html,
    `<div class="activity-command code-wrap has-steps"><div class="activity-command-head">` +
    `<span class="activity-command-cwd">in <span>lib</span> <span class="activity-command-sep">›</span> <span>/p</span></span>` +
    `<label class="activity-command-raw" title="Show the command as written"><input type="checkbox">raw</label></div>` +
    `<ol class="activity-steps"><li class="activity-step"><span class="step-op"></span><span class="step-body"><code>rg x</code>` +
    `<span class="step-chip" title="output limited">head 5</span></span></li></ol>` +
    `<pre><code>cd /p &amp;&amp; rg x | head -5</code></pre>${COPY}</div>`);
});

test("commandBlockHtml: steps with no in tag get the raw toggle alone, no empty head line", () => {
  const html = commandBlockHtml({ command: "ls", steps: [{ text: "ls" }] });
  assert.match(html, /^<div class="activity-command code-wrap has-steps"><div class="activity-command-head bare"><label class="activity-command-raw"[^]*?raw<\/label><\/div><ol /);
  assert.doesNotMatch(html, /activity-command-cwd/);
});

test("commandBlockHtml: the fallback (no steps, or none parsed) is the raw block alone, a cd not shown apart", () => {
  const plain = `<div class="activity-command code-wrap"><pre><code>for f in *; do :; done</code></pre>${COPY}</div>`;
  assert.equal(commandBlockHtml({ command: "for f in *; do :; done" }), plain);
  assert.equal(commandBlockHtml({ command: "for f in *; do :; done", steps: [], cd: "/p" }), plain);
});

test("commandBlockHtml: a cut command with steps keeps its cut line", () => {
  const html = commandBlockHtml({ command: "ls", truncated: true, chars: 9000, steps: [{ text: "ls" }] });
  assert.match(html, /<div class="activity-command-cut">… \(2 of 9,000 chars\)<\/div><\/div>$/);
});

test("stepsHtml: ops between steps, labels as headings, limit and heredoc chips, all escaped", () => {
  const html = stepsHtml([
    { text: "git status", label: "<git>" },
    { text: "a", op: "&&" }, { text: "b", op: "||" }, { text: "c", op: "|" }, { text: "d", op: "&" },
    { text: "git commit -m \"$(cat <<'EOF')\"", op: "\n", heredoc: { tag: "EOF", lines: 1 } },
    { text: "cat > x <<J", op: ";", heredoc: { tag: "J", lines: 34 } }
  ]);
  assert.equal(html,
    `<ol class="activity-steps"><li class="step-label">&lt;git&gt;</li><li class="activity-step"><span class="step-op"></span><span class="step-body"><code>git status</code></span></li>` +
    `<li class="activity-step"><span class="step-op" title="&amp;&amp;">→</span><span class="step-body"><code>a</code></span></li>` +
    `<li class="activity-step"><span class="step-op else" title="||">else</span><span class="step-body"><code>b</code></span></li>` +
    `<li class="activity-step"><span class="step-op" title="|">→</span><span class="step-body"><code>c</code></span></li>` +
    `<li class="activity-step"><span class="step-op" title="after starting the step before in the background">&amp;</span><span class="step-body"><code>d</code></span></li>` +
    `<li class="activity-step"><span class="step-op" title="new line">→</span><span class="step-body"><code>git commit -m &quot;$(cat &lt;&lt;'EOF')&quot;</code>` +
    `<span class="step-chip heredoc" title="a heredoc: its text in the raw command">EOF · 1 line</span></span></li>` +
    `<li class="activity-step"><span class="step-op" title=";">→</span><span class="step-body"><code>cat &gt; x &lt;&lt;J</code>` +
    `<span class="step-chip heredoc" title="a heredoc: its text in the raw command">J · 34 lines</span></span></li></ol>`);
});

test("heredocChip: the first heredoc and +N for the others, all of them in the hover", () => {
  assert.equal(heredocChip({ text: "x" }), "");
  assert.equal(heredocChip({ heredoc: { tag: "EOF", lines: 3 } }),
    `<span class="step-chip heredoc" title="a heredoc: its text in the raw command">EOF · 3 lines</span>`);
  const two = { heredoc: { tag: "EOF", lines: 3 }, heredocs: [{ tag: "EOF", lines: 3 }, { tag: "T", lines: 1 }] };
  assert.equal(heredocChip(two),
    `<span class="step-chip heredoc" title="2 heredocs: EOF · 3 lines, T · 1 line; their text in the raw command">EOF · 3 lines +1</span>`);
  const three = { heredoc: { tag: "<A>", lines: 1 }, heredocs: [{ tag: "<A>", lines: 1 }, { tag: "B", lines: 2 }, { tag: "C", lines: 4 }] };
  assert.match(heredocChip(three), /title="3 heredocs: &lt;A&gt; · 1 line, B · 2 lines, C · 4 lines; their text in the raw command">&lt;A&gt; · 1 line \+2<\/span>$/);
  // A one-entry heredocs: (not sent today) reads as the one heredoc.
  assert.equal(heredocChip({ heredoc: { tag: "EOF", lines: 2 }, heredocs: [{ tag: "EOF", lines: 2 }] }),
    `<span class="step-chip heredoc" title="a heredoc: its text in the raw command">EOF · 2 lines</span>`);
});

test("stepTextHtml: dims redirections to and from nowhere, leaves real ones", () => {
  assert.equal(stepTextHtml("rg x 2>&1"), `rg x <span class="step-plumbing">2&gt;&amp;1</span>`);
  assert.equal(stepTextHtml("rspec </dev/null 2>/dev/null"),
    `rspec <span class="step-plumbing">&lt;/dev/null</span> <span class="step-plumbing">2&gt;/dev/null</span>`);
  assert.equal(stepTextHtml("a &>/dev/null"), `a <span class="step-plumbing">&amp;&gt;/dev/null</span>`);
  assert.equal(stepTextHtml("echo x > out.txt"), "echo x &gt; out.txt");
  assert.equal(stepTextHtml("echo 2>&1x"), "echo 2&gt;&amp;1x");
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
