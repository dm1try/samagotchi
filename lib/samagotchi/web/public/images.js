// Images in the web UI: pasted or dropped into the composer as chips, sent
// with a turn as refs (uploaded first), shown as thumbnails in the bubbles
// and tool rows, opened full size in a lightbox. No DOM here beyond what the
// callers pass, so it runs under `node --test`.
import { escapeHtml } from "./format.js";

// The image files a paste's or drop's DataTransfer carries.
export function imageFiles(dataTransfer) {
  const files = [...(dataTransfer?.files || [])];
  for (const item of dataTransfer?.items || []) {
    if (item.kind !== "file") continue;
    const file = item.getAsFile?.();
    if (file && !files.includes(file)) files.push(file);
  }
  return files.filter((f) => /^image\//.test(f?.type || ""));
}

// A pasted screenshot is often called "image.png": number it so the chips
// (and what the model reads) tell them apart.
export function chipName(file, index) {
  const name = String(file?.name || "").trim();
  if (name && name !== "image.png") return name;
  const ext = (String(file?.type || "").split("/")[1] || "png").replace("jpeg", "jpg");
  return `pasted-${index + 1}.${ext}`;
}

// The text a turn sends: what was typed, or for images alone a line naming
// them (a turn always carries text).
export function turnText(prompt, chips) {
  const text = String(prompt ?? "").trim();
  if (text || !chips?.length) return text;
  return chips.map((c) => `[image: ${c.name}]`).join(" ");
}

// Where the page loads a stored image from.
export function imageUrl(sessionId, ref) {
  return `/api/sessions/${encodeURIComponent(sessionId)}/${String(ref?.file || "")
    .split("/")
    .map(encodeURIComponent)
    .join("/")}`;
}

// Thumbnails for a bubble or a tool row; "" for none. `src` may be given
// (a blob: URL while the upload is on its way).
export function thumbsHtml(sessionId, images) {
  const list = (images || []).filter((i) => i && (i.src || i.file));
  if (!list.length) return "";
  const thumbs = list.map((img) => {
    const src = img.src || imageUrl(sessionId, img);
    const size = img.width && img.height ? ` ${img.width}×${img.height}` : "";
    const title = `${img.name || "image"}${size}`;
    return `<img class="thumb" src="${escapeHtml(src)}" alt="${escapeHtml(title)}" title="${escapeHtml(title)}" loading="lazy">`;
  });
  return `<div class="thumbs">${thumbs.join("")}</div>`;
}

// The composer's chips: a thumbnail, the name and a remove button each.
export function chipsHtml(chips) {
  return (chips || [])
    .map(
      (c, i) =>
        `<span class="chip" data-index="${i}"><img src="${escapeHtml(c.src)}" alt=""><span class="chip-name">${escapeHtml(c.name)}</span>` +
        `<button type="button" class="chip-remove" data-index="${i}" aria-label="remove ${escapeHtml(c.name)}">×</button></span>`,
    )
    .join("");
}

// The {file, name} refs a turn names.
export function turnRefs(chips) {
  return (chips || []).filter((c) => c.ref).map((c) => ({ file: c.ref.file, name: c.name }));
}

// Chips again for a prompt the worker handed back (its images are stored
// already, so they need no upload).
export function restoredChips(sessionId, images) {
  return (images || []).filter((i) => i && i.file).map((ref) => ({ name: ref.name || "image", ref, src: imageUrl(sessionId, ref) }));
}
