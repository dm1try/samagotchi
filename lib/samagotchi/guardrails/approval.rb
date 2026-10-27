# frozen_string_literal: true

require "json"

require_relative "../question_answer"

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
      # A participant's turn's ask (author:): who asks, in the header and as
      # the question's last line, so a UI that doesn't know the field still
      # says it.
      PARTICIPANT_HEADER = "%s's turn asks: approve tool call?"
      # Who asks, in the plain question (indented) and as the card's line
      # (approval asked_by:): the one wording every UI shows.
      ASKED_BY = "asked by: %s's turn (a participant, not you); Allow once only"
      # The only scope a participant's ask offers: no session, repo or rule
      # approval is made from a participant's call.
      PARTICIPANT_SCOPES = %w[once].freeze
      DENY = "Deny"
      ONCE = "Allow once"

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
      # @param author [String, nil] a participant's author ("p:<id>") when
      #   their turn asks: it offers once only (PARTICIPANT_SCOPES), and the
      #   card names them (approval author:, author_name:, the header)
      # @param author_name [String, nil] their name (participants.json)
      # @return [Hash] open_question fields; its caller adds user_only:
      #   (ParentApprovals.protected_facts? on approval:, a file that
      #   requires this one)
      def payload(verdict, label: nil, preview: nil, only: nil, author: nil, author_name: nil)
        asker = asker(author, author_name)
        only = PARTICIPANT_SCOPES if asker
        scopes = offered_scopes(verdict, only: only)
        targets = verdict.targets
        question = question_text(verdict, label: label, preview: preview)
        question = "#{question}\n  #{format(ASKED_BY, asker)}" if asker
        {
          question: question,
          options: scopes.map { |scope| label(scope, verdict) } + [DENY],
          header: asker ? format(PARTICIPANT_HEADER, asker) : HEADER,
          multi_select: false,
          allow_freeform: true,
          effects: effects(scopes),
          kind: KIND,
          approval: {
            tool: targets&.tool || verdict.call[:name].to_s,
            # The tool the call acts as (an MCP tool behind call_tool).
            acts_as: targets&.acts_as,
            label: label,
            command: targets&.command,
            paths: targets && !targets.paths.empty? ? targets.paths : nil,
            # No command or path (an MCP tool): its arguments, as the question.
            args: args_for_card(targets),
            # A memory_write ask, in words: the entry, its scope, and for a
            # removal the description its index line carries.
            memory: memory_for_card(targets),
            cwd: targets&.cwd,
            repo_root: targets&.repo_root,
            # The repository's name (a worktree's main checkout's folder).
            repo_name: targets&.repo_name,
            branch: verdict.context&.branch(targets&.cwd || verdict.context.cwd),
            rule: verdict.rule,
            source: verdict.source,
            reason: verdict.reason,
            scopes: scopes,
            preview: preview,
            # A participant's turn asks (nil for the owner's).
            author: (author.to_s if asker),
            author_name: (author_name_for(author_name) if asker),
            asked_by: (format(ASKED_BY, asker) if asker)
          }.compact
        }
      end

      # How a participant's ask names them: their cleaned name, else their
      # id; nil for the owner's turns.
      def asker(author, author_name)
        require_relative "../steer"
        return nil unless Steer.participant_author?(author)

        name = author_name_for(author_name)
        name || Steer.participant_id(author.to_s)
      end

      def author_name_for(author_name)
        require_relative "../participant_name"
        name = ParticipantName.clean(author_name)
        name.empty? ? nil : name
      end

      # Each option's effect for a parent's answer (ParentPolicy): once
      # permits one call, a wider scope more, Deny denies.
      def effects(scopes)
        scopes.map { |scope| scope == "once" ? "permit" : "permit_wide" } + ["deny"]
      end

      def args_for_card(targets)
        return nil if targets.nil? || targets.command || !targets.paths.empty?

        text = Approval.args_text(targets.args, limit: ARGS_CHARS)
        text.empty? ? nil : text
      end

      # A memory_write ask names an entry, not a file: which one, and in which
      # scope. For a removal the ask also carries that entry's description from
      # its scoped index line, which is what System 1 otherwise cannot see
      # (docs/guardrails.md, "System 1"). nil for every other tool.
      def memory_for_card(targets)
        entry = targets&.memory
        return nil if entry.nil?

        facts = { name: entry[:name], scope: entry[:scope] }
        if targets.memory_remove?
          require_relative "../memory_bundle/index_updater"
          description = MemoryBundle::IndexUpdater.description_for(entry[:scope], entry[:name])
          facts[:description] = description unless description.to_s.strip.empty?
        end
        facts
      end

      # Settle +verdict+ from open_question's result.
      # @param answer [QuestionAnswer, Hash, String] the answer, or {error:} (anything else is a cancel)
      # @param scopes [Array<String>] the offered scopes, in option order
      # @return [Verdict]
      def settle(verdict, answer, scopes)
        unless answer.is_a?(QuestionAnswer)
          return verdict.settle!(:deny, decided_by: "user", note: "The approval was cancelled.")
        end

        index = answer.selected_indices.first
        if index && index < scopes.size
          verdict.settle!(:allow, decided_by: "user")
          verdict.scope = scopes[index]
          return verdict
        end

        freeform = answer.freeform.to_s.strip
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
        when "once" then ONCE
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
