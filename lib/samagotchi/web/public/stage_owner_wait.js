// The stage's look while a participant's view of the running turn waits for
// the owner (the participant main page, scene 3): the status row says
// "waiting for the owner" and one line under the live slots names what
// kind of thing they are asked (an approval, a question, a continue
// offer), never its content; no card. chi web sends the kind alone
// (ParticipantView.waiting_kind: question_requested / continue_offered's
// `kind`, the show's current_turn and viewer.waiting_for_owner).
// stage_view.js draws it at each refresh from its +ownerWait+ hook; the
// owner's page passes none (its cards are the waiting look).

export const OWNER_WAIT_STATUS = "waiting for the owner";

// The line per kind; a kind the page doesn't know reads as a question.
export const OWNER_WAIT_TEXT = Object.freeze({
  approval: "chi wants to run a command that needs the owner's approval. The turn continues when they answer.",
  question: "chi asked the owner a question. The turn continues when they answer.",
  continue: "chi asks the owner whether to go on. The turn continues when they answer.",
});

export const ownerWaitText = (kind) => OWNER_WAIT_TEXT[kind] || OWNER_WAIT_TEXT.question;

// +stage+ the stage's root, +line+ the line's node (stage_view.js makes it
// after the live slots), +phaseEl+ the status row's phase.
// @return draw(kind): kind null (not waiting) puts the stage back
export function createOwnerWait({ stage, line, phaseEl }) {
  line.hidden = true;
  return function draw(kind) {
    stage.classList.toggle("owner-wait", !!kind);
    line.hidden = !kind;
    if (!kind) return;
    phaseEl.textContent = OWNER_WAIT_STATUS;
    const text = ownerWaitText(kind);
    if (line.textContent !== text) line.textContent = text;
  };
}
