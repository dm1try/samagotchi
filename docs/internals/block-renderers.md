# Block renderers: bundles that draw fenced blocks in chi web

A bundle's JS turns a fenced block in an answer (```` ```mermaid ````) into a picture in the owner's page. No tool, no
toolkit. The bundle's side is [plugins.md](../plugins.md#block-renderers); this page is the mechanism and the security
model. The TUI is untouched: it shows a fence as source.

## The path

1. `MarkdownRenderer` keeps the language: syntect drops it from the HTML, so a second parse walks the `code_block` nodes
   in document order and zips them with the fragment's `<pre>`s, setting `data-lang` after sanitize's walk. Only the first
   word, downcased, matching `BlockRenderers::LANG`. A count that differs sets nothing. **`web.markdown` off means no
   `<pre data-lang>`, so nothing draws.**
2. `BlockRenderers.for_installed` (manifest `block_renderers:`, read through `InstalledBundle#manifest`: the bundle's
   kept `manifest.yml`, else its record's mirror, so chi web needs no plugins, and a bundle installed by a chi that
   didn't know the key draws once a kept manifest is there) lists
   who draws what: `GET /api/block_renderers`, `:owner`. `GET /api/block_renderers/:bundle/:file` serves a file, `:owner`:
   the URL's names go through `BlockRenderers.script_path` (membership in a listed renderer's `load` before any path is
   made), then `Provenance.sha_matches?`; a changed file is 409 `renderer_changed`. ETag + `no-cache`, as static files. A `block_renderers:` list that
   doesn't parse is logged once per bundle and problem (each list request and file fetch reads it).
3. `block_watch.js` (`createBlockWatch`, made by `block_host.js`'s `createBlockHost`, wired in `app.js`; `participant.js`
   isn't) finds and watches the blocks; `block_host.js` is its frame drawer (`createFrameDrawer`). The watcher asks an
   ordered list of drawers, core ones first (`inline_widgets.js` for `chi-ui`: [inline-widgets.md](inline-widgets.md)), then the frame drawer, which waits for `/api/block_renderers`;
   the first that `claims` the block's language draws it, and a language none claims is left alone. The contract
   (`claims`, `needsDraw`, `draw`, its `reconsider`, `sessionChanged`) is in the module's header. The shared DOM
   helpers live there too: `failBlock` and its `.block-note` (a click copies it), `holdingView`, `rejoin`, the
   toggle's listener; frames, the cache, hang marks, size checks, the zoom and the theme redraw stay in
   `block_host.js`. One `MutationObserver` per turn root,
   filtered to `TEXTS` (`text_roots.js`), so cards, the asking slot, question replies and delegate reports never draw, and
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
   diagram, its source under the Show the source button"). The natural size, a click on the picture, is also a
   `.block-zoom` button (icon, `aria-label`, `aria-pressed`) for the keyboard: before the toggle, shown on keyboard focus
   only, and taking no pointer while hidden, so the mouse's view is as it was.
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
   `max-height` and natural `max-width` say the same number, a backstop whatever the parsing gets wrong. The decode is bounded too
   (15 s, the mark on until it ends). A very wide picture stays at least 120 px tall and scrolls sideways instead of a sliver.

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
