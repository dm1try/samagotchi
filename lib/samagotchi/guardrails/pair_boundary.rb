# frozen_string_literal: true

require_relative "review_paths"
require_relative "shell_paths"
require_relative "parent_approvals"
require_relative "../steer"

module Samagotchi
  module Guardrails
    # A participant's pair turn (ParticipantMode :pair, a working session):
    # it acts with the session's tools under the owner's guardrails, and
    # their asks go to the owner (GuardrailWiring#request_approval). This
    # check sits in ReviewBoundary's seat (GuardrailWiring#checks), on in
    # every guardrails mode and with guardrails.enabled: false, active only
    # while the running turn's author is a participant. Like ReviewBoundary
    # it denies, never asks (the owner's approval would let the
    # participant's text reach what only the owner should), on:
    #   - secrets: ReviewPaths' read denylist (chi's state and config dirs,
    #     the web token and grants.json among them; home secret dirs;
    #     project secret files) on a read's path and on the paths a command
    #     names (execute, and any call whose targets carry a command:
    #     ShellPaths, with SECRET_TEXT for a word it can't resolve);
    #   - owner-voiced tools (OWNER_VOICED): what speaks or acts in the
    #     owner's name beyond this turn (a delegate, a reminder, a note to
    #     another session, a background task, a forgotten output) and a
    #     memory_write outside the project scope;
    #   - ask_user_question: there is no one on the participant's side to
    #     answer it here; the model asks in its reply instead.
    # Everything else goes on to the owner's checks and rules as for the
    # owner's turns.
    class PairBoundary
      RULE = "pair-boundary"
      SOURCE = "core"
      PROJECT_SCOPE = "project"
      OWNER_VOICED = %w[delegate register_reminder send_note forget_outputs task_create].freeze
      ASK_TOOL = "ask_user_question"

      ADVICE = "This is a participant's turn: work with this session's other tools, and say in your reply what " \
               "only the owner can do."
      SECRET = "a participant's turn can't read secrets or chi's own files"
      OWNER_ONLY = "a participant's turn can't use %s: it acts in the owner's name beyond this turn"
      MEMORY_SCOPE = "a participant's turn writes project memories only: call memory_write with scope: project"
      ASK = "a participant's turn can't ask the user: ask in your reply"

      # What a command word that can't be resolved to a path is matched
      # with: chi's own dirs (ParentApprovals::CHI_TEXT, the state dir,
      # the web's grants and token), the home secret dirs, and the secret
      # file names ReviewPaths::SECRET_FILE has.
      SECRET_TEXT = Regexp.union(
        ParentApprovals::CHI_TEXT,
        %r{\.local/state/samagotchi|web-grants|grants\.json|web-token},
        %r{(?:\A|[\s/'"=])\.(?:ssh|gnupg|aws|kube|docker)(?![\w.-])},
        %r{(?:\A|[\s/'"=])(?:\.env(?:\.[\w.-]*)?|[._]netrc|\.npmrc|\.pypirc|\.git-credentials)(?![\w-])},
        /\bid_(?:rsa|dsa|ecdsa|ed25519)\b|credentials|\.(?:pem|p12|pfx|tfstate)\b/
      )

      # @param author [#call] → String, nil: the running turn's author
      #   (GuardrailWiring#turn_author); the check is off unless it is a
      #   participant's (Steer.participant_author?)
      # @param denied_dirs [#call] → Array<String>: chi's own dirs
      # @param home [#call] → String, nil
      def initialize(author:, denied_dirs: -> { ReviewPaths.chi_dirs }, home: -> { Dir.home })
        @author = author
        @denied_dirs = denied_dirs
        @home = home
      end

      # Vote on +verdict+ (its call and targets).
      def check(verdict)
        return verdict unless Steer.participant_author?(@author.call)

        reason = refusal(verdict)
        return verdict unless reason

        verdict.deny!(reason, rule: RULE, source: SOURCE, decided_by: "core", advice: ADVICE)
      end

      private

      def refusal(verdict)
        call = verdict.call || {}
        tool = call[:name].to_s
        return ASK if tool == ASK_TOOL
        return format(OWNER_ONLY, tool) if OWNER_VOICED.include?(tool)
        return MEMORY_SCOPE if tool == "memory_write" && call[:scope].to_s.strip.downcase != PROJECT_SCOPE

        targets = verdict.targets
        return nil unless targets

        paths = ReviewPaths.new(root: nil, denied_dirs: @denied_dirs.call, home: @home.call)
        return SECRET if tool == "read" && paths.secret_refusal(targets.paths.compact)
        return SECRET if targets.command && command_secret?(targets.command, targets.cwd, paths)

        nil
      end

      def command_secret?(command, cwd, paths)
        ShellPaths.any_path?(command, text: SECRET_TEXT, cwd: cwd, home: @home.call.to_s) do |path|
          paths.secret_refusal([path])
        end
      end
    end
  end
end
