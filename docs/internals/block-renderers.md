# Block renderers: bundles that draw fenced blocks in chi web

A bundle's JS turns a fenced block in an answer (```` ```mermaid ````) into a picture in the owner's page. No tool, no
toolkit. The bundle's side is [plugins.md](../plugins.md#block-renderers); this page is the mechanism and the security
model. The TUI is untouched: it shows a fence as source.

## The path

1. `MarkdownRenderer` keeps the language: syntect drops it from the HTML, so a second parse walks the `code_block` nodes
   in document order and zips them with the fragment's `<pre>`s, setting `data-lang` after sanitize's walk. Only the first
   word, downcased, matching `BlockRenderers::LANG`. A count that differs sets nothing. **`web.markdown` off means no
   `<pre data-lang>`, so nothing draws.**
2. `BlockRenderers.for_installed` (manifest `block_renderers:`, read through `InstalledBundles::Record#manifest`: the bundle's
   kept `manifest.yml`, else its record's mirror, so chi web needs no plugins, and a bundle installed by a chi that
   didn't know the key draws once a kept manifest is there) lists
   who draws what: `GET /api/block_renderers`, `:owner`. `GET /api/block_renderers/:bundle/:file` serves a file, `:owner`:
   the URL's names go through `BlockRenderers.script_path` (membership in a listed renderer's `load` before any path is
   made), then `InstalledBundles::Dir#file_refusal(:scripts, …)` (the check a context provider's scripts get too); a file with no recorded sha, a missing one or a changed one is 409
   `renderer_changed`, each with its own reason. ETag + `no-cache`, as static files. A `block_renderers:` list that
   doesn't parse is logged once per bundle and problem (each list request and file fetch reads it); a bundle this chi is
   too old for (`requires_chi`) draws nothing, logged once per bundle and version (`block_renderers_too_new`).
3. `block_watch.js` (`createBlockWatch`, made by `block_host.js`'s `createBlockHost`, wired in `app.js`; a participant's page
   gets the core drawers only, no bundle's renderers: `block_renderers`) finds and watches the blocks; `block_host.js` is its frame drawer (`createFrameDrawer`). The watcher asks an
   ordered list of drawers, core ones first (`inline_widgets.js` for `chi-ui`: [inline-widgets.md](inline-widgets.md)), then the frame drawer, which waits for `/api/block_renderers`;
   the first that `claims` the block's language draws it, and a language none claims is left alone. The contract
   (`claims`, `needsDraw`, `draw`, its `reconsider`, `sessionChanged`) is in the module's header. The shared DOM
   helpers live there too: `failBlock` and its `.block-note` (a click copies it), `holdingView`, `rejoin`, the
   toggle's listener; frames, the cache, hang marks, size checks, the click that opens the picture viewer and the theme
   redraw stay in `block_host.js`. One `MutationObserver` per turn root,
   filtered to `TEXTS` (`text_roots.js`), so cards, a lead-in bubble, question replies and delegate reports never draw, and
   every path that adds a block to a root is seen the same way. One `IntersectionObserver` per scroller, with an explicit `root`
   (with `root: null`, `rootMargin` doesn't pass an `overflow: auto` in between). Closed `<details>` fire on open. **A
   move isn't over when it is seen:** a block waiting to come near is watched by its scroller's observer, so one that moves
   to another scroller (the stage's `.ts-scroll` hands a long answer to `#history`) is watched there, or it never draws.
4. `block_frame.js` (`createBlockFrame`): one hidden frame per language, made on first need, one render at a time, 15 s per
   call, the renderer files' fetch included (browser `fetch` has no timeout; a fetch past it is a failed load). A timeout, a
   dead frame or a session switch drops it, and a drop rejects whatever is pending, the load too. Handshake `loaded` → `code {files}` → `ready | failed`,
   then `render {id, source, theme}` → `done {id, svg} | error {id, message}`.
5. On success a `<figure class="block-drawn">` goes right before the `<pre>`, which stays in the DOM, `hidden`, so whatever
   reads text (copy, a claim's walk, fold thresholds) sees what it did. **The DOM is the state** (`block_source.js`): a Revise
   clone arrives with both. On failure the `<pre>` stays, marked `data-block-failed`, with one muted line: an attribute CSS
   shows, never markup, and not in the bubble's `textContent`, which the page's dedupe and an annotation read (`copy.js`'s rule). CSS content can't be selected, so a click on the line copies its words.
   The toggle has an icon and an `aria-label`, no text (`copy.js`'s rule). A jump into the source shows it (`revealInHistory`).
   For a screen reader: the hidden `<pre>` isn't read, so the `<img>`'s alt names the toggle that shows it ("mermaid
   diagram, its source under the Show the source button"). In the answer the picture is always fitted to the column. A
   click on it opens the page's picture viewer (`createBlockHost`'s `openPicture`, app.js's `picture_viewer.js`;
   [web-frontend.md](web-frontend.md#picture-viewer)) with its `data:` URL and its size from the viewBox, zoomable and
   movable there; without `openPicture` (an older app.js) a click does nothing. The same is a `.block-zoom` button
   ("Open in the viewer": icon, `aria-label`) for the keyboard: before the toggle, shown on keyboard focus only, and
   taking no pointer while hidden; Esc in the viewer gives it the focus back.
6. Cache: a `Map` on `lang + theme + source`, about 200 entries, holding the `data:` URL; a later `bubble.innerHTML` wipes the
   figure and the observer redraws in the same pass. No `crypto.subtle`: it's undefined on a plain-http LAN address. A system
   theme change redraws through the figure (a hidden `<pre>` never intersects).
7. The view: a viewer at the bottom stays there (`scroll.js keepFollowing`); a block drawn above a reader's view keeps
   what they read in place (checked in Chromium and WebKit).
8. **A maximum picture, in the page, for any renderer** (`block_host.js oversize`): 50,000 px a side and 100M px. Mermaid's
   secure keys don't cover diagram sizes, so a model's `%%{init:{"sequence":{"height":50000000}}}%%` otherwise gives an image
   33M px tall, which breaks the session's scrolling. Eval 0012's real diagrams reach about 2,600 px a side and 3.5M px;
   a chain of 240 edges or a sequence of 1,000 messages still fits. **The decoded and displayed size is what counts.** The root's box comes
   from `DOMParser`, never a regex over model-influenced XML (exponents, a comment holding `<svg`, a `>` in an attribute, entities and
   prefixes all fooled one), and a vast one isn't decoded. Then the decoded size is checked: over the maximum, or a width or
   height of 0 (WebKit's 0 x 150 for a viewBox it can't hold), the block stays source with its line. `.block-img`'s CSS
   `max-height` says the same number, a backstop whatever the parsing gets wrong. The decode is bounded too
   (15 s, the mark on until it ends). A very wide picture stays at least 120 px tall and scrolls sideways instead of a sliver.

## A failed block is asked for again

One mechanism for every drawn block, a `chi-ui` picks or walk (core's drawer) and a bundle's renderer (chi-mermaid's
`mermaid`): a block the owner's page can't draw **in the newest answer**, for a reason that is the model's (a refused
`chi-ui` block, a renderer's own `error`), is asked for once more as a side request, and the answer is patched. No
message is sent and no turn runs. `web.block_fix: off` ([configuration.md](../configuration.md)) is the page as before.

```
page: a drawer fails a block in the newest answer, marked fixable
  └─ POST /api/sessions/:id/blocks/fix {turn_id, lang, source, reason}   (chi web, :owner: Web::BlockFixRoutes)
       → Bridge POST /session/:id/blocks/fix (Bridge::BlockFixRoute) → Engine#fix_block
         ├─ the answer's stamp knows this block → 200 {state: "fixed" | "failed"}
         └─ else 202 {state: "running"}; a side thread asks the model, checks the answer,
            queues the result and wakes the worker's loop
worker loop, between turns (before any queued prompt): Engine#apply_block_fixes
  └─ patches the answer (its text, or its display), stamps it, saves, announces :block_fix
page: on :block_fix → re-reads that answer; the patched block draws as any block
reload: the answer is the patched text; the render marks the block from the stamp
```

**The request** (`BlockFix.request`, `Engine::BlockFixPart`): `ask_side_model`, as `/btw` and ctx.ask_model, on the
session's model: the conversation up to and including the answer as the side transcript (`Plugin::SideQuestion`, its
last 32,000 characters; display-only keys gone), then the failed block, its language and its error (cut to 300
characters, in the user part only). `BlockFix::SYSTEM` asks for the corrected block only, in one fence; for `chi-ui` the
schemas follow (`InlineWidgets::FIX_RULES`: core can't read the inline-widgets bundle's prompt sections). No tools,
thinking off, 25 s, 6,000 tokens out. It shows as `block-fix` in `/stats`' side line, always the owner's.
`BlockFix.extract` takes the first fence of the answer (else the whole answer); it is refused when the answer was cut
off at its limit, empty, the same block, or over 16 KB, and a `chi-ui` fix must parse (`BlockFix.check`). Any other
language passes: only the page can draw it.

**Where the block is** (`BlockFix.locate`, `replace`): commonmarker, the page's render's parser (`MarkdownParser` loads
it for the render and the worker), walks the `code_block` nodes; the first in that language whose normalised source is
the block's is the one, and its `source_position` gives its body's lines. `replace` keeps the fence lines and gives each
new line the old body's indent (a list item's) and the text's own line ends. A block in a blockquote isn't fixed (its
lines carry `> `). A block's identity is `BlockFix.key`: SHA-256 of the language and the normalised source, 32 hex
characters.

**The route's answers** (`Engine#fix_block`): 409 `fix_unavailable` (no session, a scratch one, no commonmarker), 413
`block_too_large` (over 16 KB), 409 `block_not_found` (the source isn't a block of that turn's answer:
`AnswerTail.find` by turn id), 200 with the stamp's state when the answer's stamp knows the block (a block that is a
fix and fails again: `failed`), 202 `running` while it is asked, 429 `fix_busy` past 2 in flight. The answer is resolved
once, there: the result carries its **anchor** (its index in the conversation, its digest as `Bridge::TurnDrawings`
computes one, and the turn counter: `Engine#turn_messages` counts each turn).

**The write: on the worker's loop, between turns, never from the request's thread.** A running turn holds its own copy
of the conversation and writes it back at its end. `Worker::BlockFixesPart#apply_block_fixes` runs in each pass that
runs the queued commands, after them and before the notes and the next prompt (the idle pass and each input file's
step); the result's thread wakes the loop (`Engine#block_fix_ready=`, `Waker#wake`). Under the event lock, three
outcomes:

- **No turn started since the ask, and the answer is still the newest** (`AnswerTail.find`; notes, a `!cmd` line and
  `/continue no` land after an answer without a request, so "the last message" isn't the test): its `content` is
  patched, its `display` too when a hook set one, and on `api: anthropic` its saved blocks (`anthropic_content`, which
  `AnthropicWire#assistant_blocks` sends as they are): the text block that holds the block whole, else the blocks are
  dropped and the answer goes as its text. A thinking block is never touched. The next turn sends the patched answer.
  A fix asked as its own turn ends (the page asks on the end event, before the turn's hooks are done) counts as no turn
  since.
- **A turn started since** (or was running at the ask): only `display` (`AnswerDisplay::KEY`, what the page renders in
  place of `content`; never sent to a model). No message a model has been sent is rewritten, so no prompt cache is
  invalidated.
- **The answer or the block is gone** (its digest changed: a rollback, a new text; the turn id now names another
  answer: a reminder turn's id names no prompt, so it falls back to the newest answer): the fix is dropped
  (`state: "dropped"`).

A failed ask stamps the answer only. Each outcome is one `Log.info(:model, "block_fix_<state>", lang:, key:, bytes:, ms:,
landed:, reason:)` line (never the source) and one `:block_fix` event (`turn_id`, `key`, `lang`, `state`, `landed`,
`reason`, and the answer's digest before and after: `was_digest`, `digest`). A participant never gets it
(`ParticipantView::DROPPED`). A pending result doesn't keep a worker alive: an idle exit or a stop loses it, and the
page's give-up shows "Ask in chat".

**The stamp** (`BlockFix::STAMP`, `block_fixes` on the answer's model message: `{key, fixed_key, state, reason, at}`
per block asked) is display only (`AnswerDisplay::DISPLAY_ONLY`) and rides both loops' allowlists (`ChatLoop#plain`,
`KernelLoop#sanitize_history`). It is why nothing is asked twice: a reload, a second tab and a re-rendered bubble get the
stamp's answer. `Web::MarkdownRenderer#render(block_fixes:)`, from `MessageDisplay`'s answer render only, marks a block
that is a fix `data-block-fixed` and one whose fix failed `data-block-fix-failed`; an unstamped answer's HTML is as
before.

**The turn's drawing.** A patched `content` changes the digest the turn's drawing line ends on (`TurnDrawings#holds?`),
so the Bridge's `TurnDrawings` (an observer of `:block_fix` with `landed: "answer"`) writes that turn's line again with
the new end digest, when the old one ended on the answer as it was (`was_digest`). A `display` patch keeps the digest.

**What a content patch costs**: nothing on a remote prefix cache or on Anthropic's Messages API (the cached prefix ends
before the answer); on llama.cpp the slot re-evaluates from the patched block, a few hundred tokens, and the turn-end
warm-up's gain is lost for that one turn ([prompt-caching.md](prompt-caching.md#the-turn-end-warm-up)). A `!rollback` or
a canceled Continue can restore a checkpoint from before the patch: the answer comes back unpatched and unstamped and may
be asked for once more.

## Security model

The bundle's JS is trusted (installing a bundle already means trusting it, [plugins.md](../plugins.md#trust)). **Its input
is model-written**, so a renderer bug or an injected diagram must not reach a page that controls sessions.

| Layer | What it stops |
|---|---|
| `<iframe sandbox="allow-scripts">`, never `allow-same-origin` | reading the parent; reading gated responses |
| CSP meta in the srcdoc (`block_frame.js FRAME_CSP`) | fetch, POST, beacon, image, CSS url, prefetch/preload. Without it WebKit sent the session cookie on the frame's GET |
| Page header `frame-src 'none'` (`App::FRAME_HEADERS`; srcdoc frames still load and run under it) | self-navigation, meta refresh, anchor click, which leak past the frame's CSP in both browsers |
| `delete window.RTCPeerConnection` + `webkitRTCPeerConnection` in the bootstrap, before any bundle code | the plain WebRTC call only |
| Output only as `<img src="data:…">` | scripts and remote images inside the SVG don't run or load |

**Hard rules.**

1. Never `allow-same-origin`. Never `innerHTML` the frame's output. SVG goes only into a `data:` URL for an `<img>`.
2. **Never `blob:` for the SVG.** A blob inherits chi web's origin, and the browser's own "Open Image in New Tab" and drag-to-tab
   navigate to it, where its script reads a gated route with chi's origin and cookie. Opened as a document, a `data:` SVG
   has origin `null` and can't read chi's API; WebKit may still attach a same-host cookie to a request it makes (seen with a
   test cookie to another port), so what holds is that the answer stays unreadable, not that no cookie is ever sent.
3. The page accepts messages only where `e.source === frame.contentWindow`, of known types, and treats them as data
   (`frameMessage`). No other window `message` listener exists on the page (`spec/web/public/message_listeners.test.js` keeps it so).
4. Code enters the frame by postMessage from the page's own authenticated fetch (the frame's CSP closes its network but for
   WebRTC, the residual risk below, and it has no cookie),
   then as `script.text = code`. `eval` doesn't work: a library's `"use strict"` keeps its global local. A syntax error doesn't
   throw: it reaches the frame's error event, as a failed load. `fetchRendererFile` requires `res.ok` and a JS content type, so a
   proxy's sign-in HTML is never passed in as code.

**Residual risk, accepted for v1.** Code running in the frame can send what the frame holds over WebRTC: the diagram sources it
has rendered. A nested `srcdoc` frame gets a fresh `RTCPeerConnection` and still sends packets, in both browsers, and no CSP
stops WebRTC. It can't reach the page, cookies or sessions, and it needs a renderer compromised through its input. To limit
what it holds, the frame is dropped on a session switch.

**The hang.** The frame shares the page's thread, so a timer can't fire during a hang, and the model's input drives the
renderer's runtime. So a source over 64 KB stays source, and before each render a `sessionStorage` mark (`chi_block_rendering:`,
per block) is written and cleared after; a block whose mark is still there on load stays source with its muted line. A timeout
keeps the mark too. It is per tab: a new tab tries again. A reload during a render isn't a hang: `pagehide` clears the marks of renders
under 15 s old. A page truly hung never runs it. A render that ends after holding on over 10 s (`SLOW_RENDER_MS`) draws now and keeps its
mark, so it stalls the page once and not on every load; several such blocks still stall once each, and one under the bound stalls every
load. Real Mermaid's worst was about 1 s, so that takes a bad renderer. A mark of a render still running isn't a leftover: a bubble
rewritten or cloned meanwhile has its blocks wait for that render (`coming`), and each draws into whichever is connected.
No real hang has been produced; this is a guard.

A navigation a hostile renderer tries is blocked, but in Chromium it leaves the frame on an error page, so that render times out at
15 s and the frame is dropped. Not a concern for a working renderer, and the page stays usable meanwhile.

## Not done

Firefox isn't tested: if its CSP blocks srcdoc under `frame-src 'none'`, the frame never answers and blocks stay source.
Interactive output (a visible frame running the model's own code) isn't built: nothing secret could be in such a frame, and a busy
loop would stall the page.
