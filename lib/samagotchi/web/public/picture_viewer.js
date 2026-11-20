// The picture viewer (#lightbox): an attached image shown over the page.
// open() shows a picture, a click or Esc closes it.
//
// +picture+: {url, width, height, alt}; width and height may be absent.
// A module of its own: its exports are new (docs/internals/web-frontend.md,
// "New exports go in new modules").

// A thumbnail's picture: its size once loaded, so most opens don't wait for
// a decode.
export function thumbPicture(img) {
  const sized = img.complete && img.naturalWidth > 0;
  return { url: img.src, alt: img.alt, width: sized ? img.naturalWidth : null, height: sized ? img.naturalHeight : null };
}

// @param el the #lightbox element (index.html keeps its <img> for an older
//   cached app.js, which reads it; one is added when it is missing)
// @return {open(picture, {opener}), close(), isOpen()}
export function createPictureViewer({ el, doc = document }) {
  const img = el.querySelector("img") || el.appendChild(doc.createElement("img"));

  function open(picture) {
    img.src = picture.url;
    img.alt = picture.alt || "";
    el.hidden = false;
  }

  function close() {
    el.hidden = true;
  }

  const isOpen = () => !el.hidden;

  el.addEventListener("click", close);
  doc.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && isOpen()) close();
  });

  return { open, close, isOpen };
}
