# frozen_string_literal: true

require "digest"

require_relative "question"

module Samagotchi
  module SystemOne
    # The one question an approval asks System 1: "would this user allow it
    # without hesitation?" (docs/guardrails.md, "System 1"). The instruction
    # is a constant in code, reviewed like a prompt; the state is the ask's
    # own facts — the rule that asked, why, the call, and where it runs.
    module ApprovalQuestion
      ID = "allow"
      # What the judgment is asked, in the model's terms. Frozen: a change
      # here is a change in behaviour, not a wording tweak.
      INSTRUCTIONS = "A coding agent wants to run this tool call, and a guardrail rule asked its user to approve it. " \
                     "The state names the rule, why it asked, the call and where it runs. Would the user approve it " \
                     "without hesitation? Users usually approve routine reads, edits of the agent's own notes and " \
                     "memory, and pushes of verified work; they usually refuse discarding uncommitted work, " \
                     "interactive rebases, deleting outside the project, and anything irreversible they did not ask for."
      # How much of a command, a diff or a path list the state carries.
      TEXT_CHARS = 2000
      # How much of the call the judgment log keeps; its digest is of the whole.
      CALL_CHARS = 300

      # @return [Question] the noul question for id "allow"
      def self.question
        # The type as a string: a symbol here reads as an event type to
        # spec/web/participant_view_spec.
        Question.new(id: ID, type: "noul", instructions: INSTRUCTIONS)
      end

      # @param approval [Hash] payload[:approval]: the ask the user is shown
      # @param session_title [String, nil] the session's title, when it has one
      # @return [Hash] the state, with the fields the ask didn't give left out
      def self.state(approval, session_title: nil)
        {
          "rule" => approval[:rule],
          "source" => approval[:source],
          "reason" => approval[:reason],
          "tool" => approval[:tool],
          "command" => cut(approval[:command]),
          "paths" => Array(approval[:paths]).map { |path| cut(path) },
          "change" => change_text(approval[:preview]),
          "cwd" => approval[:cwd],
          "repo_name" => approval[:repo_name],
          "branch" => approval[:branch],
          "session" => session_title
        }.reject { |_key, value| value.nil? || (value.is_a?(String) && value.strip.empty?) || (value.is_a?(Array) && value.empty?) }
      end

      # What the call is, whole: the command, the paths, or a plugin tool's
      # arguments.
      def self.call_text(approval)
        command = approval[:command]
        return command.to_s if command && !command.to_s.empty?

        paths = Array(approval[:paths])
        return paths.join("\n") unless paths.empty?

        approval[:args].to_s
      end

      # The judgment log's two fields for the call: what it was, cut to
      # CALL_CHARS, and the SHA256 of the whole of it.
      def self.call_fields(approval)
        call = call_text(approval)
        { "call" => cut(call, CALL_CHARS), "call_digest" => Digest::SHA256.hexdigest(call) }
      end

      private_class_method def self.change_text(preview)
        return nil unless preview.is_a?(Hash)

        text = preview[:text] || preview["text"]
        return cut(text) if text && !text.to_s.strip.empty?

        note = preview[:error] || preview["error"] || preview[:skipped] || preview["skipped"]
        return note.to_s unless note.to_s.strip.empty?

        "+#{(preview[:added] || preview["added"]).to_i} −#{(preview[:removed] || preview["removed"]).to_i}"
      end

      private_class_method def self.cut(text, chars = TEXT_CHARS)
        text = text.to_s
        text.length > chars ? "#{text[0, chars - 1]}…" : text
      end
    end
  end
end
