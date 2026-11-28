// The composer drafts' storage keys (drafts.js): a leaf module, so
// session_prefs.js can sweep the drafts with the view settings without a new
// export of its own (a new export on an old module would blank a page holding
// it cached: docs/internals/web-frontend.md).
//
// COMPOSER_DRAFT: a session's draft text, as `<key>:<session>`
// (session_prefs.js, swept with the session list). START_DRAFT: the start
// page's, one per browser, outside that sweep.
export const COMPOSER_DRAFT = "chi_composer_draft";
export const START_DRAFT = "chi_start_draft";
