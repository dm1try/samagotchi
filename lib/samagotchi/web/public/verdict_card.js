const TYPES = Object.freeze({
  confirmed: { icon: "✅", label: "confirmed" },
  refuted: { icon: "❌", label: "refuted" },
  unclear: { icon: "❓", label: "unclear" },
});

export function placeVerdict(root, record, { who = "Owner", author = null } = {}) {
  const anchor = record?.anchor;
  const type = TYPES[record?.verdict];
  if (!root || !type || typeof anchor?.turn_id !== "string" || typeof anchor?.quote !== "string"
      || typeof record.reason !== "string" || typeof record.check_turn_id !== "string") return null;

  const elements = [...root.querySelectorAll("[data-turn-id]")];
  const source = elements.find((element) => element.dataset.turnId === anchor.turn_id);
  if (!source) return null;
  const cards = [...root.querySelectorAll(".verify-verdict")];
  const existing = cards.find((card) => card.dataset.checkTurnId === record.check_turn_id);
  if (existing) return existing;

  const doc = root.ownerDocument;
  const card = doc.createElement("aside");
  card.className = `verify-verdict ${record.verdict}`;
  card.dataset.sourceTurnId = anchor.turn_id;
  card.dataset.checkTurnId = record.check_turn_id;
  if (author) card.dataset.author = author;
  card.setAttribute("aria-label", `Claim verdict: ${type.label}`);

  const heading = doc.createElement("div");
  heading.className = "verify-verdict-heading";
  heading.append(doc.createTextNode(`${type.icon} ${type.label} · `));
  const name = doc.createElement("span");
  name.className = "verify-verdict-who";
  name.textContent = who;
  heading.append(name);

  const quote = doc.createElement("blockquote");
  quote.className = "verify-verdict-quote";
  quote.textContent = anchor.quote;
  const reason = doc.createElement("p");
  reason.className = "verify-verdict-reason";
  reason.textContent = record.reason;

  // P5 can add Verify fresh here for unclear verdicts.
  const link = doc.createElement("a");
  link.href = "#";
  link.className = "verify-verdict-link";
  link.textContent = "View check";
  link.addEventListener("click", (event) => {
    event.preventDefault();
    [...root.querySelectorAll("[data-turn-id]")].find((element) => element.dataset.turnId === record.check_turn_id)
      ?.scrollIntoView?.({ behavior: "smooth", block: "center" });
  });
  card.append(heading, quote, reason, link);

  const previous = cards.filter((candidate) => candidate.dataset.sourceTurnId === anchor.turn_id).at(-1);
  (previous || source).after(card);
  return card;
}

export function nameVerdictCards(root, nameFor) {
  for (const card of root?.querySelectorAll?.(".verify-verdict[data-author]") || []) {
    const name = nameFor(card.dataset.author);
    if (name) card.querySelector(".verify-verdict-who").textContent = name;
  }
}
