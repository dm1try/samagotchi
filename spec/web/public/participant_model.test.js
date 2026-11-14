import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import {
  authorSlot, authorColor, AUTHOR_SLOTS, PARTICIPANT_PREFIX, participantAuthor, isParticipantAuthor,
} from "../../../lib/samagotchi/web/public/participant_model.js";

test("participant: a participant's author is the prefix and its id, the server's Steer::PARTICIPANT_PREFIX", () => {
  assert.equal(participantAuthor("p_1"), "p:p_1");
  const steer = readFileSync(new URL("../../../lib/samagotchi/steer.rb", import.meta.url), "utf8");
  assert.equal(steer.match(/PARTICIPANT_PREFIX = "([^"]*)"/)[1], PARTICIPANT_PREFIX);
});

test("participant: only p:-prefixed authors are participants; missing and other authors are the owner", () => {
  assert.equal(isParticipantAuthor("p:reviewer"), true);
  for (const author of ["", null, undefined, "owner", "ownerish", "reviewer", 1]) assert.equal(isParticipantAuthor(author), false);
});

test("participant: no other web script spells the author prefix by hand", () => {
  const dir = new URL("../../../lib/samagotchi/web/public/", import.meta.url);
  const spelled = readdirSync(dir).filter((name) => name.endsWith(".js") && name !== "participant_model.js")
    .filter((name) => /[`"']p:(\$\{|["'`])/.test(readFileSync(new URL(name, dir), "utf8")));
  assert.deepEqual(spelled, []);
});

test("participant: an author's colour slot is stable per id and in range; the owner has their own colour", () => {
  assert.equal(authorSlot("p:p_1"), authorSlot("p:p_1"));
  for (const id of ["p:p_1", "p:p_2", "p:p_abcdef12", ""]) {
    const slot = authorSlot(id);
    assert.ok(slot >= 1 && slot <= AUTHOR_SLOTS, `${id}: ${slot}`);
  }
  assert.equal(authorColor(undefined), "var(--author-owner)");
  assert.equal(authorColor("owner"), "var(--author-owner)");
  assert.match(authorColor("p:p_1"), /^var\(--author-[1-6]\)$/);
});
