// A level setting (thinking, reasoning history) as the settings panels draw
// it: a row of segments (settings_panel.js; the start page's ⚙ panel and the
// session bar's, settings_chip.js) and the command a session's pick runs in
// its worker (the reply shows in the conversation, like a typed one). The
// summary is the setting's SettingExplained#summary ({level, source, own}:
// the worker's snapshot, a command_ran, or the server's own reading of the
// session file; the start page's from GET /api/models, own nil).
//
// A config names the setting (thinking_chip.js, reasoning_history_chip.js):
//   name     the row's label and the tooltip's word ("Thinking")
//   prefix   the session chip's word for an own value ("think low")
//   command  the command ("/thinking")
//   levels   the settable levels (the segments after "default")
//   cost     the panel's note on what a change costs the prompt cache

export const DEFAULT = "default";

// The command line for a level ("default" unsets the session's own), with
// --yes: the panel names the cost (CacheConfirm asks nothing then); null
// when it is the level the session has (+initial+: its own, or default).
export function commandLine(cfg, level, initial = null) {
  if (initial !== null && level === initial) return null;
  return `${cfg.command} ${level} --yes`;
}

// A settings panel row's first segment (settings_panel.js): follow the
// model, its value in brackets ("default (high)"); "default" alone for a
// model with no value of its own, or when +own+ (the value in force is the
// session's, not the model's: the summary doesn't carry the model's then).
export const followSegment = (value, own = false) => {
  const plain = own || value === DEFAULT;
  return { value: DEFAULT, label: plain ? DEFAULT : `${DEFAULT} (${value})`,
           title: plain ? "Follow the model" : `Follow the model (${value})` };
};

// A config's row of segments in the settings panel: the model's own level
// first (followSegment; plain while the session has its own), then the
// config's levels; the pressed one is +choice+ (null: the follow segment).
// null without the summary's level (the row is hidden).
export function segments(cfg, summary, choice) {
  if (!summary?.level) return null;
  const pressed = choice || DEFAULT;
  return [followSegment(summary.level, !!summary.own),
    ...cfg.levels.map((level) => ({ value: level, label: level }))].map((s) => ({ ...s, pressed: s.value === pressed }));
}
