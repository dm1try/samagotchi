// A missing-name guard for the web frontend's ES modules, not a style pass:
// a name used but never imported or declared (no-undef), and an import or
// variable left unused. In the e2e specs, the unused one too, and the
// timing rule: a fixed pause (page.waitForTimeout) instead of a wait for the
// state, the twin of the Samagotchi/SpecSleep cop. And the session store's one write path (a
// write into the open session's state in place), and the modules' size caps (every module's, app.js's own). `npm run lint`; see
// docs/testing.md. In the web unit specs, one rule: no assert.equal(domNode, null), which hangs when it fails.
import globals from "globals";

// assert.equal / strictEqual / deepEqual (…, null | undefined) whose actual is a DOM lookup: a method that returns a
// node or null, or a node's own link to another, optional chaining included.
function domNullAssertSelectors() {
  const lookups = "querySelector|closest|getElementById|elementFromPoint";
  const links = "firstChild|lastChild|firstElementChild|lastElementChild|parentNode|parentElement|nextSibling|" +
    "previousSibling|nextElementSibling|previousElementSibling|activeElement|offsetParent|shadowRoot";
  const call = "CallExpression[callee.object.name='assert'][callee.property.name=/^(equal|strictEqual|deepEqual|deepStrictEqual)$/]";
  const actuals = [
    `[arguments.0.callee.property.name=/^(${lookups})$/]`,
    `[arguments.0.expression.callee.property.name=/^(${lookups})$/]`,
    `[arguments.0.property.name=/^(${links})$/]`,
    `[arguments.0.expression.property.name=/^(${links})$/]`,
  ];
  const expecteds = ["[arguments.1.type='Literal'][arguments.1.raw='null']", "[arguments.1.type='Identifier'][arguments.1.name='undefined']"];
  return actuals.flatMap((actual) => expecteds.map((expected) => call + actual + expected));
}

export default [
  { ignores: ["lib/samagotchi/web/public/vendor/"] },
  {
    files: ["lib/samagotchi/web/public/**/*.js"],
    linterOptions: { reportUnusedDisableDirectives: "error" },
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      globals: globals.browser
    },
    rules: {
      "no-undef": "error",
      "no-unused-vars": ["error", { args: "none", caughtErrors: "none", ignoreRestSiblings: true }]
    }
  },
  {
    // One write path for the open session's state (docs/internals/web-frontend.md, "The session store"): the
    // modules that hold it write through the store (update, setStatus, replaceCurrent), never in place. Scoped to
    // them: elsewhere `current` is another thing (turn_model.js genFor's gen). An alias (`const st = state();
    // st.x = …`) isn't caught: the doc's rule covers it.
    name: "samagotchi/session-writes",
    files: [
      "lib/samagotchi/web/public/app.js",
      "lib/samagotchi/web/public/stream_handlers.js",
      "lib/samagotchi/web/public/send_turn.js",
      "lib/samagotchi/web/public/session_actions.js",
      "lib/samagotchi/web/public/start_page.js",
      "lib/samagotchi/web/public/working_set_view.js",
      "lib/samagotchi/web/public/owner_verify.js",
      "lib/samagotchi/web/public/session_sync.js",
      "lib/samagotchi/web/public/session_view.js",
    ],
    rules: {
      "no-restricted-syntax": ["error", ...[
        "AssignmentExpression[left.object.name='current']",
        "AssignmentExpression[left.object.object.name='current']",
        "AssignmentExpression[left.object.callee.name='state']",
        "AssignmentExpression[left.object.object.callee.name='state']",
        "AssignmentExpression[left.object.property.name='current'][left.object.object.name='store']",
        "AssignmentExpression[left.object.object.property.name='current'][left.object.object.object.name='store']",
        "UpdateExpression[argument.object.name='current']",
        "UnaryExpression[operator='delete'][argument.object.name='current']",
        "CallExpression[callee.object.name='Object'][callee.property.name='assign'][arguments.0.name='current']",
        "CallExpression[callee.object.name='Object'][callee.property.name='assign'][arguments.0.property.name='current']",
      ].map((selector) => ({
        selector,
        message: "The open session's state is written through the store (store.update, setStatus, replaceCurrent), " +
          "so its redraws follow: see session_fields.js.",
      }))],
    },
  },
  {
    // Every module's size cap, counted as `wc -l` counts (blank lines and comments too): about 10% over the largest
    // (turn_block.js, 1078 lines), so no module becomes the next app.js. A module near it splits; never raise it
    // (docs/internals/web-frontend.md). app.js's own cap below wins for its file.
    name: "samagotchi/module-size",
    files: ["lib/samagotchi/web/public/**/*.js"],
    rules: {
      "max-lines": ["error", { max: 1200, skipBlankLines: false, skipComments: false }],
    },
  },
  {
    // app.js's size cap, counted the same way. The cap is ratcheted down when a refactor shrinks app.js, and new
    // features go into their own module: never raise it, extract instead (docs/internals/web-frontend.md).
    name: "samagotchi/app-size",
    files: ["lib/samagotchi/web/public/app.js"],
    rules: {
      "max-lines": ["error", { max: 1649, skipBlankLines: false, skipComments: false }],
    },
  },
  {
    // The stage (docs/internals/web-frontend.md, "The stage's modules"): a new stage feature goes into its own
    // stage_<feature>.js, wired in a few lines; each module resets itself from emptySlots. Every stage_*.js module's
    // cap: 500. stage_view.js's own (the wiring, refresh, the lifecycle, the event API) was 1144 lines before its
    // features moved out; it is ratcheted down with each move (its size + 30): never raise it, extract instead.
    name: "samagotchi/stage-size",
    files: ["lib/samagotchi/web/public/stage_*.js"],
    rules: {
      "max-lines": ["error", { max: 500, skipBlankLines: false, skipComments: false }],
    },
  },
  {
    name: "samagotchi/stage-view-size",
    files: ["lib/samagotchi/web/public/stage_view.js"],
    rules: {
      "max-lines": ["error", { max: 999, skipBlankLines: false, skipComments: false }],
    },
  },
  {
    // The service worker: a classic script in the worker's scope (self, clients).
    files: ["lib/samagotchi/web/public/sw.js"],
    languageOptions: { sourceType: "script", globals: globals.serviceworker },
  },
  {
    // A failing assert.equal(domNode, null) never fails: node's assert formats the happy-dom node it got, whose
    // object graph (its document, its window) takes minutes and gigabytes, so `npm test` hangs instead of naming the
    // test. Caught where the actual is a DOM lookup by its shape (a querySelector, a closest, a parentElement…); a
    // helper that returns a node (`h.input()`) isn't, the doc's rule covers it (docs/testing.md).
    name: "samagotchi/dom-null-asserts",
    files: ["spec/web/public/**/*.js"],
    linterOptions: { reportUnusedDisableDirectives: "error" },
    languageOptions: { ecmaVersion: "latest", sourceType: "module" },
    rules: {
      "no-restricted-syntax": ["error", ...domNullAssertSelectors().map((selector) => ({
        selector,
        message: "A failing assert.equal(domNode, null) hangs npm test (node formats the whole happy-dom node): " +
          "write assert.ok(x === null) (or === undefined).",
      }))],
    },
  },
  {
    files: ["spec/e2e/**/*.js"],
    linterOptions: { reportUnusedDisableDirectives: "error" },
    languageOptions: { ecmaVersion: "latest", sourceType: "module" },
    rules: {
      "no-unused-vars": ["error", { args: "none", caughtErrors: "none", ignoreRestSiblings: true }],
      "no-restricted-syntax": ["error", {
        selector: "CallExpression[callee.property.name='waitForTimeout']",
        message: "Wait for the state (a locator's expect, data-phase, an animation's end, waitForFunction), not a fixed pause. " +
          "A pause that is the behaviour carries // eslint-disable-line no-restricted-syntax -- why.",
      }],
    },
  }
];
