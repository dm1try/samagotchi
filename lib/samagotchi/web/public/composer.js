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
//   failedElsewhere(line, text, id)   a command to session id, no longer open, failed
//   ownedByTui()         a plain terminal holds the session
//   composer: {busy(), text(), clear(), done()}   the composer's send button
//                        and text (text(): what it holds now)
export function createComposerCommands(deps) {
  const { session, clientId, sendCommand, followWokenWorker, refreshHistory, failed, failedElsewhere, ownedByTui,
          composer } = deps;

  // The page may open another session while a command is in flight: what
  // follows is about the session it went to (+id+), so the open one's
  // worker, owner and history are left alone then.
  async function send(line) {
    const id = session();
    // The composer is shared: a draft typed in a session opened meanwhile
    // stays when the answer comes; only the text sent goes.
    const sent = composer.text();
    composer.busy();
    try {
      await sendCommand(id, line, { clientId });
      if (composer.text() === sent) composer.clear();
      refreshHistory();
      if (session() === id) followWokenWorker();
    } catch (e) {
      if (session() !== id) return failedElsewhere(line, e.message, id);
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
      if (session() === id) followWokenWorker();
      return true;
    } catch (e) {
      if (session() === id) failed(line, e.message);
      else failedElsewhere(line, e.message, id);
      return false;
    }
  }

  return { send, run };
}
