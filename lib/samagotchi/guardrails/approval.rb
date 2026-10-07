# frozen_string_literal: true

require "json"

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
      # @param label [String, nil] a plugin tool's label ("chrome:
      #   screenshot"): the question names the tool by it, as its row does
      #   (without one, by the tool the call acts as, else its name);
      #   approval[:tool] stays the raw name
      # @param preview [Hash, nil] EditPreview.for(verdict.call) for edit and
      #   write: the card shows its diff, the question text one change line
      # @param only [Array<String>, nil] offer no scope beyond these (a
      #   scratch session: once, session); "once" when none is left
      # @return [Hash] open_question fields
      def payload(verdict, label: nil, preview: nil, only: nil)
        scopes = offered_scopes(verdict, only: only)
        targets = verdict.targets
        {
          question: question_text(verdict, label: label, preview: preview),
          options: scopes.map { |scope| label(scope, verdict) } + [DENY],
          header: HEADER,
          multi_select: false,
          allow_freeform: true,
          kind: KIND,
          approval: {
            tool: targets&.tool || verdict.call[:name].to_s,
            # The tool the call acts as (an MCP tool behind mcp_call).
            acts_as: targets&.acts_as,
            label: label,
            command: targets&.command,
            paths: targets && !targets.paths.empty? ? targets.paths : nil,
            # No command or path (an MCP tool): its arguments, as the question.
            args: args_for_card(targets),
            cwd: targets&.cwd,
            repo_root: targets&.repo_root,
            # The repository's name (a worktree's main checkout's folder).
            repo_name: targets&.repo_name,
            branch: verdict.context&.branch(targets&.cwd || verdict.context.cwd),
            rule: verdict.rule,
            source: verdict.source,
            reason: verdict.reason,
            scopes: scopes,
            preview: preview
          }.compact
        }
      end

      def args_for_card(targets)
        return nil if targets.nil? || targets.command || !targets.paths.empty?

        text = Approval.args_text(targets.args, limit: ARGS_CHARS)
        text.empty? ? nil : text
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
        note = freeform.empty? ? "The user declined this call." : "The user declined this call: #{freeform.inspect}."
        verdict.settle!(:deny, decided_by: "user", note: note)
      end

      # The rule's scopes; "rule" only when a rule id names what to approve.
      def offered_scopes(verdict, only: nil)
        scopes = verdict.scopes.reject { |scope| scope == "rule" && verdict.rule.nil? }
        return scopes unless only

        scopes &= only
        scopes.empty? ? ["once"] : scopes
      end

      def label(scope, verdict)
        place = verdict.targets&.repo_root ? "in this repo (#{verdict.targets.repo_name})" : "in this directory"
        case scope
        when "once" then "Allow once"
        when "session" then "Allow this call for the session"
        when "repo" then "Allow this call #{place}"
        when "rule" then "Allow rule #{verdict.rule} #{place}"
        end
      end

      # How much of a plugin tool's arguments the question shows.
      ARGS_CHARS = 300

      # A plugin tool's arguments (Targets#args), as the question shows
      # them and an approval is keyed by, when its targets name no command
      # or path (an MCP tool): `a=20 b="x y"`, keys sorted, values as JSON.
      # "" for none (chi's own tools).
      # @param limit [Integer, nil] cut to this many characters (with …)
      def args_text(args, limit: nil)
        return "" unless args.is_a?(Hash) && !args.empty?

        text = args.sort_by { |key, _| key.to_s }.map do |key, value|
          "#{key}=#{value.is_a?(String) && value.match?(/\A[^\s"=]+\z/) ? value : JSON.generate(value)}"
        end.join(" ")
        limit && text.length > limit ? "#{text[0, limit - 1]}…" : text
      end

      # execute: git push origin main
      #   in /path/to/repo (repo samagotchi, branch main)
      #   why: git push publishes commits (rule git-push, bundle guardrails)
      #   change: +3 −1                      (edit/write, from the preview)
      def question_text(verdict, label: nil, preview: nil)
        targets = verdict.targets
        tool = label || targets&.acts_as || targets&.tool || verdict.call[:name].to_s
        what = targets&.command || (targets && targets.paths.join(", "))
        what = Approval.args_text(targets&.args, limit: ARGS_CHARS) if what.to_s.empty?
        lines = ["#{tool}: #{what}"]
        if targets
          branch = verdict.context&.branch(targets.cwd)
          where = targets.repo_root ? "repo #{targets.repo_name}#{", branch #{branch}" if branch}" : "not in a repo"
          lines << "  in #{targets.cwd} (#{where})"
        end
        who = verdict.rule ? ["rule #{verdict.rule}", verdict.source].compact.join(", ") : (verdict.source || "hook")
        reason = verdict.reason.to_s.strip
        lines << "  why: #{reason.empty? ? "(no reason given)" : reason} (#{who})"
        change = change_text(preview)
        lines << "  change: #{change}" if change
        lines.join("\n")
      end

      # One line for an EditPreview: "+3 −1", "new file, 12 lines",
      # "would fail: …" or "not shown (binary file)". The diff itself stays
      # out of the question text (size); the card and the TUI show it.
      def change_text(preview)
        return nil unless preview.is_a?(Hash)

        get = ->(key) { preview[key] || preview[key.to_s] }
        return "would fail: #{get.call(:error)}" if get.call(:error)
        return "not shown (#{get.call(:skipped)})" if get.call(:skipped)

        added = get.call(:added).to_i
        return "new file, #{added} #{added == 1 ? "line" : "lines"}" if get.call(:new_file)

        "+#{added} −#{get.call(:removed).to_i}"
      end
    end
  end
end
