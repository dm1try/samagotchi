# Inline widgets: chi-ui blocks the page draws

A model can write a ```` ```chi-ui ```` fence in an answer: YAML, `type:` first, a **picks** (rows of options to choose
from, which fill the reply) or a **walk** (a scenario stepped through). Core draws it, not a bundle: the server parses
the YAML once and the page draws from the parsed data. Where it doesn't draw (the terminal, `web.markdown` off, a
refused block) the YAML reads as text. This page is the server half; the page half comes with the drawers.

## The path

1. `Web::MarkdownRenderer#fences` walks the `code_block` nodes, as for block renderers' `data-lang`
   ([block-renderers.md](block-renderers.md), The path), keeping each one's language and its literal
   (`string_content`, the source between the fences, also inside a list item or a blockquote) as a `Fence`.
2. After sanitize's walk, `mark_languages` pairs them with the `<pre>`s by position and, for a `chi-ui` one, calls
   `InlineWidgets.parse(literal)`. The block gets `data-widget` (the JSON of the data with its `type`) or
   `data-widget-error` (the one-line reason), and `data-widget-lenient` when the lenient pass was needed. A count
   that differs sets nothing, as for `data-lang`.
3. Every HTML path goes through `render`, so answers, cards, delegate reports and `/api/render` all carry the
   attributes; which of them draw is the page's choice (answer texts only).
4. `chi-ui` is `BlockRenderers::RESERVED`: a bundle's `block_renderers:` can't claim it, so the page never has two
   drawers for one block.

**Safety.** The JSON is an attribute value: Nokogiri escapes its quotes, and `<`, `>` and `&` in it are `\u` escapes
(`JSON_MARKUP`), so the HTML holds no model markup even as attribute text. The page draws its strings as text.

## The parse (`Samagotchi::InlineWidgets`)

Pure Ruby, no web, no Engine. `parse(source)` returns a `Result`: `ok?`, `type`, `data` (string keys, JSON-ready),
`lenient?`, `error`, and `widget_json`.

- **Strings stay strings.** The YAML is never loaded: `Tree` reads Psych's node tree and takes each scalar's own text.
  YAML 1.1 would make `- no` false (a real eval block has one), `id: 1.10` the float 1.1, and a date a `Date` that
  `safe_load` refuses. A plain empty value, `~` or `null` is absent.
- **Plain data only.** An anchor, an alias or a tag (`!ruby/object`, `!!str`) is refused, as is a second document, a
  key that isn't a scalar, a root that isn't a mapping, text that isn't valid UTF-8, and nesting past 8 levels
  (`MAX_DEPTH`; the deepest legal block nests 6). A stack overflow is rescued too, as the backstop: it is no
  `StandardError`, so it would escape `render` and break every render of the history.
- **Strict first, then the lenient pass.** Only a block Psych can't parse gets `Lenient.quote` and a second parse.
  The pass is eval 0013's (`~/.claude/plans/evals/0013-inline-widgets/scripts/validate.rb`): the free-text values
  (`title text why does sees behind when recommended`) and the list items that aren't mappings go in double quotes
  unless they are one clean scalar already. It mends the traps models fell into: a colon in a value
  (`does: Asked: ...`), a colon in an option (`- B: keep 1 h`), a value starting with a quoted word
  (`text: "x" is called`). It is line by line, so a YAML error's line still points at the source. It can't mend a
  comma in a flow list (`options: [A allow, B deny project, allow system]` is three options, so the recommended one
  isn't one of them: eval round 1's failures), and a block that parses strictly into the wrong shape isn't retried.
- **Folds.** A block that parses strictly can still have an option or a free-text value that YAML read as a mapping
  of one pair of scalars (`- fix now: drop the command`). Where text is wanted (an option, `title`, `text`, `why`,
  `does`, `sees`, `behind`, `when`, `recommended`), that mapping is taken as the text written: the source slice from
  the key to the value's end when both sit on one line, else `key: value`. The Result is then `lenient?`. A mapping
  of several pairs, or one holding a list or a mapping, stays an error, and so does one where an id, an actor, a
  `next` or a `goto` goes. This is a mend, not a second lenient pass (`Tree#folds`, `Schema#text`).
- **Normalised.** Ids are strings, unknown keys are dropped, optional values are absent rather than null, and text is
  stripped. The page never sees model junk.

### The schemas

| | Required | Optional | Rules |
|---|---|---|---|
| picks | `rows`: rows of `id`, `text`, `options` (2-4 texts) | `title`; on a row `recommended`, `why` | ids unique; `recommended` is one of the options |
| walk | `title`, `actors` (2-5 texts), `steps`: steps of `id`, `actor`, `does` or `sees` | on a step `behind`, `next`, `cases` (each `when` + `goto`) | ids unique; actors unique; `actor` is one of the actors; `next` and every `goto` name a step |

Eval round 1's `branches:` (the same shape as `cases:`) is read as `cases`.

### The caps

The source is at most 16 KB, checked before the parse. After it: a picks has at most 12 rows, a walk at most 30 steps
and 2-5 unique actors, and every string is at most 300 characters. An error repeats at most 40 characters of a bad
`type`, and never a tag.

## The fixtures

`spec/fixtures/inline_widgets/` holds eval 0013's 78 real blocks (47 from round 2, 31 from round 1), one file each,
and `manifest.yml`, the outcome (ok, lenient or error) the eval's `check()` gave each when they were copied, but for
r2-deepseek-picks-review.2: its options are one-pair mappings, an error in the eval, and a fold (lenient) here.
`spec/inline_widgets_spec.rb` checks every one gets it: all 47 of round 2's draw, and round 1's errors are the
comma splits.
