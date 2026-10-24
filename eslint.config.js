// A missing-name guard for the web frontend's ES modules, not a style pass:
// a name used but never imported or declared (no-undef), and an import or
// variable left unused. In the e2e specs, only the timing rule: a fixed
// pause (page.waitForTimeout) instead of a wait for the state, the twin of
// the Samagotchi/SpecSleep cop. `npm run lint`; see docs/testing.md.
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
    // The service worker: a classic script in the worker's scope (self, clients).
    files: ["lib/samagotchi/web/public/sw.js"],
    languageOptions: { sourceType: "script", globals: globals.serviceworker },
  },
  {
    files: ["spec/e2e/**/*.js"],
    linterOptions: { reportUnusedDisableDirectives: "error" },
    languageOptions: { ecmaVersion: "latest", sourceType: "module" },
    rules: {
      "no-restricted-syntax": ["error", {
        selector: "CallExpression[callee.property.name='waitForTimeout']",
        message: "Wait for the state (a locator's expect, data-phase, an animation's end, waitForFunction), not a fixed pause. " +
          "A pause that is the behaviour carries // eslint-disable-line no-restricted-syntax -- why.",
      }],
    },
  }
];
