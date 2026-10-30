// A `!cmd`'s saved user message: the worker appends "!(<command>)\n<output>"
// for the next turn (session_commands.rb, no turn id, no time). The history
// draws it as its command bubble (turn_html.js) and the reload's turns
// leave it out (timing.js turnGroups: a group of its own, no steps, no
// timing). Pure, no imports: timing.js and turn_html.js both read it, and
// turn_html.js imports timing.js. A module of its own: static JS is cached
// at unversioned URLs, and a new export on an old module would blank the
// page.

// Its command line and its output, or null when the content is any other
// message. The command sits on the first line inside `!(` `)`; the output
// is everything after that first newline. A message that merely starts
// with "!" or "!(" without the newline shape is a plain message.
export function shellCommandMessage(content) {
  const text = String(content ?? "");
  const match = text.match(/^!\((.*)\)\n([\s\S]*)$/);
  if (!match) return null;
  return { line: `!${match[1]}`, text: match[2] };
}

// A history item that is a `!cmd`'s record, not a prompt: a user message of
// that shape with no turn id (a prompt saves its turn's; session_chain.rb
// reads the record the same way).
export function isShellCommandItem(item) {
  return item?.role === "user" && !item.turn_id && shellCommandMessage(item.content) !== null;
}
