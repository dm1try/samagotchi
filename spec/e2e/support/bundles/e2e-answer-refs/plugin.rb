# frozen_string_literal: true

# The e2e suite's refs on an answer that says E2E_REFS (the answer_refs
# scenario): JIRA-7 (a markdown link to its first action's URL) with a
# second action, and ABC-3 (plain text) with one. Refs only, no present:
# the page gets them from an answer_display with no display.
# Its e2e_ticket tool gives its row two refs (traceable refs P5d): the
# title opens the first's action, the menu offers the second's.
# A question whose reply names JIRA-7 (the question scenario) gets it as a
# ref on that reply (:question_asked).
class Plugin
  def register(chi)
    chi.tool("e2e_ticket", "Look up an e2e ticket", params: { id: { type: "string", required: true } },
             label: "ticket",
             refs: lambda { |args|
               [{ kind: "issue", target: { id: args["id"] }, label: "#{args["id"]} Login fails",
                  actions: [{ id: "open", label: "Open in Jira", url: "https://example.test/#{args["id"]}" }] },
                { kind: "pr", target: { id: "42" }, label: "PR #42",
                  actions: [{ id: "open", label: "Open on GitHub", url: "https://example.test/pull/42" }] }]
             }) { |args| "#{args["id"]}: Login fails" }
    chi.on(:question_asked) do |event, _ctx|
      next unless event[:text].to_s.include?("JIRA-7")

      event[:refs].call(match: "JIRA-7", kind: "issue", target: { id: "JIRA-7" }, label: "JIRA-7 Login fails",
                        actions: [{ id: "open", label: "Open in Jira", url: "https://example.test/JIRA-7" }])
    end
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
