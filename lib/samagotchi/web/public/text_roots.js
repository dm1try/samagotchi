// The texts the page treats as text it wrote out of a model's words: the
// answers and the closed steps' texts. Cards, question replies, the asking
// slot and delegate reports aren't among them. markdown_place.js links refs on
// these; block_watch.js finds blocks to draw in these. A module of its own: static JS is cached
// at unversioned URLs, and a new export on an old module would blank the page.
export const TEXTS = ".bubble.output, .gen:not(.live) > .gen-text";
