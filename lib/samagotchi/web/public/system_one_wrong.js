import { markSystemOneWrong } from "./data.js";

// The owner-only correction button on a System 1 auto-allowed tool row.
export function createSystemOneWrongAction({
  sessionId,
  mark = markSystemOneWrong,
  alert = (text) => globalThis.alert(text),
}) {
  return async (event) => {
    const button = event.target.closest?.("button.system-one-wrong");
    if (!button) return false;

    event.preventDefault();
    event.stopPropagation();
    const id = sessionId();
    if (!id || button.disabled) return false;

    button.disabled = true;
    try {
      await mark(id, button.dataset.judgmentId);
      button.textContent = "should have asked";
      button.setAttribute("aria-pressed", "true");
      button.classList.add("marked");
      button.closest(".activity-row")?.classList.add("guardrail-wrong");
      return true;
    } catch (error) {
      button.disabled = false;
      alert(`Could not mark auto-allow: ${error.message}`);
      return false;
    }
  };
}
