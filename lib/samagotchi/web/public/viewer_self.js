// Who the viewer is in the conversation, for drawing it: a participant's
// own turns and prompts, and the owner's as "owner" (the participant main
// page). Not viewer.js: that one says what the viewer may do; this one who
// they are, read from a show's `viewer` (kind, id, name, client_id, mode),
// since <body> names no ids. The owner's page never sets it: every helper
// then answers as before (nothing is "mine" but the tab's own client id,
// no owner label).
//
// Module state, as participant_names.js keeps the names: turn_events.js
// isOwn, turn_html.js and bubbles.js read it where they draw.
import { participantAuthor } from "./participant_model.js";

let self = null;

// +viewer+: a show's viewer ({kind: "participant", id, name, client_id,
// mode}); anything else (the owner's, none) clears it.
export function setViewerSelf(viewer) {
  if (!viewer || viewer.kind !== "participant" || !viewer.id) {
    self = null;
    return;
  }
  self = {
    clientId: typeof viewer.client_id === "string" && viewer.client_id ? viewer.client_id : null,
    author: participantAuthor(viewer.id),
    name: String(viewer.name || ""),
    mode: viewer.mode || null,
  };
}

// The participant looking, or null (the owner's page).
export function viewerSelf() {
  return self;
}

// Whether +clientId+ is the viewer's own (chi web gives a participant's
// turns participant:<grant id>, whichever tab or device sent them).
const PARTICIPANT_CLIENT = "participant:";
// compat shim review_client_id: the same id as an older chi gave it.
const LEGACY_PARTICIPANT_CLIENT = "review:";
export function isViewerClient(clientId) {
  if (!self?.clientId) return false;
  if (clientId === self.clientId) return true;
  const own = String(self.clientId);
  return own.startsWith(PARTICIPANT_CLIENT) && clientId === LEGACY_PARTICIPANT_CLIENT + own.slice(PARTICIPANT_CLIENT.length);
}

// Whether +author+ ("p:<id>") is the viewer's.
export function isViewerAuthor(author) {
  return !!self && author === self.author;
}

// The label a participant sees on the owner's prompts.
export const OWNER_LABEL = "owner";

// The label on a prompt with no participant author, for this viewer: "owner"
// for a participant, none on the owner's page.
export function ownerLabel() {
  return self ? OWNER_LABEL : null;
}
