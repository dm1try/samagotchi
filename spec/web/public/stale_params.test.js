import test from "node:test";
import assert from "node:assert/strict";
import { withoutStaleParams } from "../../../lib/samagotchi/web/public/stale_params.js";

test("?view= (the removed turn view's) goes; the rest of the query stays as written", () => {
  assert.equal(withoutStaleParams("?view=turn"), "");
  assert.equal(withoutStaleParams("?view=stage&dir=/Users/me/proj"), "?dir=/Users/me/proj");
  assert.equal(withoutStaleParams("?scope=all&view=turn&from=/a/b"), "?scope=all&from=/a/b");
  assert.equal(withoutStaleParams("?view"), "");
  assert.equal(withoutStaleParams("?v%69ew=turn&working_set=0"), "?working_set=0");
});

test("a query without it is left alone (null: nothing to replace)", () => {
  assert.equal(withoutStaleParams(""), null);
  assert.equal(withoutStaleParams("?dir=/a&scope=all"), null);
  assert.equal(withoutStaleParams("?preview=1"), null);
  assert.equal(withoutStaleParams(undefined), null);
});
