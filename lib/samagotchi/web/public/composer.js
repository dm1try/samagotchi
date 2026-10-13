// The composer's line: where a typed line goes (routeComposerLine, pure),
// and a session command sent from it or from a control such as the llm ctx
// chip (createComposerCommands: no DOM, the page passes its hooks). Split
// out of app.js; plain JS, no markup.

import { sessionCommandLine, startPageReplyOrHint, steerChoiceRoute, unknownCommandHint, webLocalReply } from "./commands.js";

// Where a composer line goes, in the order the page reads it:
//   1. /cut TEXT, /queue TEXT (steerChoiceRoute): during a turn in a session
//      the text as a cut or queued for after the turn; else the text goes
//      on as the line.
//   2. On the start page (+session+ false): the page's own reply or a typo
//      hint (startPageReplyOrHint) needs no session; anything else makes one.
//   3. In a session (routeSessionLine): a session command, the page's own
//      reply to a terminal's command, a typo hint, else a turn.
// +images+ is the count of image chips: a line with images is a message.
// @return one of
//   {reply, line}            the page answers itself (a bubble in a session,
//                            a notice on the start page); nothing is sent
//   {create: true, send, delivery}  start page: make a session, then route
//                            +send+ again in it (routeSessionLine, with its
//                            commands)
//   {command}                POST /command
//   {send, delivery}         POST /turn (+delivery+ "cut", "queue" or null)
export function routeComposerLine(text, { session = true, running = false, commands = [], images = 0 } = {}) {
  const choice = steerChoiceRoute(text, { running: running && session });
  if (choice?.reply) return { reply: choice.reply, line: text };
  const prompt = choice ? choice.send : text;
  const delivery = choice?.delivery || null;
  if (!session) {
    const local = startPageReplyOrHint(prompt, { commands, images });
    if (local) return { reply: local, line: prompt };
    return { create: true, send: prompt, delivery };
  }
  return routeSessionLine(prompt, { commands, images, delivery });
}

// A line in a session, after its /cut or /queue was read: a session command
// by the session's list (+commands+), or the page's own reply to one of a
// terminal's; an unknown /word is a prompt, as in a terminal, but a typo of
// a command (/modle) gets the hint, not a turn.
export function routeSessionLine(prompt, { commands = [], images = 0, delivery = null } = {}) {
  if (!images && sessionCommandLine(prompt, commands)) {
    const local = webLocalReply(prompt);
    return local ? { reply: local, line: prompt } : { command: prompt };
  }
  if (!images) {
    const typo = unknownCommandHint(prompt, commands);
    if (typo) return { reply: typo, line: prompt };
  }
  return { send: prompt, delivery };
}

// /model, !ls, /continue no … run in the session's worker; every client
// shows the command_ran, this one too.
// deps:
//   session()            the open session's id, or null
//   clientId             this tab's id (the command_ran's origin)
//   sendCommand(id, line, {clientId})   POST /command (data.js)
//   followWokenWorker()  the command woke the worker: follow its stream
//   refreshHistory()
//   failed(line, text)   a failed command's bubble
//   ownedByTui()         a plain terminal holds the session
//   composer: {busy(), clear(), done()}   the composer's send button and text
export function createComposerCommands(deps) {
  const { session, clientId, sendCommand, followWokenWorker, refreshHistory, failed, ownedByTui, composer } = deps;

  // A line typed in the composer (routeComposerLine's {command}).
  async function send(line) {
    composer.busy();
    try {
      await sendCommand(session(), line, { clientId });
      composer.clear();
      refreshHistory();
      followWokenWorker();
    } catch (e) {
      if (e.code === "owned_by_tui") {
        ownedByTui();
        return;
      }
      failed(line, e.message);
    } finally {
      composer.done();
    }
  }

  // A session command from a control (the llm ctx chip), not the composer:
  // its command_ran shows its line and reply, as a typed one's would.
  // Resolves true once the worker took it, false when it wasn't sent (no
  // session, a refusal or a network error: the failed bubble says why).
  async function run(line) {
    const id = session();
    if (!id) return false;
    try {
      await sendCommand(id, line, { clientId });
      followWokenWorker();
      return true;
    } catch (e) {
      failed(line, e.message);
      return false;
    }
  }

  return { send, run };
}
