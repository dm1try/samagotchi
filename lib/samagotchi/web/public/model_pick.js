// The start page's model picker: pure helpers over GET /api/models' payload.

export const MODEL_KEY = "chi_model";

// The names to offer, in the server's order: the default host's models
// bare, the other hosts' as host:model. [] for a payload with none.
export function modelNames(payload) {
  const list = Array.isArray(payload?.models) ? payload.models : [];
  return list.map((m) => String(m?.name || "")).filter(Boolean);
}

// The name to preselect: the remembered one when it is still offered (any
// case), else the server's default, else the first offered, else "".
export function pickModel(names, defaultName, stored) {
  const want = String(stored || "").trim().toLowerCase();
  if (want) {
    const kept = names.find((n) => n.toLowerCase() === want);
    if (kept) return kept;
  }
  if (defaultName && names.includes(defaultName)) return defaultName;
  return defaultName || names[0] || "";
}

