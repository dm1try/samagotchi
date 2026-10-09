import test from "node:test";
import assert from "node:assert/strict";
import { tabTitle, topBarTitle } from "../../../lib/samagotchi/web/public/session_title.js";

test("topBarTitle: shown only when no visible strip card shows the title", () => {
  const title = "fix the strip";
  assert.equal(topBarTitle({ title, cardShown: true, stripHidden: false, allView: false }), "");
  assert.equal(topBarTitle({ title, cardShown: true, stripHidden: true, allView: false }), title);
  assert.equal(topBarTitle({ title, cardShown: false, stripHidden: false, allView: false }), title);
  assert.equal(topBarTitle({ title, cardShown: false, stripHidden: true, allView: false }), title);
});

test("topBarTitle: nothing in the all view or without a title", () => {
  assert.equal(topBarTitle({ title: "x", cardShown: false, stripHidden: true, allView: true }), "");
  assert.equal(topBarTitle({ title: "", cardShown: false, stripHidden: true, allView: false }), "");
  assert.equal(topBarTitle({ title: null, cardShown: false, stripHidden: false, allView: false }), "");
});

test("topBarTitle: newlines and double spaces collapse to one line", () => {
  assert.equal(topBarTitle({ title: "  a\n\nb   c ", cardShown: false, stripHidden: true, allView: false }), "a b c");
});

test("tabTitle: the base alone without a session title", () => {
  assert.equal(tabTitle({ title: "", base: "Chi · samagotchi" }), "Chi · samagotchi");
  assert.equal(tabTitle({ title: null, base: "Chi" }), "Chi");
  assert.equal(tabTitle({ title: " \n ", base: "Chi" }), "Chi");
});

test("tabTitle: the title in front of the base", () => {
  assert.equal(tabTitle({ title: "fix the strip", base: "Chi · samagotchi" }), "fix the strip · Chi · samagotchi");
  assert.equal(tabTitle({ title: "fix the strip", base: "Chi" }), "fix the strip · Chi");
});

test("tabTitle: cut at 40 chars with an ellipsis, newlines and double spaces collapsed", () => {
  const forty = "a".repeat(40);
  assert.equal(tabTitle({ title: forty, base: "Chi" }), `${forty} · Chi`);
  assert.equal(tabTitle({ title: `${forty}b`, base: "Chi" }), `${forty}… · Chi`);
  assert.equal(tabTitle({ title: "line one\n\nline  two", base: "Chi" }), "line one line two · Chi");
});
