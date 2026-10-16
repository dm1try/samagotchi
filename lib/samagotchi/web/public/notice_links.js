// A hook notice line's http(s) URLs as links (a source-links `sources:`
// line with markdown off): the terminals need the line as text, the web can
// click it. Only http(s) URLs that refs.js httpUrl accepts (no userinfo, not
// over-long) are linked; everything else stays text, escaped by lit (no
// unsafeHTML). A link opens in a new tab: refs.js installRefClicks leaves a
// plain <a> (no data-ref-kind) to the browser.
import { html } from "./vendor/lit-html.js";
import { httpUrl } from "./refs.js";

// A candidate: the scheme, then anything up to a space or an angle bracket
// (`<https://x/a>` links https://x/a).
const CANDIDATE = /https?:\/\/[^\s<>]+/gi;
const TRAILING = /[.,;:!?'"]+$/;

// +url+ cut at its first ) that no ( inside it balances: `(https://x/a)`
// ends before the ), `…/Foo_(bar)` keeps it (source_links.rb trim_url_end).
function cutUnbalancedParen(url) {
  let depth = 0;
  for (let i = 0; i < url.length; i++) {
    if (url[i] === "(") depth++;
    else if (url[i] === ")") {
      if (depth === 0) return url.slice(0, i);
      depth--;
    }
  }
  return url;
}

// A candidate without what ends the sentence around it: trailing
// punctuation (the sources line's ", "), an unbalanced ), a ] no [ opens.
function trimUrl(candidate) {
  let url = cutUnbalancedParen(candidate.replace(TRAILING, ""));
  if (url.endsWith("]") && !url.includes("[")) url = url.replace(/\]+$/, "");
  return url.replace(TRAILING, "");
}

// +text+ with each http(s) URL a link (a lit template's array of strings
// and <a> parts); +text+ itself when it links nothing, so a URL-less line
// renders exactly as before.
export function linkedLine(text) {
  if (typeof text !== "string" || !text) return text;
  const parts = [];
  let last = 0;
  for (const match of text.matchAll(CANDIDATE)) {
    const shown = trimUrl(match[0]);
    const href = httpUrl(shown);
    if (!href) continue;
    if (match.index > last) parts.push(text.slice(last, match.index));
    parts.push(html`<a href=${href} target="_blank" rel="noopener noreferrer">${shown}</a>`);
    last = match.index + shown.length;
  }
  if (!parts.length) return text;
  if (last < text.length) parts.push(text.slice(last));
  return parts;
}
