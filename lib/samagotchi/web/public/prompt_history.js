// ↑/↓ in the composer: the prompt history the TUI's ↑ walks (GET
// /api/history, oldest first), shared by every chi prompt. Pure: the page
// hands in the composer's value and selection, and sets what comes back.
//
// ↑ recalls only with the caret on the first line and nothing selected,
// ↓ moves forward only while browsing and from the last line; otherwise
// the keys are the browser's (null). ↑ puts the caret at the start, so ↑
// again keeps walking back; ↓ at the end. Past the newest entry ↓ brings
// back the draft there was when browsing started. Browsing ends whenever
// the value isn't the one the history last set: typing, a send clearing
// it, a refill, a quote — every path that sets the value, unhooked.
// An entry equal to the one just shown is skipped.

const onFirstLine = ({ value, start }) => !value.slice(0, start).includes("\n");
const onLastLine = ({ value, end }) => !value.slice(end).includes("\n");

export function createPromptHistory() {
  let entries = [];
  let index = -1; // the entry shown; -1 = not browsing
  let draft = "";
  let lastSet = null;

  function browsing(value) {
    if (index >= 0 && value !== lastSet) index = -1;
    return index >= 0;
  }

  function show(i, caretAtEnd) {
    index = i;
    lastSet = entries[i];
    return { value: lastSet, caret: caretAtEnd ? lastSet.length : 0 };
  }

  return {
    // The list as fetched; a place in it survives while its entry does.
    setEntries(list) {
      entries = Array.isArray(list) ? list.map(String) : [];
      if (index >= 0) index = entries.lastIndexOf(lastSet);
    },

    up(state) {
      const was = browsing(state.value);
      if (state.start !== state.end || !onFirstLine(state)) return null;
      const shown = was ? lastSet : state.value;
      let i = was ? index - 1 : entries.length - 1;
      while (i >= 0 && entries[i] === shown) i--;
      if (i < 0) return null;
      if (!was) draft = state.value;
      return show(i, false);
    },

    down(state) {
      if (!browsing(state.value)) return null;
      if (state.start !== state.end || !onLastLine(state)) return null;
      let i = index + 1;
      while (i < entries.length && entries[i] === lastSet) i++;
      if (i < entries.length) return show(i, true);
      index = -1;
      lastSet = null;
      return { value: draft, caret: draft.length };
    },
  };
}
