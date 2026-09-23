# frozen_string_literal: true

module Samagotchi
  module Guardrails
    # An ask as a question for the user (Engine#open_question), and the
    # answer back as a verdict. The question text is plain and complete, so
    # a UI that doesn't know approvals still shows everything; `approval:`
    # carries the same facts for UIs that render them richer. Answers map
    # to scopes by index, never by label.
    module Approval
      KIND = "approval"
      HEADER = "Approve tool call?"
      DENY = "Deny"

      module_function

      # @param verdict [Verdict] an ask, with its targets and context
      # @return [Hash] open_question fields
      def payload(verdict)
        scopes = offered_scopes(verdict)
        targets = verdict.targets
        {
          question: question_text(verdict),
          options: scopes.map { |scope| label(scope, verdict) } + [DENY],
          header: HEADER,
          multi_select: false,
          allow_freeform: true,
          kind: KIND,
          approval: {
            tool: targets&.tool || verdict.call[:name].to_s,
            command: targets&.command,
            paths: targets && !targets.paths.empty? ? targets.paths : nil,
            cwd: targets&.cwd,
            repo_root: targets&.repo_root,
            branch: verdict.context&.branch(targets&.cwd || verdict.context.cwd),
            rule: verdict.rule,
            source: verdict.source,
            reason: verdict.reason,
            scopes: scopes
          }.compact
        }
      end

      # Settle +verdict+ from open_question's result.
      # @param answer [Hash, String] {selected_indices:, freeform:} or {error:}
      # @param scopes [Array<String>] the offered scopes, in option order
      # @return [Verdict]
      def settle(verdict, answer, scopes)
        unless answer.is_a?(Hash) && !answer[:error]
          return verdict.settle!(:deny, decided_by: "user", note: "The approval was cancelled.")
        end

        index = Array(answer[:selected_indices]).first
        if index && index < scopes.size
          verdict.settle!(:allow, decided_by: "user")
          verdict.scope = scopes[index]
          return verdict
        end

        freeform = answer[:freeform].to_s.strip
        note = freeform.empty? ? "The user declined." : "The user declined: #{freeform.inspect}."
        verdict.settle!(:deny, decided_by: "user", note: note)
      end

      # The rule's scopes; "rule" only when a rule id names what to approve.
      def offered_scopes(verdict)
        verdict.scopes.reject { |scope| scope == "rule" && verdict.rule.nil? }
      end

      def label(scope, verdict)
        place = verdict.targets&.repo_root ? "in this repo" : "in this directory"
        case scope
        when "once" then "Allow once"
        when "session" then "Allow this call for the session"
        when "repo" then "Allow this call #{place}"
        when "rule" then "Allow rule #{verdict.rule} #{place}"
        end
      end

      # execute: git push origin main
      #   in /path/to/repo (repo samagotchi, branch main)
      #   why: git push publishes commits (rule git-push, bundle guardrails)
      def question_text(verdict)
        targets = verdict.targets
        tool = targets&.tool || verdict.call[:name].to_s
        what = targets&.command || (targets && targets.paths.join(", "))
        lines = ["#{tool}: #{what}"]
        if targets
          repo = targets.repo_root
          branch = verdict.context&.branch(targets.cwd)
          where = repo ? "repo #{File.basename(repo)}#{", branch #{branch}" if branch}" : "not in a repo"
          lines << "  in #{targets.cwd} (#{where})"
        end
        who = verdict.rule ? ["rule #{verdict.rule}", verdict.source].compact.join(", ") : (verdict.source || "hook")
        reason = verdict.reason.to_s.strip
        lines << "  why: #{reason.empty? ? "(no reason given)" : reason} (#{who})"
        lines.join("\n")
      end
    end
  end
end
