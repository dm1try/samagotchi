// A missing-name guard for the web frontend's ES modules, not a style pass:
// a name used but never imported or declared (no-undef), and an import or
// variable left unused. In the e2e specs, the unused one too, and the
// timing rule: a fixed pause (page.waitForTimeout) instead of a wait for the
// state, the twin of the Samagotchi/SpecSleep cop. And the session store's one write path (a
// write into the open session's state in place). `npm run lint`; see
// docs/testing.md.
import globals from "globals";

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
    // The service worker: a classic script in the worker's scope (self, clients).
    files: ["lib/samagotchi/web/public/sw.js"],
    languageOptions: { sourceType: "script", globals: globals.serviceworker },
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
