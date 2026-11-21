// A card's actions as the page draws them (card.js): a command one, which
// the session runs, or a url one, an address opened in a new tab.
import { httpUrl } from "./refs.js";

// The longest address a card's url action opens: the server's
// Plugin::Card::MAX_URL (an authorize address can be long).
export const CARD_MAX_URL = 4096;

// A url action's address as the page opens it, else null: re-checked here,
// as a saved cards.json is seeded without the server's check and lit-html
// doesn't sanitize href. A url action needs its label (never the address).
export function cardActionUrl(action) {
  if (!action || action.command || !String(action.label ?? "").trim()) return null;
  return httpUrl(action.url, { max: CARD_MAX_URL });
}

// The card's actions the page draws: a command one, or a url one whose
// address passes cardActionUrl.
export function cardActions(card) {
  return (card?.actions || []).filter((a) => a && (a.command || cardActionUrl(a)));
}
