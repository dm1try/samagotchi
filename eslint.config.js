// A missing-name guard for the web frontend's ES modules, not a style pass:
// a name used but never imported or declared (no-undef), and an import or
// variable left unused. `npm run lint`; see docs/testing.md.
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
  }
];
