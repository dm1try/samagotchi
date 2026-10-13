import test from "node:test";
import assert from "node:assert/strict";
import {
  actionEnabled, actionLine, actionTitle, annotationActions, composerWithAction, fillTemplate, sameActions,
  selectionFields, splitInline,
} from "../../../lib/samagotchi/web/public/annotate_actions.js";

const claude = {
  name: "/claude", anytime: true, mid_turn: "anytime", source: "claude-peer",
  annotations: [{ label: "Confirm with Claude", line: "/claude validate", template: "{quote}", send: false }],
};
const validate = annotationActions([claude])[0];

test("annotationActions flattens the listing's annotations in order, with their command's mid-turn and bundle", () => {
  const commands = [
    { name: "/model", anytime: false, mid_turn: "refuse", source: "core" },
    claude,
    { name: "/foo", mid_turn: "refuse", source: "foo-bundle",
      annotations: [{ label: "Ask", line: "/foo ask", template: "{text}", send: true }, { label: "", line: "/foo" }, null] },
  ];
  assert.deepEqual(annotationActions(commands), [
    { label: "Confirm with Claude", line: "/claude validate", template: "{quote}", send: false, command: "/claude", anytime: true, source: "claude-peer" },
    { label: "Ask", line: "/foo ask", template: "{text}", send: true, command: "/foo", anytime: false, source: "foo-bundle" },
  ]);
  assert.deepEqual(annotationActions(null), []);
  assert.deepEqual(annotationActions([{ name: "/x", annotations: [{ label: "X", line: "/x" }] }])[0].template, "{quote}");
});

test("sameActions compares the pills drawn", () => {
  assert.equal(sameActions(annotationActions([claude]), annotationActions([{ ...claude }])), true);
  assert.equal(sameActions(annotationActions([claude]), []), false);
});

test("selectionFields: the quote block, the trimmed text with its indentation, the source", () => {
  const fields = selectionFields("\r\n  def x  \r\n    1\n\n", { kind: "thinking" });
  assert.deepEqual(fields, {
    quote: "From your thinking:\n>   def x\n>     1\n\n",
    text: "  def x\n    1",
    source: "thinking",
  });
  assert.equal(selectionFields(" \n ", { kind: "answer" }), null);
  assert.equal(selectionFields("x", {}).source, "answer");
});

test("fillTemplate fills {quote}, {text} and {source}; an unknown {x} stays", () => {
  const fields = { quote: "> q\n\n", text: "q", source: "tool" };
  assert.equal(fillTemplate("{source}: {text} {other} {quote}", fields), "tool: q {other} > q\n\n");
  assert.equal(fillTemplate("{text}{text}", fields), "qq");
});

test("actionLine: the command line, the filled template under it", () => {
  const fields = selectionFields("the line", { kind: "thinking" });
  assert.equal(actionLine(validate, fields), "/claude validate\nFrom your thinking:\n> the line\n\n");
});

test("composerWithAction: empty → the line; same command → the quote appended; another draft → under the quote", () => {
  const line = actionLine(validate, selectionFields("b", { kind: "answer" }));
  assert.equal(composerWithAction("", validate, line), "/claude validate\n> b\n\n");
  assert.equal(composerWithAction("  \n", validate, line), "/claude validate\n> b\n\n");
  assert.equal(composerWithAction("/claude validate\n> a\n\nwhy a?\n", validate, line),
    "/claude validate\n> a\n\nwhy a?\n\n> b\n\n");
  assert.equal(composerWithAction("my draft\nline two", validate, line), "/claude validate\n> b\n\nmy draft\nline two");
  assert.equal(composerWithAction("/claude other", validate, line), "/claude validate\n> b\n\n/claude other");
});

test("actionEnabled and actionTitle: a send pill waits for the turn unless its command is anytime", () => {
  const send = { ...validate, send: true, anytime: false, command: "/foo", label: "Ask", source: "foo" };
  assert.equal(actionEnabled(validate, true), true);
  assert.equal(actionEnabled(send, false), true);
  assert.equal(actionEnabled(send, true), false);
  assert.equal(actionEnabled({ ...send, anytime: true }, true), true);
  assert.equal(actionTitle(validate, true), "Confirm with Claude (claude-peer)");
  assert.equal(actionTitle(send, true), "Ask (foo): /foo waits for the turn to end");
  assert.equal(actionTitle(send, false), "Ask (foo): sends at once");
});

test("splitInline keeps 3 inline, the rest behind ⋯", () => {
  const list = [1, 2, 3, 4, 5];
  assert.deepEqual(splitInline(list), { inline: [1, 2, 3], more: [4, 5] });
  assert.deepEqual(splitInline([1]), { inline: [1], more: [] });
});
