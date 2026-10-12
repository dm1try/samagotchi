# frozen_string_literal: true

# The e2e suite's refs on an answer that says E2E_REFS (the answer_refs
# scenario): JIRA-7 (a markdown link to its first action's URL) with a
# second action, and ABC-3 (plain text) with one. Refs only, no present:
# the page gets them from an answer_display with no display.
class Plugin
  def register(chi)
    chi.on(:after_turn) do |event, _ctx|
      answer = Array(event[:messages]).reverse.find { |m| (m[:role] || m["role"]).to_s == "model" }
      next unless answer && (answer[:content] || answer["content"]).to_s.include?("E2E_REFS")

      event[:refs].call(match: "JIRA-7", kind: "issue", target: { id: "JIRA-7" }, label: "JIRA-7 Login fails",
                        actions: [{ id: "open", label: "Open in Jira", url: "https://example.test/JIRA-7" },
                                  { id: "board", label: "Jira board", url: "https://example.test/board/JIRA-7" }])
      event[:refs].call(match: "ABC-3", kind: "issue", target: { id: "ABC-3" },
                        actions: [{ id: "open", label: "Open in ABC", url: "https://example.test/ABC-3" }])
    end
  end
end
