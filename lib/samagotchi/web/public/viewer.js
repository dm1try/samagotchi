// The viewer: who looks at this page and what they may do on it (chi web's
// Web::Viewer). chi web stamps it on <body> (data-viewer-kind, and
// data-viewer-can: the capability names, space-separated), read once here at
// boot; a session's show carries it as `viewer` too. The page draws a
// control, and makes a call, only when viewer.can(name) says so: a control
// the viewer may not use is not created and not wired (the null-control
// idiom), and its static element stays hidden (control(): hidden and
// data-withheld, which index.html's CSS never shows). No 403 is a way
// of gating. See docs/internals/web-frontend.md (The viewer).
//
// Not app.js's refEditor() (where this page can open a ref: the editor) nor
// the show's capabilities (what the page renders): those are per request.
//
// A show's viewer narrows the stamp, never widens it: the boot's controls
// were made from the stamp. Leaving a session (forgetSession) goes back to
// the stamp. A page with no stamp may do nothing (it fails closed).

// The names in a stamp's or a show's list, as a Set.
function namesOf(list) {
  const names = Array.isArray(list) ? list : String(list || "").split(/\s+/);
  return new Set(names.filter((name) => typeof name === "string" && name));
}

// @param body the page's <body> (its data-viewer-kind, data-viewer-can)
// @return {can(name), kind(), update(viewer), reset(), control(el, name), controls(els, name)}
export function createViewer(body) {
  const data = body?.dataset || {};
  const stamped = { kind: data.viewerKind || null, can: namesOf(data.viewerCan) };
  let current = stamped;

  const can = (name) => current.can.has(name);
  return {
    can,
    kind: () => current.kind,
    // A show's +viewer+ ({kind, can}); anything else keeps what is there.
    update(viewer) {
      if (!viewer || typeof viewer !== "object" || !Array.isArray(viewer.can)) return;
      const shown = namesOf(viewer.can);
      current = { kind: stamped.kind, can: new Set([...stamped.can].filter((name) => shown.has(name))) };
    },
    reset() {
      current = stamped;
    },
    // +el+ when the viewer may use +name+; else +el+ hidden, and null (the
    // page wires nothing to it). data-withheld keeps it hidden whatever its
    // own CSS display says (index.html's [data-withheld] rule).
    control(el, name) {
      if (can(name)) return el;
      if (el) {
        el.hidden = true;
        el.dataset.withheld = "";
      }
      return null;
    },
    controls(els, name) {
      return els.map((el) => this.control(el, name));
    },
  };
}
