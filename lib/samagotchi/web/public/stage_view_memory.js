// What the user had opened of a running turn, per session, for this tab
// only: the cloud open, the steps opened in it, the working set's reader on
// an item. A switch rebuilds the stage from the server's read (session_sync.js
// select → resync → session_view.js renderSessionView); this puts back what
// was opened, when the page comes back to the same turn.
//
// Saved when the page leaves a session (select, before forgetSession resets
// the stage and closes the reader), taken when renderSessionView has drawn
// the read: applied only when the read's running turn is the one saved, and
// dropped either way (a different or ended turn has nothing to put back). A
// turn that ends on the page drops its session's entry (endTurnView).
//
// A plain Map keyed by session id, the oldest going past +cap+: nothing
// written to storage, nothing sent. The working set's peek isn't kept: it
// closes with its popover, which the tap that leaves the session closes.
//
// A module of its own: static JS is cached at unversioned URLs, and a new
// export on an old module would blank the page.

export const VIEW_MEMORY_CAP = 20;

// What the page shows now of its running turn ({turnId, cloud, steps,
// reader}), or null: no turn held, or nothing opened. +stage+: the stage
// view (stage_view.js: holds, current, cloud, step); +turnId+ the running
// turn's id; +reader+: the working set's reader (ws_reader.js), or null.
export function captureView({ stage, turnId, reader = null }) {
  if (!turnId || !stage?.holds?.() || !stage.cloud || !stage.step) return null;
  const count = stage.current?.()?.turn?.gens?.length || 0;
  const steps = [];
  for (let i = 0; i < count; i++) if (stage.step(i)?.el?.open) steps.push(i);
  const cloud = !!stage.cloud.isOpen?.();
  const item = reader?.isOpen?.() ? reader.openItem?.() || null : null;
  if (!cloud && !item) return null;
  return { turnId, cloud, steps: cloud ? steps : [], reader: item };
}

// Puts +view+ back on the page (captureView's shape): the cloud, then each
// step it had open that the replay drew closed (a hand toggle, as a click on
// its row), then the reader's item.
export function applyView(view, { stage, reader = null }) {
  if (!view) return;
  if (view.cloud && stage?.holds?.() && stage.cloud) {
    stage.cloud.setCloud(true);
    for (const i of view.steps) {
      const step = stage.step(i);
      if (step?.el && !step.el.open) step.summary?.click();
    }
  }
  if (view.reader && reader?.open) reader.open(view.reader);
}

// The memory: +leave(session, now)+ keeps what +now+ (captureView) says for
// +session+ (null: forgets it); +take(session, turnId)+ the entry for that
// turn, else null, and the entry goes; +drop(session)+.
export function createStageViewMemory({ cap = VIEW_MEMORY_CAP } = {}) {
  const entries = new Map();
  return {
    leave(session, now) {
      if (!session) return;
      entries.delete(session);
      if (!now) return;
      entries.set(session, now);
      while (entries.size > cap) entries.delete(entries.keys().next().value);
    },
    take(session, turnId) {
      const entry = entries.get(session) || null;
      entries.delete(session);
      return entry && turnId && entry.turnId === turnId ? entry : null;
    },
    drop(session) {
      entries.delete(session);
    },
    size: () => entries.size,
  };
}
