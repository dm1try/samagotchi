// The tracker on the page (pure, no DOM): ObjectivesTrack's reading of each
// objective (the view's item.track: {reading, reason, at, model, stale?}) and
// the view's tracking: {until} while one runs. Information only. A module of
// its own, not new exports of objectives_model.js or objectives_state.js:
// static JS is cached at unversioned URLs, and an existing module importing a
// new export of another existing one blanks a page with a mixed cache. See
// docs/internals/objectives.md, The tracker.
import { workerPredates } from "./worker_features.js";

// The one line both of its buttons post (ObjectivesCommand).
export const TRACK_LINE = "/objectives track";

// The worker's Bridge feature (ObjectivesTrack::FEATURE): an older worker hides Where are we?.
export const TRACK_FEATURE = "objectives_track";

// The page's objectivesTrack gate (feature_gates.js): a live worker that predates the tracker.
export function trackWorkerUnavailable(workerFeatures, bridgeUp) {
  return workerPredates(workerFeatures, bridgeUp, TRACK_FEATURE);
}

const word = (reading) => (reading === "no_answer" ? "no answer" : String(reading ?? ""));

// The list's row: "tracker: no sign — nothing ran for it". null with no reading.
export function trackText(track) {
  if (!track?.reading) return null;
  return `tracker: ${word(track.reading)}${track.reason ? ` — ${track.reason}` : ""}`;
}

// Whether the reading disagrees with the agent's last move on it (claims done vs no
// sign): the signal to look at. Not for an objective with no move, nor no answer.
export function trackDiffers(item) {
  const reading = item?.track?.reading;
  const state = item?.move?.state || "progress";
  return !!(item?.move && reading && reading !== "no_answer" && reading !== state);
}

// When the running read runs out, in ms; null with none. No event says so when its worker dies.
export function trackingUntil(list) {
  const at = Date.parse(list?.tracking?.until);
  return Number.isFinite(at) ? at : null;
}

// +list+ without a running read past its time.
export function expireTracking(list, now) {
  const at = trackingUntil(list);
  if (at === null || at > now) return list;
  const { tracking: _gone, ...rest } = list;
  return rest;
}

// Whether a read runs now.
export const tracking = (list) => trackingUntil(list) !== null;
