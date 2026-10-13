// Images in the web UI: pasted or dropped into the composer as chips, sent
// with a turn as refs (uploaded first), shown as thumbnails in the bubbles
// and tool rows, opened full size in a lightbox. No DOM here beyond what the
// callers pass (the templates are lit-html's), so it runs under `node --test`.
import { html, nothing } from "./vendor/lit-html.js";

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

// Thumbnails for a bubble or a tool row; nothing for none. `src` may be
// given (a blob: URL while the upload is on its way). A redraw with the
// same images keeps the <img> elements (no reload).
export function thumbsTemplate(sessionId, images) {
  const list = (images || []).filter((i) => i && (i.src || i.file));
  if (!list.length) return nothing;
  const thumbs = list.map((img) => {
    const src = img.src || imageUrl(sessionId, img);
    const size = img.width && img.height ? ` ${img.width}×${img.height}` : "";
    const title = `${img.name || "image"}${size}`;
    return html`<img class="thumb" src=${src} alt=${title} title=${title} loading=${"lazy"}>`;
  });
  return html`<div class="thumbs">${thumbs}</div>`;
}

// The composer's chips: a thumbnail, the name and a remove button each.
export function chipsTemplate(chips) {
  return (chips || []).map((c, i) =>
    html`<span class="chip" data-index=${i}><img src=${c.src} alt=""><span class="chip-name">${c.name}</span><button type="button" class="chip-remove" data-index=${i} aria-label=${`remove ${c.name}`}>×</button></span>`);
}

// The {file, name} refs a turn names.
export function turnRefs(chips) {
  return (chips || []).filter((c) => c.ref).map((c) => ({ file: c.ref.file, name: c.name }));
}

// Chips again for a prompt the worker handed back (its images are stored
// already, so they need no upload: to that session).
export function restoredChips(sessionId, images) {
  return (images || []).filter((i) => i && i.file)
    .map((ref) => ({ name: ref.name || "image", ref, session: sessionId, src: imageUrl(sessionId, ref) }));
}

// A restored chip has no file of its own: its image, read back from where
// its session stores it.
async function fetchChipFile(src, name) {
  const res = await fetch(src);
  if (!res.ok) throw new Error(`Can't read ${name} again (${res.status})`);
  const blob = await res.blob();
  return new File([blob], name, { type: blob.type });
}

// Uploads the chips a turn to +sessionId+ needs: a ref is into one session's
// image store (chip.session), so a chip uploaded to another one (a failed
// send there, then a switch) goes up again, to this one. Sets each chip's
// ref and session in place: a failed send keeps them for another try.
export async function uploadChips(chips, sessionId, { upload, fetchFile = fetchChipFile }) {
  for (const chip of chips || []) {
    if (chip.ref && chip.session === sessionId) continue;
    const file = chip.file || await fetchFile(chip.src, chip.name);
    chip.ref = await upload(sessionId, file, chip.name);
    chip.session = sessionId;
  }
}
