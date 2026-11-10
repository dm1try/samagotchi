# Inline widgets: chi-ui blocks the page draws

A model can write a ```` ```chi-ui ```` fence in an answer: YAML, `type:` first, a **picks** (rows of options to choose
from, which fill the reply) or a **walk** (a scenario stepped through). Core draws it, not a bundle: the server parses
the YAML once and the page draws from the parsed data. Where it doesn't draw (the terminal, `web.markdown` off, a
refused block) the YAML reads as text. The server half (the parse) and the page half (the drawers) are below.

What tells the model the blocks exist is the shipped inline-widgets bundle
([bundles.md](../bundles.md#the-inline-widgets-bundle)): two prompt sections, `picks` and `walk`, each with an example
its spec holds to a strict parse. Without it nothing here changes, and blocks already in a history still draw.

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
(`JSON_MARKUP`), so `data-widget`'s JSON holds no model markup even as attribute text. `data-widget-error` is not
escaped that way: a refusal quotes model values (`recommended "<b>z</b>" isn't one of its options`), so it can hold a raw
`<` or `>` inside its quoted value. The page reads it only as data (`failBlock`'s dataset, CSS, `aria-label`), never as
markup, and no consumer should treat rendered HTML with a regex. The page draws all strings as text.

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
- **Normalised.** Ids are strings, unknown keys are dropped, a repeated key is last-wins (`Tree#mapping`), optional values are absent rather than null, and text is
  stripped. The page never sees model junk.

### The schemas

| | Required | Optional | Rules |
|---|---|---|---|
| picks | `rows`: rows of `id`, `text`, `options` (2-4 texts) | `title`; on a row `recommended`, `why` | ids unique; a row's options unique; `recommended` is one of the options |
| walk | `title`, `actors` (2-5 texts), `steps`: steps of `id`, `actor`, `does` or `sees` | on a step `behind`, `next`, `cases` (each `when` + `goto`) | ids unique, none of them `end`; actors unique; `actor` is one of the actors; `next` names a step or is `end`, and not the step itself; every `goto` names a step, its own included (a retry, as models write it: the page draws that case disabled, "this step") |

Eval round 1's `branches:` (the same shape as `cases:`) is read as `cases`.

**`next: end`** ends the walk at that step: a branch that ends early, such as a success step written before the
error step it must not run into. The normalised JSON keeps `"next": "end"`, and the page shows the step as the last
one (its "end" tag, then "Start over"). A `goto` can't be `end`. In YAML:

```yaml
  - id: s4
    actor: user
    sees: the saved form
    next: end
```

### The caps

The source is at most 16 KB, checked before the parse. After it: a picks has at most 12 rows, a walk at most 30 steps
and 2-5 unique actors, and every string is at most 300 characters. An error repeats at most 40 characters of a bad
`type`, and never a tag.

## The page (`inline_widgets.js`)

`createWidgetDrawer` is a core drawer of `block_watch.js` (its header has the contract), wired in `app.js` ahead of the
bundles' frame drawer through `createBlockHost`'s `drawers`. So a `chi-ui` block gets the watcher's paths: a reload, a
session switch, a turn's end, Revise's clones, the stage's hand-off to `#history`.

- **What it draws.** A `<pre>` with `data-widget` gets a light-DOM `<figure class="block-drawn widget">` right before it,
  holding a `.widget-host` and the shared `.block-toggle` (block_source.js `setSourceShown`, the same icon; the
  figure's `data-toggle-picture` makes its other label "Show the widget"). The `<pre>` stays, hidden: the DOM is the state, copy.js gives it its `.code-wrap`
  copy button (it copies the YAML, which is the answer's text), and the toggle shows it. The toggle is in the light DOM
  because a click in a shadow root reaches the page's delegated listeners retargeted at the host.
- **Shadow DOM.** The host has an open shadow root holding the widget, with `widgets.css` adopted
  (`adoptedStyleSheets`): the page fetches it once into a constructable `CSSStyleSheet` (`loadWidgetSheet`), and `draw`
  returns a Promise that places the widget once it is there, so no widget flashes unstyled and the view held
  (`holdingView`) measures the styled one. A failed fetch draws unstyled and the next draw tries again. Its words are then out of the bubble's `textContent`, which the shown-texts dedupe (`seedSeenFromDom`), copy's
  fallback and an annotation's quote read, as with a renderer's `<img>`-only figure. chi's `:root` tokens reach it as
  inherited custom properties, so light and dark follow the page. Playwright's locators pierce an open shadow root;
  `page.evaluate`'s DOM calls don't. Whatever asks `document.activeElement` whether a field has the focus looks
  through shadow roots (`composer_fold.js editable`, `stage_watch.js`), or typing in a note opens a folded composer.
- **A clone redraws.** `cloneNode` doesn't copy a shadow root: a Revise clone (`revise_switch.js viewOf`) arrives with
  the figure and an empty host, which `needsDraw` sees, and `draw` fills it again with a fresh widget and its own
  listeners. A widget's position and picks live in the widget, so a clone or a rewrite starts over (accepted for v1).
- **A refused block** (`data-widget-error`) stays source under `failBlock`'s muted `.block-note` ("Couldn't draw this
  chi-ui block: …", an attribute CSS shows, a click copies it). Bad JSON or an unknown `type` fails the same way, from
  the watcher. A `chi-ui` `<pre>` with neither attribute (an older server) is left alone.
- **walk** (`widget_walk.js`): the swimlane (one column per actor, one row per step; the current, seen and a hovered
  case's target marked; a click jumps), the step card (actor, `does`, "You see", the dashed "Behind it"), a fork's
  "Which case?" buttons, Back / Next / Start over, the path taken, and ← → while the widget has the focus
  (a move that removes or hides the focused button leaves the focus on the widget; a click on the current step is no
  move). `walkRoutes`
  resolves where a step goes: its `next` (`end`: nowhere), else the step below; a fork's `cases` as written, a case whose `when` is no
  condition (round 1's `always`) reading as the usual path, alone it is the step's next. At a phone's width the
  swimlane scrolls sideways inside the widget; the page doesn't.
- **picks** (`widget_picks.js`): one row per item, its options as chips (`aria-pressed`), the recommended one marked
  and picked to start with, a "+ note" per row, and "Fill reply".

**The only way out is composer text.** Fill reply builds `id: option (note) · …` from the picked rows (a row with no
pick is left out) and hands it to app.js's `fillComposer`, after a typed draft on a new line (`withDraft`; the draft
is kept). It never sends: the owner reads the text and sends it or not. A walk has no way out at all. The model's
strings reach the page through `textContent` and attributes only, never `innerHTML`, so a step reading
`<img src=x onerror=…>` shows as those characters.

**What doesn't draw.** The participant page (`participant.js` wires no block host), `web.markdown` off (no
`data-lang`), a live answer while it streams (its YAML shows until the turn's end re-renders it as markdown), and
anything outside `TEXTS`: cards, question replies, the asking slot, delegate reports. The terminal shows the YAML.

## The fixtures

`spec/fixtures/inline_widgets/` holds eval 0013's 78 real blocks (47 from round 2, 31 from round 1), one file each,
and `manifest.yml`, the outcome (ok, lenient or error) the eval's `check()` gave each when they were copied, but for
r2-deepseek-picks-review.2: its options are one-pair mappings, an error in the eval, and a fold (lenient) here.
`spec/inline_widgets_spec.rb` checks every one gets it: all 47 of round 2's draw, and round 1's errors are the
comma splits.
