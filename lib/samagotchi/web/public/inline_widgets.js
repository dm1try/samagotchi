// The core drawer of chi-ui blocks (docs/internals/inline-widgets.md): a picks
// or a walk, drawn from the data the server parsed (the <pre>'s data-widget,
// InlineWidgets on the server), asked before the bundle renderers by
// block_watch.js (its header has the drawer contract).
//
// What it draws: a <figure class="block-drawn"> right before the <pre>, which
// stays, hidden (the DOM is the state, block_source.js), holding the shared
// source toggle and a .widget-host whose open shadow root holds the widget and
// its stylesheet (widgets.css, fetched once into a constructable sheet the
// widgets adopt, so none draws unstyled and the view held measures the
// styled widget). The toggle is in the light DOM: a click in the shadow root
// reaches the page's delegated listeners retargeted at the host. In a shadow
// root the widget's words are out of the bubble's textContent, which the
// shown-texts dedupe, copy's fallback and an annotation's quote read, as with a
// renderer's <img>.
//
// cloneNode doesn't copy a shadow root: a Revise clone (revise_switch.js
// viewOf) arrives with the figure and an empty host, which needsDraw sees and
// draw fills again (a fresh widget, its listeners its own).
//
// A refused block (data-widget-error) stays source under failBlock's muted line;
// a <pre> with neither attribute (an older server, web.markdown off never has a
// data-lang) is left alone. The model's words reach the page as text only.
//
// A module of its own: static JS is cached at unversioned URLs.

import { html, render as litRender } from "./vendor/lit-html.js";
import { DRAWN, figureOf, setSourceShown } from "./block_source.js";
import { failBlock, holdingView } from "./block_watch.js";
import { drawPicks, withDraft } from "./widget_picks.js";
import { drawWalk } from "./widget_walk.js";

export const LANG = "chi-ui";
export const HOST = "widget-host";
export const STYLESHEET = "/assets/widgets.css";
export const TOGGLE_PICTURE = "Show the widget";

// widgets.css as a constructable sheet, fetched once per page; a failed fetch
// draws unstyled and is tried again by the next draw. An answer that isn't CSS
// (an auth proxy's 200 login page) counts as failed.
let shared = null;
export function loadWidgetSheet(win = window) {
  shared ??= win.fetch(STYLESHEET, { headers: { Accept: "text/css" } })
    .then((res) => {
      if (!res.ok) throw new Error(`widgets.css answered ${res.status}`);
      const type = res.headers.get("content-type") || "";
      if (!type.startsWith("text/css")) throw new Error(`widgets.css answered ${type || "no Content-Type"}`);
      return res.text();
    })
    .catch((e) => {
      console.error("widgets.css:", e);
      shared = null;
      return "";
    })
    .then((css) => {
      const sheet = new win.CSSStyleSheet();
      sheet.replaceSync(css);
      return sheet;
    });
  return shared;
}

// block_host.js's toggle icon, the same button.
const ICON = html`<svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true"><path d="M5.5 4 2 8l3.5 4M10.5 4 14 8l-3.5 4" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>`;

const DRAW = {
  walk: (data, { doc }) => drawWalk(data, doc),
  picks: (data, { doc, fill }) => drawPicks(data, { doc, fill }),
};

// The widget's data on +pre+.
// @throws Error it isn't JSON of a known type
export function widgetData(pre) {
  const data = JSON.parse(pre.getAttribute("data-widget"));
  if (!data || !Object.hasOwn(DRAW, data.type)) throw new Error(`no widget of type ${String(data?.type).slice(0, 40)}`);
  return data;
}

// The host of a drawn figure, or null.
export function hostOf(figure) {
  return figure?.querySelector(`:scope > .${HOST}`) || null;
}

// @param roots the turn roots, for the view held
// @param composerText () => the composer's text now
// @param fillComposer (text) => the composer filled with +text+ (app.js's)
// @param sheet () => a Promise of the widgets' CSSStyleSheet (a seam for the specs)
export function createWidgetDrawer({ roots, composerText, fillComposer, doc = document, win = window, sheet = () => loadWidgetSheet(win) }) {
  const fill = (reply) => fillComposer(withDraft(composerText(), reply));

  function fillHost(host, data, styles) {
    const shadow = host.shadowRoot || host.attachShadow({ mode: "open" });
    shadow.adoptedStyleSheets = [styles];
    shadow.replaceChildren(DRAW[data.type](data, { doc, fill }));
  }

  function makeFigure(data) {
    const figure = doc.createElement("figure");
    figure.className = `${DRAWN} widget`;
    figure.dataset.widgetType = data.type;
    figure.dataset.togglePicture = TOGGLE_PICTURE;
    const host = doc.createElement("div");
    host.className = HOST;
    const toggle = doc.createElement("button");
    toggle.type = "button";
    toggle.className = "block-toggle";
    litRender(ICON, toggle);
    figure.append(host, toggle);
    return figure;
  }

  function needsDraw(pre, figure) {
    if (figure) return !hostOf(figure)?.shadowRoot;
    if (pre.hasAttribute("data-widget-error")) {
      failBlock(pre, LANG, pre.getAttribute("data-widget-error"));
      return false;
    }
    return pre.hasAttribute("data-widget");
  }

  // After the sheet: the data is read first, so a bad block fails at once.
  function draw(pre) {
    const data = widgetData(pre);
    return sheet().then((styles) => place(pre, data, styles));
  }

  function place(pre, data, styles) {
    if (!pre.isConnected) return;
    const drawn = figureOf(pre);
    if (drawn) {
      let host = hostOf(drawn);
      if (!host) {
        host = doc.createElement("div");
        host.className = HOST;
        drawn.prepend(host);
      }
      if (!host.shadowRoot) fillHost(host, data, styles);
      return;
    }
    const figure = makeFigure(data);
    fillHost(hostOf(figure), data, styles);
    holdingView(pre, roots, () => {
      pre.before(figure);
      setSourceShown(figure, pre, false);
    }, () => figure.getBoundingClientRect().bottom, win);
  }

  return { claims: (lang) => lang === LANG, needsDraw, draw };
}
