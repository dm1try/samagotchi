import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createPictureViewer, thumbPicture } from "../../../lib/samagotchi/web/public/picture_viewer.js";

const URL_A = "data:image/png;base64,AAAA";

function setup({ markup = '<img alt="">' } = {}) {
  const el = document.createElement("div");
  el.id = "lightbox";
  el.hidden = true;
  el.innerHTML = markup;
  document.body.append(el);
  const pictures = createPictureViewer({ el });
  return { el, pictures, img: () => el.querySelector("img") };
}

test.afterEach(() => { document.body.innerHTML = ""; });

test("closed, the viewer is hidden", () => {
  const { el, pictures } = setup();
  assert.equal(el.hidden, true);
  assert.equal(pictures.isOpen(), false);
});

test("open shows the picture in the kept <img>", () => {
  const { el, pictures, img } = setup();
  const kept = img();
  pictures.open({ url: URL_A, alt: "a shot" });
  assert.equal(el.hidden, false);
  assert.equal(pictures.isOpen(), true);
  assert.ok(img() === kept);
  assert.equal(kept.getAttribute("src"), URL_A);
});

test("an #lightbox with no <img> gets one", () => {
  const { pictures, img } = setup({ markup: "" });
  pictures.open({ url: URL_A });
  assert.equal(img().getAttribute("src"), URL_A);
});

test("Esc closes it", () => {
  const { el, pictures } = setup();
  pictures.open({ url: URL_A });
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  assert.equal(el.hidden, true);
  assert.equal(pictures.isOpen(), false);
});

test("a click closes it", () => {
  const { el, pictures, img } = setup();
  pictures.open({ url: URL_A });
  img().click();
  assert.equal(el.hidden, true);
});

test("thumbPicture takes a loaded thumbnail's size, and none before it loads", () => {
  const loaded = { src: URL_A, alt: "x", complete: true, naturalWidth: 40, naturalHeight: 30 };
  assert.deepEqual(thumbPicture(loaded), { url: URL_A, alt: "x", width: 40, height: 30 });
  assert.deepEqual(thumbPicture({ ...loaded, complete: false }), { url: URL_A, alt: "x", width: null, height: null });
});
